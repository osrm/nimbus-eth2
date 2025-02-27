# beacon_chain
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

# Types specific to Fulu (i.e. known to have changed across hard forks) - see
# `base` for types and guidelines common across forks

# TODO Careful, not nil analysis is broken / incomplete and the semantics will
#      likely change in future versions of the language:
#      https://github.com/nim-lang/RFCs/issues/250
{.experimental: "notnil".}

import
  std/[sequtils, typetraits],
  "."/[phase0, base, electra],
  chronicles,
  json_serialization,
  ssz_serialization/[merkleization, proofs],
  ssz_serialization/types as sszTypes,
  ../digest,
  kzg4844/[kzg, kzg_abi]

from std/strutils import join
from stew/bitops2 import log2trunc
from stew/byteutils import to0xHex
from ./altair import
  EpochParticipationFlags, InactivityScores, SyncAggregate, SyncCommittee,
  TrustedSyncAggregate, SyncnetBits, num_active_participants
from ./bellatrix import BloomLogs, ExecutionAddress, Transaction
from ./capella import
  ExecutionBranch, HistoricalSummary, SignedBLSToExecutionChange,
  SignedBLSToExecutionChangeList, Withdrawal, EXECUTION_PAYLOAD_GINDEX
from ./deneb import Blobs, BlobsBundle, KzgCommitments, KzgProofs

export json_serialization, base

const
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/polynomial-commitments-sampling.md#cells
  FIELD_ELEMENTS_PER_EXT_BLOB* = 2 * kzg_abi.FIELD_ELEMENTS_PER_BLOB
  # Number of field elements in a Reed-Solomon extended blob |
  FIELD_ELEMENTS_PER_CELL* = 64 # Number of field elements in a cell |
  BYTES_PER_CELL* = FIELD_ELEMENTS_PER_CELL * kzg_abi.BYTES_PER_FIELD_ELEMENT
  # The number of bytes in a cell |
  CELLS_PER_EXT_BLOB* = FIELD_ELEMENTS_PER_EXT_BLOB div FIELD_ELEMENTS_PER_CELL
  # The number of cells in an extended blob |

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/p2p-interface.md#preset
  KZG_COMMITMENTS_INCLUSION_PROOF_DEPTH* = 4
  KZG_COMMITMENTS_INCLUSION_PROOF_DEPTH_GINDEX* = 27

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/das-core.md#data-size
  NUMBER_OF_COLUMNS* = 128

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/das-core.md#networking
  DATA_COLUMN_SIDECAR_SUBNET_COUNT* = 128

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/das-core.md#custody-setting
  SAMPLES_PER_SLOT* = 8
  CUSTODY_REQUIREMENT* = 4

type
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.6/specs/_features/eip7594/polynomial-commitments-sampling.md#custom-types
  BLSFieldElement* = KzgBytes32
  G2Point* = array[96, byte]
  PolynomialCoeff* = List[BLSFieldElement, FIELD_ELEMENTS_PER_EXT_BLOB]
  Coset* = array[FIELD_ELEMENTS_PER_CELL, BLSFieldElement]
  CosetEvals* = array[FIELD_ELEMENTS_PER_CELL, BLSFieldElement]
  Cell* = KzgCell
  Cells* = KzgCells
  CellsAndProofs* = KzgCellsAndKzgProofs

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/das-core.md#custom-types
  RowIndex* = uint64
  ColumnIndex* = uint64
  CellIndex* = uint64


type
  DataColumn* = List[KzgCell, Limit(MAX_BLOB_COMMITMENTS_PER_BLOCK)]

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.9/specs/_features/eip7594/das-core.md#datacolumnsidecar
  DataColumnSidecar* = object
    index*: ColumnIndex # Index of column in extended matrix
    column*: DataColumn
    kzg_commitments*: KzgCommitments
    kzg_proofs*: KzgProofs
    signed_block_header*: SignedBeaconBlockHeader
    kzg_commitments_inclusion_proof*:
      array[KZG_COMMITMENTS_INCLUSION_PROOF_DEPTH, Eth2Digest]

  DataColumnSidecars* = seq[ref DataColumnSidecar]

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/p2p-interface.md#datacolumnidentifier
  DataColumnIdentifier* = object
    block_root*: Eth2Digest
    index*: ColumnIndex

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.6/specs/_features/eip7594/das-core.md#matrixentry
  MatrixEntry* = object
    cell*: Cell
    kzg_proof*: KzgProof
    column_index*: ColumnIndex
    row_index*: RowIndex

  # Not in spec, defined in order to compute custody subnets
  CscBits* = BitArray[DATA_COLUMN_SIDECAR_SUBNET_COUNT]

  CscCount* = uint8

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/_features/eip7594/p2p-interface.md#metadata
  MetaData* = object
    seq_number*: uint64
    attnets*: AttnetBits
    syncnets*: SyncnetBits
    custody_subnet_count*: uint64

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/deneb/beacon-chain.md#executionpayload
  ExecutionPayload* = object
    # Execution block header fields
    parent_hash*: Eth2Digest
    fee_recipient*: ExecutionAddress
      ## 'beneficiary' in the yellow paper
    state_root*: Eth2Digest
    receipts_root*: Eth2Digest
    logs_bloom*: BloomLogs
    prev_randao*: Eth2Digest
      ## 'difficulty' in the yellow paper
    block_number*: uint64
      ## 'number' in the yellow paper
    gas_limit*: uint64
    gas_used*: uint64
    timestamp*: uint64
    extra_data*: List[byte, MAX_EXTRA_DATA_BYTES]
    base_fee_per_gas*: UInt256

    # Extra payload fields
    block_hash*: Eth2Digest # Hash of execution block
    transactions*: List[Transaction, MAX_TRANSACTIONS_PER_PAYLOAD]
    withdrawals*: List[Withdrawal, MAX_WITHDRAWALS_PER_PAYLOAD]
    blob_gas_used*: uint64
    excess_blob_gas*: uint64

  ExecutionPayloadForSigning* = object
    executionPayload*: ExecutionPayload
    blockValue*: Wei
    blobsBundle*: BlobsBundle
    executionRequests*: seq[seq[byte]]

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/deneb/beacon-chain.md#executionpayloadheader
  ExecutionPayloadHeader* = object
    # Execution block header fields
    parent_hash*: Eth2Digest
    fee_recipient*: ExecutionAddress
    state_root*: Eth2Digest
    receipts_root*: Eth2Digest
    logs_bloom*: BloomLogs
    prev_randao*: Eth2Digest
    block_number*: uint64
    gas_limit*: uint64
    gas_used*: uint64
    timestamp*: uint64
    extra_data*: List[byte, MAX_EXTRA_DATA_BYTES]
    base_fee_per_gas*: UInt256

    # Extra payload fields
    block_hash*: Eth2Digest
      ## Hash of execution block
    transactions_root*: Eth2Digest
    withdrawals_root*: Eth2Digest
    blob_gas_used*: uint64
    excess_blob_gas*: uint64

  ExecutePayload* = proc(
    execution_payload: ExecutionPayload): bool {.gcsafe, raises: [].}

  FinalityBranch* =
    array[log2trunc(FINALIZED_ROOT_GINDEX_ELECTRA), Eth2Digest]

  CurrentSyncCommitteeBranch* =
    array[log2trunc(CURRENT_SYNC_COMMITTEE_GINDEX_ELECTRA), Eth2Digest]

  NextSyncCommitteeBranch* =
    array[log2trunc(NEXT_SYNC_COMMITTEE_GINDEX_ELECTRA), Eth2Digest]

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/capella/light-client/sync-protocol.md#modified-lightclientheader
  LightClientHeader* = object
    beacon*: BeaconBlockHeader
      ## Beacon block header

    execution*: ExecutionPayloadHeader
      ## Execution payload header corresponding to `beacon.body_root` (from Capella onward)
    execution_branch*: capella.ExecutionBranch

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/altair/light-client/sync-protocol.md#lightclientbootstrap
  LightClientBootstrap* = object
    header*: LightClientHeader
      ## Header matching the requested beacon block root

    current_sync_committee*: SyncCommittee
      ## Current sync committee corresponding to `header.beacon.state_root`
    current_sync_committee_branch*: CurrentSyncCommitteeBranch

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/altair/light-client/sync-protocol.md#lightclientupdate
  LightClientUpdate* = object
    attested_header*: LightClientHeader
      ## Header attested to by the sync committee

    next_sync_committee*: SyncCommittee
      ## Next sync committee corresponding to
      ## `attested_header.beacon.state_root`
    next_sync_committee_branch*: NextSyncCommitteeBranch

    # Finalized header corresponding to `attested_header.beacon.state_root`
    finalized_header*: LightClientHeader
    finality_branch*: FinalityBranch

    sync_aggregate*: SyncAggregate
      ## Sync committee aggregate signature
    signature_slot*: Slot
      ## Slot at which the aggregate signature was created (untrusted)

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/specs/altair/light-client/sync-protocol.md#lightclientfinalityupdate
  LightClientFinalityUpdate* = object
    # Header attested to by the sync committee
    attested_header*: LightClientHeader

    # Finalized header corresponding to `attested_header.beacon.state_root`
    finalized_header*: LightClientHeader
    finality_branch*: FinalityBranch

    # Sync committee aggregate signature
    sync_aggregate*: SyncAggregate
    # Slot at which the aggregate signature was created (untrusted)
    signature_slot*: Slot

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/altair/light-client/sync-protocol.md#lightclientoptimisticupdate
  LightClientOptimisticUpdate* = object
    # Header attested to by the sync committee
    attested_header*: LightClientHeader

    # Sync committee aggregate signature
    sync_aggregate*: SyncAggregate
    # Slot at which the aggregate signature was created (untrusted)
    signature_slot*: Slot

  SomeLightClientUpdateWithSyncCommittee* =
    LightClientUpdate

  SomeLightClientUpdateWithFinality* =
    LightClientUpdate |
    LightClientFinalityUpdate

  SomeLightClientUpdate* =
    LightClientUpdate |
    LightClientFinalityUpdate |
    LightClientOptimisticUpdate

  SomeLightClientObject* =
    LightClientBootstrap |
    SomeLightClientUpdate

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/altair/light-client/sync-protocol.md#lightclientstore
  LightClientStore* = object
    finalized_header*: LightClientHeader
      ## Header that is finalized

    current_sync_committee*: SyncCommittee
      ## Sync committees corresponding to the finalized header
    next_sync_committee*: SyncCommittee

    best_valid_update*: Opt[LightClientUpdate]
      ## Best available header to switch finalized head to
      ## if we see nothing else

    optimistic_header*: LightClientHeader
      ## Most recent available reasonably-safe header

    previous_max_active_participants*: uint64
      ## Max number of active participants in a sync committee
      ## (used to compute safety threshold)
    current_max_active_participants*: uint64

  # https://github.com/ethereum/consensus-specs/blob/82133085a1295e93394ebdf71df8f2f6e0962588/specs/electra/beacon-chain.md#beaconstate
  BeaconState* = object
    # Versioning
    genesis_time*: uint64
    genesis_validators_root*: Eth2Digest
    slot*: Slot
    fork*: Fork

    # History
    latest_block_header*: BeaconBlockHeader
      ## `latest_block_header.state_root == ZERO_HASH` temporarily

    block_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
      ## Needed to process attestations, older to newer

    state_roots*: HashArray[Limit SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    historical_roots*: HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT]
      ## Frozen in Capella, replaced by historical_summaries

    # Eth1
    eth1_data*: Eth1Data
    eth1_data_votes*:
      HashList[Eth1Data, Limit(EPOCHS_PER_ETH1_VOTING_PERIOD * SLOTS_PER_EPOCH)]
    eth1_deposit_index*: uint64

    # Registry
    validators*: HashList[Validator, Limit VALIDATOR_REGISTRY_LIMIT]
    balances*: HashList[Gwei, Limit VALIDATOR_REGISTRY_LIMIT]

    # Randomness
    randao_mixes*: HashArray[Limit EPOCHS_PER_HISTORICAL_VECTOR, Eth2Digest]

    # Slashings
    slashings*: HashArray[Limit EPOCHS_PER_SLASHINGS_VECTOR, Gwei]
      ## Per-epoch sums of slashed effective balances

    # Participation
    previous_epoch_participation*: EpochParticipationFlags
    current_epoch_participation*: EpochParticipationFlags

    # Finality
    justification_bits*: JustificationBits
      ## Bit set for every recent justified epoch

    previous_justified_checkpoint*: Checkpoint
    current_justified_checkpoint*: Checkpoint
    finalized_checkpoint*: Checkpoint

    # Inactivity
    inactivity_scores*: InactivityScores

    # Light client sync committees
    current_sync_committee*: SyncCommittee
    next_sync_committee*: SyncCommittee

    # Execution
    latest_execution_payload_header*: ExecutionPayloadHeader
      ## [Modified in Electra:EIP6110:EIP7002]

    # Withdrawals
    next_withdrawal_index*: WithdrawalIndex
    next_withdrawal_validator_index*: uint64

    # Deep history valid from Capella onwards
    historical_summaries*:
      HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT]

    deposit_requests_start_index*: uint64  # [New in Electra:EIP6110]
    deposit_balance_to_consume*: Gwei  # [New in Electra:EIP7251]
    exit_balance_to_consume*: Gwei  # [New in Electra:EIP7251]
    earliest_exit_epoch*: Epoch  # [New in Electra:EIP7251]
    consolidation_balance_to_consume*: Gwei  # [New in Electra:EIP7251]
    earliest_consolidation_epoch*: Epoch  # [New in Electra:EIP7251]
    pending_deposits*: HashList[PendingDeposit, Limit PENDING_DEPOSITS_LIMIT]
      ## [New in Electra:EIP7251]

    # [New in Electra:EIP7251]
    pending_partial_withdrawals*:
      HashList[PendingPartialWithdrawal, Limit PENDING_PARTIAL_WITHDRAWALS_LIMIT]
    pending_consolidations*:
      HashList[PendingConsolidation, Limit PENDING_CONSOLIDATIONS_LIMIT]
      ## [New in Electra:EIP7251]

  # TODO Careful, not nil analysis is broken / incomplete and the semantics will
  #      likely change in future versions of the language:
  #      https://github.com/nim-lang/RFCs/issues/250
  BeaconStateRef* = ref BeaconState not nil
  NilableBeaconStateRef* = ref BeaconState

  # TODO: There should be only a single generic HashedBeaconState definition
  HashedBeaconState* = object
    data*: BeaconState
    root*: Eth2Digest # hash_tree_root(data)

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/beacon-chain.md#beaconblock
  BeaconBlock* = object
    ## For each slot, a proposer is chosen from the validator pool to propose
    ## a new block. Once the block as been proposed, it is transmitted to
    ## validators that will have a chance to vote on it through attestations.
    ## Each block collects attestations, or votes, on past blocks, thus a chain
    ## is formed.

    slot*: Slot
    proposer_index*: uint64 # `ValidatorIndex` after validation

    parent_root*: Eth2Digest
      ## Root hash of the previous block

    state_root*: Eth2Digest
      ## The state root, _after_ this block has been processed

    body*: BeaconBlockBody

  SigVerifiedBeaconBlock* = object
    ## A BeaconBlock that contains verified signatures
    ## but that has not been verified for state transition

    slot*: Slot
    proposer_index*: uint64 # `ValidatorIndex` after validation

    parent_root*: Eth2Digest
      ## Root hash of the previous block

    state_root*: Eth2Digest
      ## The state root, _after_ this block has been processed

    body*: SigVerifiedBeaconBlockBody

  TrustedBeaconBlock* = object
    ## When we receive blocks from outside sources, they are untrusted and go
    ## through several layers of validation. Blocks that have gone through
    ## validations can be trusted to be well-formed, with a correct signature,
    ## having a parent and applying cleanly to the state that their parent
    ## left them with.
    ##
    ## When loading such blocks from the database, to rewind states for example,
    ## it is expensive to redo the validations (in particular, the signature
    ## checks), thus `TrustedBlock` uses a `TrustedSig` type to mark that these
    ## checks can be skipped.
    ##
    ## TODO this could probably be solved with some type trickery, but there
    ##      too many bugs in nim around generics handling, and we've used up
    ##      the trickery budget in the serialization library already. Until
    ##      then, the type must be manually kept compatible with its untrusted
    ##      cousin.
    slot*: Slot
    proposer_index*: uint64 # `ValidatorIndex` after validation
    parent_root*: Eth2Digest
    state_root*: Eth2Digest
    body*: TrustedBeaconBlockBody

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.6/specs/electra/beacon-chain.md#beaconblockbody
  BeaconBlockBody* = object
    randao_reveal*: ValidatorSig
    eth1_data*: Eth1Data
      ## Eth1 data vote

    graffiti*: GraffitiBytes
      ## Arbitrary data

    # Operations
    proposer_slashings*: List[ProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*:
      List[electra.AttesterSlashing, Limit MAX_ATTESTER_SLASHINGS_ELECTRA]
      ## [Modified in Electra:EIP7549]
    attestations*: List[electra.Attestation, Limit MAX_ATTESTATIONS_ELECTRA]
      ## [Modified in Electra:EIP7549]
    deposits*: List[Deposit, Limit MAX_DEPOSITS]
    voluntary_exits*: List[SignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

    sync_aggregate*: SyncAggregate

    # Execution
    execution_payload*: fulu.ExecutionPayload   # [Modified in Electra:EIP6110:EIP7002]
    bls_to_execution_changes*: SignedBLSToExecutionChangeList
    blob_kzg_commitments*: KzgCommitments
    execution_requests*: ExecutionRequests  # [New in Electra]

  SigVerifiedBeaconBlockBody* = object
    ## A BeaconBlock body with signatures verified
    ## including:
    ## - Randao reveal
    ## - Attestations
    ## - ProposerSlashing (SignedBeaconBlockHeader)
    ## - AttesterSlashing (IndexedAttestation)
    ## - SignedVoluntaryExits
    ## - SyncAggregate
    ##
    ## However:
    ## - ETH1Data (Deposits) can contain invalid BLS signatures
    ##
    ## The block state transition has NOT been verified
    randao_reveal*: TrustedSig
    eth1_data*: Eth1Data
      ## Eth1 data vote

    graffiti*: GraffitiBytes
      ## Arbitrary data

    # Operations
    proposer_slashings*:
      List[TrustedProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*:
      List[electra.TrustedAttesterSlashing, Limit MAX_ATTESTER_SLASHINGS_ELECTRA]
      ## [Modified in Electra:EIP7549]
    attestations*: List[electra.TrustedAttestation, Limit MAX_ATTESTATIONS_ELECTRA]
      ## [Modified in Electra:EIP7549]
    deposits*: List[Deposit, Limit MAX_DEPOSITS]
    voluntary_exits*: List[TrustedSignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

    sync_aggregate*: TrustedSyncAggregate

    # Execution
    execution_payload*: ExecutionPayload   # [Modified in Electra:EIP6110:EIP7002]
    bls_to_execution_changes*: SignedBLSToExecutionChangeList
    blob_kzg_commitments*: KzgCommitments
    execution_requests*: ExecutionRequests  # [New in Electra]

  TrustedBeaconBlockBody* = object
    ## A full verified block
    randao_reveal*: TrustedSig
    eth1_data*: Eth1Data
      ## Eth1 data vote

    graffiti*: GraffitiBytes
      ## Arbitrary data

    # Operations
    proposer_slashings*:
      List[TrustedProposerSlashing, Limit MAX_PROPOSER_SLASHINGS]
    attester_slashings*:
      List[electra.TrustedAttesterSlashing, Limit MAX_ATTESTER_SLASHINGS_ELECTRA]
      ## [Modified in Electra:EIP7549]
    attestations*: List[electra.TrustedAttestation, Limit MAX_ATTESTATIONS_ELECTRA]
      ## [Modified in Electra:EIP7549]
    deposits*: List[Deposit, Limit MAX_DEPOSITS]
    voluntary_exits*: List[TrustedSignedVoluntaryExit, Limit MAX_VOLUNTARY_EXITS]

    sync_aggregate*: TrustedSyncAggregate

    # Execution
    execution_payload*: ExecutionPayload   # [Modified in Electra:EIP6110:EIP7002]
    bls_to_execution_changes*: SignedBLSToExecutionChangeList
    blob_kzg_commitments*: KzgCommitments
    execution_requests*: ExecutionRequests  # [New in Electra]

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/specs/phase0/beacon-chain.md#signedbeaconblock
  SignedBeaconBlock* = object
    message*: BeaconBlock
    signature*: ValidatorSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  SigVerifiedSignedBeaconBlock* = object
    ## A SignedBeaconBlock with signatures verified
    ## including:
    ## - Block signature
    ## - BeaconBlockBody
    ##   - Randao reveal
    ##   - Attestations
    ##   - ProposerSlashing (SignedBeaconBlockHeader)
    ##   - AttesterSlashing (IndexedAttestation)
    ##   - SignedVoluntaryExits
    ##
    ##   - ETH1Data (Deposits) can contain invalid BLS signatures
    ##
    ## The block state transition has NOT been verified
    message*: SigVerifiedBeaconBlock
    signature*: TrustedSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  MsgTrustedSignedBeaconBlock* = object
    message*: TrustedBeaconBlock
    signature*: ValidatorSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  TrustedSignedBeaconBlock* = object
    message*: TrustedBeaconBlock
    signature*: TrustedSig

    root* {.dontSerialize.}: Eth2Digest # cached root of signed beacon block

  SomeSignedBeaconBlock* =
    SignedBeaconBlock |
    SigVerifiedSignedBeaconBlock |
    MsgTrustedSignedBeaconBlock |
    TrustedSignedBeaconBlock
  SomeBeaconBlock* =
    BeaconBlock |
    SigVerifiedBeaconBlock |
    TrustedBeaconBlock
  SomeBeaconBlockBody* =
    BeaconBlockBody |
    SigVerifiedBeaconBlockBody |
    TrustedBeaconBlockBody

  BlockContents* = object
    `block`*: BeaconBlock
    kzg_proofs*: KzgProofs
    blobs*: Blobs

func shortLog*(v: DataColumnSidecar): auto =
  (
    index: v.index,
    kzg_commitments: v.kzg_commitments.len,
    kzg_proofs: v.kzg_proofs.len,
    block_header: shortLog(v.signed_block_header.message),
  )

func shortLog*(v: seq[DataColumnSidecar]): auto =
  "[" & v.mapIt(shortLog(it)).join(", ") & "]"

func shortLog*(x: seq[DataColumnIdentifier]): string =
  "[" & x.mapIt(shortLog(it.block_root) & "/" & $it.index).join(", ") & "]"

func shortLog*(x: seq[ColumnIndex]): string =
  "<" & x.mapIt($it).join(", ") & ">"

# TODO: There should be only a single generic HashedBeaconState definition
func initHashedBeaconState*(s: BeaconState): HashedBeaconState =
  HashedBeaconState(data: s)

func shortLog*(v: SomeBeaconBlock): auto =
  (
    slot: shortLog(v.slot),
    proposer_index: v.proposer_index,
    parent_root: shortLog(v.parent_root),
    state_root: shortLog(v.state_root),
    eth1data: v.body.eth1_data,
    graffiti: $v.body.graffiti,
    proposer_slashings_len: v.body.proposer_slashings.len(),
    attester_slashings_len: v.body.attester_slashings.len(),
    attestations_len: v.body.attestations.len(),
    deposits_len: v.body.deposits.len(),
    voluntary_exits_len: v.body.voluntary_exits.len(),
    sync_committee_participants: v.body.sync_aggregate.num_active_participants,
    block_number: v.body.execution_payload.block_number,
    # TODO checksum hex? shortlog?
    block_hash: to0xHex(v.body.execution_payload.block_hash.data),
    parent_hash: to0xHex(v.body.execution_payload.parent_hash.data),
    fee_recipient: to0xHex(v.body.execution_payload.fee_recipient.data),
    bls_to_execution_changes_len: v.body.bls_to_execution_changes.len(),
    blob_kzg_commitments_len: v.body.blob_kzg_commitments.len(),
  )

func shortLog*(v: SomeSignedBeaconBlock): auto =
  (
    blck: shortLog(v.message),
    signature: shortLog(v.signature)
  )

func shortLog*(v: ExecutionPayload): auto =
  (
    parent_hash: shortLog(v.parent_hash),
    fee_recipient: $v.fee_recipient,
    state_root: shortLog(v.state_root),
    receipts_root: shortLog(v.receipts_root),
    prev_randao: shortLog(v.prev_randao),
    block_number: v.block_number,
    gas_limit: v.gas_limit,
    gas_used: v.gas_used,
    timestamp: v.timestamp,
    extra_data: toPrettyString(distinctBase v.extra_data),
    base_fee_per_gas: $(v.base_fee_per_gas),
    block_hash: shortLog(v.block_hash),
    num_transactions: len(v.transactions),
    num_withdrawals: len(v.withdrawals),
    blob_gas_used: $(v.blob_gas_used),
    excess_blob_gas: $(v.excess_blob_gas)
  )

template asSigned*(
    x: SigVerifiedSignedBeaconBlock |
       MsgTrustedSignedBeaconBlock |
       TrustedSignedBeaconBlock): SignedBeaconBlock =
  isomorphicCast[SignedBeaconBlock](x)

template asSigVerified*(
    x: SignedBeaconBlock |
       MsgTrustedSignedBeaconBlock |
       TrustedSignedBeaconBlock): SigVerifiedSignedBeaconBlock =
  isomorphicCast[SigVerifiedSignedBeaconBlock](x)

template asSigVerified*(
    x: BeaconBlock | TrustedBeaconBlock): SigVerifiedBeaconBlock =
  isomorphicCast[SigVerifiedBeaconBlock](x)

template asMsgTrusted*(
    x: SignedBeaconBlock |
       SigVerifiedSignedBeaconBlock |
       TrustedSignedBeaconBlock): MsgTrustedSignedBeaconBlock =
  isomorphicCast[MsgTrustedSignedBeaconBlock](x)

template asTrusted*(
    x: SignedBeaconBlock |
       SigVerifiedSignedBeaconBlock |
       MsgTrustedSignedBeaconBlock): TrustedSignedBeaconBlock =
  isomorphicCast[TrustedSignedBeaconBlock](x)
