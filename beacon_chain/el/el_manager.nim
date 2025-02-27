# beacon_chain
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strformat, typetraits, json, sequtils],
  # Nimble packages:
  chronos, metrics, chronicles/timings,
  json_rpc/[client, errors],
  web3, web3/[engine_api, primitives, conversions],
  eth/common/eth_types,
  results,
  kzg4844/[kzg_abi, kzg],
  stew/[assign2, byteutils, objects],
  # Local modules:
  ../spec/[eth2_merkleization, forks],
  ../networking/network_metadata,
  ".."/beacon_node_status,
  "."/[el_conf, engine_api_conversions, eth1_chain]

from std/times import getTime, inSeconds, initTime, `-`
from ../spec/engine_authentication import getSignedIatToken
from ../spec/helpers import bytes_to_uint64
from ../spec/state_transition_block import kzg_commitment_to_versioned_hash

export
  eth1_chain, el_conf, engine_api, base

logScope:
  topics = "elman"

const
  SleepDurations =
    [100.milliseconds, 200.milliseconds, 500.milliseconds, 1.seconds]

type
  FixedBytes[N: static int] =  web3.FixedBytes[N]
  PubKeyBytes = DynamicBytes[48, 48]
  WithdrawalCredentialsBytes = DynamicBytes[32, 32]
  SignatureBytes = DynamicBytes[96, 96]
  Int64LeBytes = DynamicBytes[8, 8]
  WithoutTimeout* = distinct int

  DeadlineObject* = object
    # TODO (cheatfate): This object declaration could be removed when
    # `Raising()` macro starts to support procedure arguments.
    future*: Future[void].Raising([CancelledError])

  SomeEnginePayloadWithValue =
    BellatrixExecutionPayloadWithValue |
    GetPayloadV2Response |
    GetPayloadV3Response |
    GetPayloadV4Response

contract(DepositContract):
  proc deposit(pubkey: PubKeyBytes,
               withdrawalCredentials: WithdrawalCredentialsBytes,
               signature: SignatureBytes,
               deposit_data_root: FixedBytes[32])

  proc get_deposit_root(): FixedBytes[32]
  proc get_deposit_count(): Int64LeBytes

  proc DepositEvent(pubkey: PubKeyBytes,
                    withdrawalCredentials: WithdrawalCredentialsBytes,
                    amount: Int64LeBytes,
                    signature: SignatureBytes,
                    index: Int64LeBytes) {.event.}

const
  noTimeout = WithoutTimeout(0)
  hasDepositRootChecks = defined(has_deposit_root_checks)

  targetBlocksPerLogsRequest = 1000'u64
    # TODO
    #
    # This is currently set to 1000, because this was the default maximum
    # value in Besu circa our 22.3.0 release. Previously, we've used 5000,
    # but this was effectively forcing the fallback logic in `syncBlockRange`
    # to always execute multiple requests before getting a successful response.
    #
    # Besu have raised this default to 5000 in https://github.com/hyperledger/besu/pull/5209
    # which is expected to ship in their next release.
    #
    # Full deposits sync time with various values for this parameter:
    #
    # Blocks per request | Geth running on the same host | Geth running on a more distant host
    # ----------------------------------------------------------------------------------------
    # 1000               |                      11m 20s  |                                 22m
    # 5000               |                       5m 20s  |                             15m 40s
    # 100000             |                       4m 10s  |                          not tested
    #
    # The number of requests scales linearly with the parameter value as you would expect.
    #
    # These results suggest that it would be reasonable for us to get back to 5000 once the
    # Besu release is well-spread within their userbase.

  # Engine API timeouts
  engineApiConnectionTimeout = 5.seconds  # How much we wait before giving up connecting to the Engine API
  web3RequestsTimeout* = 8.seconds # How much we wait for eth_* requests (e.g. eth_getBlockByHash)

  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.3/src/engine/paris.md#request-2
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.3/src/engine/shanghai.md#request-2
  GETPAYLOAD_TIMEOUT = 1.seconds

  connectionStateChangeHysteresisThreshold = 15
    ## How many unsuccesful/successful requests we must see
    ## before declaring the connection as degraded/restored

type
  NextExpectedPayloadParams* = object
    headBlockHash*: Eth2Digest
    safeBlockHash*: Eth2Digest
    finalizedBlockHash*: Eth2Digest
    payloadAttributes*: PayloadAttributesV3

  ELManagerState* {.pure.} = enum
    Running, Closing, Closed

  ELManager* = ref object
    eth1Network: Opt[Eth1Network]
      ## If this value is supplied the EL manager will check whether
      ## all configured EL nodes are connected to the same network.

    depositContractAddress*: Eth1Address
    depositContractBlockNumber: uint64
    depositContractBlockHash: Hash32

    blocksPerLogsRequest: uint64
      ## This value is used to dynamically adjust the number of
      ## blocks we are trying to download at once during deposit
      ## syncing. By default, the value is set to the constant
      ## `targetBlocksPerLogsRequest`, but if the EL is failing
      ## to serve this number of blocks per single `eth_getLogs`
      ## request, we temporarily lower the value until the request
      ## succeeds. The failures are generally expected only in
      ## periods in the history for very high deposit density.

    elConnections: seq[ELConnection]
      ## All active EL connections

    eth1Chain: Eth1Chain
      ## At larger distances, this chain consists of all blocks
      ## with deposits. Within the relevant voting period, it
      ## also includes blocks without deposits because we must
      ## vote for a block only if it's part of our known history.

    syncTargetBlock: Opt[Eth1BlockNumber]

    chainSyncingLoopFut: Future[void]
    exchangeTransitionConfigurationLoopFut: Future[void]
    managerState: ELManagerState

    nextExpectedPayloadParams*: Option[NextExpectedPayloadParams]

  EtcStatus {.pure.} = enum
    notExchangedYet
    mismatch
    match

  DepositContractSyncStatus {.pure.} = enum
    unknown
    notSynced
    synced

  ELConnectionState {.pure.} = enum
    NeverTested
    Working
    Degraded

  ELConnection* = ref object
    engineUrl: EngineApiUrl

    web3: Opt[Web3]
      ## This will be `none` before connecting and while we are
      ## reconnecting after a lost connetion. You can wait on
      ## the future below for the moment the connection is active.

    connectingFut: Future[Result[Web3, string]].Raising([CancelledError])
      ## This future will be replaced when the connection is lost.

    etcStatus: EtcStatus
      ## The latest status of the `exchangeTransitionConfiguration`
      ## exchange.

    state: ELConnectionState
    hysteresisCounter: int

    depositContractSyncStatus: DepositContractSyncStatus
      ## Are we sure that this EL has synced the deposit contract?

    lastPayloadId: Opt[Bytes8]

  FullBlockId* = object
    number: Eth1BlockNumber
    hash: Hash32

  DataProviderFailure* = object of CatchableError
  CorruptDataProvider* = object of DataProviderFailure
  DataProviderTimeout* = object of DataProviderFailure
  DataProviderConnectionFailure* = object of DataProviderFailure

  DisconnectHandler* = proc () {.gcsafe, raises: [].}

  DepositEventHandler* = proc (
    pubkey: PubKeyBytes,
    withdrawalCredentials: WithdrawalCredentialsBytes,
    amount: Int64LeBytes,
    signature: SignatureBytes,
    merkleTreeIndex: Int64LeBytes,
    j: JsonNode) {.gcsafe, raises: [].}

declareCounter failed_web3_requests,
  "Failed web3 requests"

declareGauge eth1_latest_head,
  "The highest Eth1 block number observed on the network"

declareGauge eth1_synced_head,
  "Block number of the highest synchronized block according to follow distance"

declareCounter engine_api_responses,
  "Number of successful requests to the newPayload Engine API end-point",
  labels = ["url", "request", "status"]

declareHistogram engine_api_request_duration_seconds,
  "Time(s) used to generate signature usign remote signer",
   buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
   labels = ["url", "request"]

declareCounter engine_api_timeouts,
  "Number of timed-out requests to Engine API end-point",
  labels = ["url", "request"]

declareCounter engine_api_last_minute_forkchoice_updates_sent,
  "Number of last minute requests to the forkchoiceUpdated Engine API end-point just before block proposals",
  labels = ["url"]

proc init*(t: typedesc[DeadlineObject], d: Duration): DeadlineObject =
  DeadlineObject(future: sleepAsync(d))

proc variedSleep*(
    counter: var int,
    durations: openArray[Duration]
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  doAssert(len(durations) > 0, "Empty durations array!")
  let index =
    if (counter < 0) or (counter > high(durations)):
      high(durations)
    else:
      counter
  inc(counter)
  sleepAsync(durations[index])

proc close(connection: ELConnection): Future[void] {.async: (raises: []).} =
  if connection.web3.isSome:
    try:
      let web3 = connection.web3.get
      await noCancel web3.close().wait(30.seconds)
    except AsyncTimeoutError:
      debug "Failed to close execution layer data provider in time",
            timeout = 30.seconds
    except CatchableError as exc:
      # TODO (cheatfate): This handler should be removed when `nim-web3` will
      # adopt `asyncraises`.
      debug "Failed to close execution layer", error = $exc.name,
            reason = $exc.msg

proc increaseCounterTowardsStateChange(connection: ELConnection): bool =
  result = connection.hysteresisCounter >= connectionStateChangeHysteresisThreshold
  if result:
    connection.hysteresisCounter = 0
  else:
    inc connection.hysteresisCounter

proc decreaseCounterTowardsStateChange(connection: ELConnection) =
  if connection.hysteresisCounter > 0:
    # While we increase the counter by 1, we decreate it by 20% in order
    # to require a steady and affirmative change instead of allowing
    # the counter to drift very slowly in one direction when the ratio
    # between success and failure is roughly 50:50%
    connection.hysteresisCounter = connection.hysteresisCounter div 5

proc setDegradedState(
    connection: ELConnection,
    requestName: string,
    statusCode: int,
    errMsg: string
): Future[void] {.async: (raises: []).} =
  debug "Failed EL Request", requestName, statusCode, err = errMsg
  case connection.state
  of ELConnectionState.NeverTested, ELConnectionState.Working:
    if connection.increaseCounterTowardsStateChange():
      warn "Connection to EL node degraded",
        url = url(connection.engineUrl),
        failedRequest = requestName,
        statusCode, err = errMsg

      connection.state = Degraded

      await connection.close()
      connection.web3 = Opt.none(Web3)
  of ELConnectionState.Degraded:
    connection.decreaseCounterTowardsStateChange()

proc setWorkingState(connection: ELConnection) =
  case connection.state
  of ELConnectionState.NeverTested:
    connection.hysteresisCounter = 0
    connection.state = Working
  of ELConnectionState.Degraded:
    if connection.increaseCounterTowardsStateChange():
      info "Connection to EL node restored",
        url = url(connection.engineUrl)
      connection.state = Working
  of ELConnectionState.Working:
    connection.decreaseCounterTowardsStateChange()

proc engineApiRequest[T](
    connection: ELConnection,
    request: Future[T],
    requestName: string,
    startTime: Moment,
    deadline: Future[void] | Duration | WithoutTimeout,
    failureAllowed = false
): Future[T] {.async: (raises: [CatchableError]).} =
  ## This procedure raises `CancelledError` and `DataProviderTimeout`
  ## exceptions, and everything which `request` could raise.
  try:
    let res =
      when deadline is WithoutTimeout:
        await request
      else:
        await request.wait(deadline)
    engine_api_request_duration_seconds.observe(
      float(milliseconds(Moment.now - startTime)) / 1000.0,
        [connection.engineUrl.url, requestName])
    engine_api_responses.inc(
      1, [connection.engineUrl.url, requestName, "200"])
    connection.setWorkingState()
    res
  except AsyncTimeoutError:
    engine_api_timeouts.inc(1, [connection.engineUrl.url, requestName])
    if not(failureAllowed):
      await connection.setDegradedState(requestName, 0, "Request timed out")
    raise newException(DataProviderTimeout, "Request timed out")
  except CancelledError as exc:
    when deadline is WithoutTimeout:
      # When `deadline` is set to `noTimeout`, we usually get cancelled on
      # timeout which was handled by caller.
      engine_api_timeouts.inc(1, [connection.engineUrl.url, requestName])
      if not(failureAllowed):
        await connection.setDegradedState(requestName, 0, "Request timed out")
    else:
      if not(failureAllowed):
        await connection.setDegradedState(requestName, 0, "Request interrupted")
    raise exc
  except CatchableError as exc:
    let statusCode =
      if request.error of ErrorResponse:
        ((ref ErrorResponse) request.error).status
      else:
        0
    engine_api_responses.inc(
      1, [connection.engineUrl.url, requestName, $statusCode])
    if not(failureAllowed):
      await connection.setDegradedState(
        requestName, statusCode, request.error.msg)
    raise exc

func raiseIfNil(web3block: BlockObject): BlockObject {.raises: [ValueError].} =
  if web3block == nil:
    raise newException(ValueError, "EL returned 'null' result for block")
  web3block

template cfg(m: ELManager): auto =
  m.eth1Chain.cfg

func hasJwtSecret*(m: ELManager): bool =
  for c in m.elConnections:
    if c.engineUrl.jwtSecret.isSome:
      return true

func isSynced*(m: ELManager): bool =
  m.syncTargetBlock.isSome and
  m.eth1Chain.blocks.len > 0 and
  m.syncTargetBlock.get <= m.eth1Chain.blocks[^1].number

template eth1ChainBlocks*(m: ELManager): Deque[Eth1Block] =
  m.eth1Chain.blocks

# TODO: Add cfg validation
# MIN_GENESIS_ACTIVE_VALIDATOR_COUNT should be larger than SLOTS_PER_EPOCH
#  doAssert SECONDS_PER_ETH1_BLOCK * cfg.ETH1_FOLLOW_DISTANCE < GENESIS_DELAY,
#             "Invalid configuration: GENESIS_DELAY is set too low"

func isConnected(connection: ELConnection): bool =
  connection.web3.isSome

func getJsonRpcRequestHeaders(jwtSecret: Opt[seq[byte]]):
    auto =
  if jwtSecret.isSome:
    let secret = jwtSecret.get
    (proc(): seq[(string, string)] =
      # https://www.rfc-editor.org/rfc/rfc6750#section-6.1.1
      @[("Authorization", "Bearer " & getSignedIatToken(
        secret, (getTime() - initTime(0, 0)).inSeconds))])
  else:
    (proc(): seq[(string, string)] = @[])

proc newWeb3*(engineUrl: EngineApiUrl): Future[Web3] =
  newWeb3(engineUrl.url,
          getJsonRpcRequestHeaders(engineUrl.jwtSecret), httpFlags = {})

proc establishEngineApiConnection(url: EngineApiUrl):
                                  Future[Result[Web3, string]] {.
                                  async: (raises: [CancelledError]).} =
  try:
    ok(await newWeb3(url).wait(engineApiConnectionTimeout))
  except AsyncTimeoutError:
    err "Engine API connection timed out"
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    err exc.msg

proc tryConnecting(connection: ELConnection): Future[bool] {.
     async: (raises: [CancelledError]).} =
  if connection.isConnected:
    return true

  if connection.connectingFut == nil or
     connection.connectingFut.finished: # The previous attempt was not successful
    connection.connectingFut =
      establishEngineApiConnection(connection.engineUrl)

  let web3Res = await connection.connectingFut
  if web3Res.isErr:
    warn "Engine API connection failed", err = web3Res.error
    false
  else:
    connection.web3 = Opt.some(web3Res.get)
    true

proc connectedRpcClient(connection: ELConnection): Future[RpcClient] {.
     async: (raises: [CancelledError]).} =
  while not connection.isConnected:
    if not(await connection.tryConnecting()):
      await sleepAsync(chronos.seconds(10))

  connection.web3.get.provider

proc getBlockByHash(
    rpcClient: RpcClient,
    hash: Hash32
): Future[BlockObject] {.async: (raises: [CatchableError]).} =
  await rpcClient.eth_getBlockByHash(hash, false)

proc getBlockByNumber*(
    rpcClient: RpcClient,
    number: Eth1BlockNumber
): Future[BlockObject] {.async: (raises: [CatchableError]).} =
  let hexNumber = try:
    let num = distinctBase(number)
    &"0x{num:X}" # No leading 0's!
  except ValueError as exc:
    # Since the format above is valid, failing here should not be possible
    raiseAssert exc.msg

  await rpcClient.eth_getBlockByNumber(hexNumber, false)

func areSameAs(expectedParams: Option[NextExpectedPayloadParams],
               latestHead, latestSafe, latestFinalized: Eth2Digest,
               timestamp: uint64,
               randomData: Eth2Digest,
               feeRecipient: Eth1Address,
               withdrawals: seq[WithdrawalV1]): bool =
  expectedParams.isSome and
    expectedParams.get.headBlockHash == latestHead and
    expectedParams.get.safeBlockHash == latestSafe and
    expectedParams.get.finalizedBlockHash == latestFinalized and
    expectedParams.get.payloadAttributes.timestamp.uint64 == timestamp and
    expectedParams.get.payloadAttributes.prevRandao.data == randomData.data and
    expectedParams.get.payloadAttributes.suggestedFeeRecipient == feeRecipient and
    expectedParams.get.payloadAttributes.withdrawals == withdrawals

proc forkchoiceUpdated(rpcClient: RpcClient,
                       state: ForkchoiceStateV1,
                       payloadAttributes: Opt[PayloadAttributesV1] |
                                          Opt[PayloadAttributesV2] |
                                          Opt[PayloadAttributesV3]):
                       Future[ForkchoiceUpdatedResponse] =
  when payloadAttributes is Opt[PayloadAttributesV1]:
    rpcClient.engine_forkchoiceUpdatedV1(state, payloadAttributes)
  elif payloadAttributes is Opt[PayloadAttributesV2]:
    rpcClient.engine_forkchoiceUpdatedV2(state, payloadAttributes)
  elif payloadAttributes is Opt[PayloadAttributesV3]:
    rpcClient.engine_forkchoiceUpdatedV3(state, payloadAttributes)
  else:
    static: doAssert false

proc getPayloadFromSingleEL(
    connection: ELConnection,
    GetPayloadResponseType: type,
    isForkChoiceUpToDate: bool,
    consensusHead: Eth2Digest,
    headBlock, safeBlock, finalizedBlock: Eth2Digest,
    timestamp: uint64,
    randomData: Eth2Digest,
    suggestedFeeRecipient: Eth1Address,
    withdrawals: seq[WithdrawalV1]
): Future[GetPayloadResponseType] {.async: (raises: [CatchableError]).} =

  let
    rpcClient = await connection.connectedRpcClient()
    payloadId = if isForkChoiceUpToDate and connection.lastPayloadId.isSome:
      connection.lastPayloadId.get
    elif not headBlock.isZero:
      engine_api_last_minute_forkchoice_updates_sent.inc(1, [connection.engineUrl.url])

      when GetPayloadResponseType is BellatrixExecutionPayloadWithValue:
        let response = await rpcClient.forkchoiceUpdated(
          ForkchoiceStateV1(
            headBlockHash: headBlock.asBlockHash,
            safeBlockHash: safeBlock.asBlockHash,
            finalizedBlockHash: finalizedBlock.asBlockHash),
          Opt.some PayloadAttributesV1(
            timestamp: Quantity timestamp,
            prevRandao: FixedBytes[32] randomData.data,
            suggestedFeeRecipient: suggestedFeeRecipient))
      elif GetPayloadResponseType is engine_api.GetPayloadV2Response:
        let response = await rpcClient.forkchoiceUpdated(
          ForkchoiceStateV1(
            headBlockHash: headBlock.asBlockHash,
            safeBlockHash: safeBlock.asBlockHash,
            finalizedBlockHash: finalizedBlock.asBlockHash),
          Opt.some PayloadAttributesV2(
            timestamp: Quantity timestamp,
            prevRandao: FixedBytes[32] randomData.data,
            suggestedFeeRecipient: suggestedFeeRecipient,
            withdrawals: withdrawals))
      elif  GetPayloadResponseType is engine_api.GetPayloadV3Response or
            GetPayloadResponseType is engine_api.GetPayloadV4Response:
        # https://github.com/ethereum/execution-apis/blob/90a46e9137c89d58e818e62fa33a0347bba50085/src/engine/prague.md
        # does not define any new forkchoiceUpdated, so reuse V3 from Dencun
        let response = await rpcClient.forkchoiceUpdated(
          ForkchoiceStateV1(
            headBlockHash: headBlock.asBlockHash,
            safeBlockHash: safeBlock.asBlockHash,
            finalizedBlockHash: finalizedBlock.asBlockHash),
          Opt.some PayloadAttributesV3(
            timestamp: Quantity timestamp,
            prevRandao: FixedBytes[32] randomData.data,
            suggestedFeeRecipient: suggestedFeeRecipient,
            withdrawals: withdrawals,
            parentBeaconBlockRoot: consensusHead.to(Hash32)))
      else:
        static: doAssert false

      if response.payloadStatus.status != PayloadExecutionStatus.valid or
         response.payloadId.isNone:
        raise newException(CatchableError, "Head block is not a valid payload")

      # Give the EL some time to assemble the block
      await sleepAsync(chronos.milliseconds 500)

      response.payloadId.get
    else:
      raise newException(CatchableError, "No confirmed execution head yet")

  when GetPayloadResponseType is BellatrixExecutionPayloadWithValue:
    let payload =
      await engine_api.getPayload(rpcClient, ExecutionPayloadV1, payloadId)
    return BellatrixExecutionPayloadWithValue(
      executionPayload: payload, blockValue: Wei.zero)
  else:
    return await engine_api.getPayload(
      rpcClient, GetPayloadResponseType, payloadId)

func cmpGetPayloadResponses(lhs, rhs: SomeEnginePayloadWithValue): int =
  cmp(distinctBase lhs.blockValue, distinctBase rhs.blockValue)

template EngineApiResponseType*(T: type bellatrix.ExecutionPayloadForSigning): type =
  BellatrixExecutionPayloadWithValue

template EngineApiResponseType*(T: type capella.ExecutionPayloadForSigning): type =
  engine_api.GetPayloadV2Response

template EngineApiResponseType*(T: type deneb.ExecutionPayloadForSigning): type =
  engine_api.GetPayloadV3Response

template EngineApiResponseType*(T: type electra.ExecutionPayloadForSigning): type =
  engine_api.GetPayloadV4Response

template EngineApiResponseType*(T: type fulu.ExecutionPayloadForSigning): type =
  engine_api.GetPayloadV4Response

template toEngineWithdrawals*(withdrawals: seq[capella.Withdrawal]): seq[WithdrawalV1] =
  mapIt(withdrawals, toEngineWithdrawal(it))

template kind(T: type ExecutionPayloadV1): ConsensusFork =
  ConsensusFork.Bellatrix

template kind(T: typedesc[ExecutionPayloadV1OrV2|ExecutionPayloadV2]): ConsensusFork =
  ConsensusFork.Capella

template kind(T: type ExecutionPayloadV3): ConsensusFork =
  ConsensusFork.Deneb

proc getPayload*(
    m: ELManager,
    PayloadType: type ForkyExecutionPayloadForSigning,
    consensusHead: Eth2Digest,
    headBlock, safeBlock, finalizedBlock: Eth2Digest,
    timestamp: uint64,
    randomData: Eth2Digest,
    suggestedFeeRecipient: Eth1Address,
    withdrawals: seq[capella.Withdrawal]
): Future[Opt[PayloadType]] {.async: (raises: [CancelledError]).} =
  if m.elConnections.len == 0:
    return err()

  let
    engineApiWithdrawals = toEngineWithdrawals withdrawals
    isFcUpToDate = m.nextExpectedPayloadParams.areSameAs(
      headBlock, safeBlock, finalizedBlock, timestamp,
      randomData, suggestedFeeRecipient, engineApiWithdrawals)

  # `getPayloadFromSingleEL` may introduce additional latency
  const extraProcessingOverhead = 500.milliseconds
  let
    timeout = GETPAYLOAD_TIMEOUT + extraProcessingOverhead
    deadline = sleepAsync(timeout)

  var bestPayloadIdx = Opt.none(int)

  while true:
    let requests =
      m.elConnections.mapIt(
        it.getPayloadFromSingleEL(EngineApiResponseType(PayloadType),
          isFcUpToDate, consensusHead, headBlock, safeBlock, finalizedBlock,
          timestamp, randomData, suggestedFeeRecipient, engineApiWithdrawals))

    let timeoutExceeded =
      try:
        await allFutures(requests).wait(deadline)
        false
      except AsyncTimeoutError:
        true
      except CancelledError as exc:
        let pending =
          requests.filterIt(not(it.finished())).mapIt(it.cancelAndWait())
        await noCancel allFutures(pending)
        raise exc

    for idx, req in requests:
      if not(req.finished()):
        warn "Timeout while getting execution payload",
             url = m.elConnections[idx].engineUrl.url
      elif req.failed():
        warn "Failed to get execution payload from EL",
             url = m.elConnections[idx].engineUrl.url,
             reason = req.error.msg
      else:
        const payloadFork = PayloadType.kind
        when payloadFork >= ConsensusFork.Capella:
          when payloadFork == ConsensusFork.Capella:
            # TODO: The engine_api module may offer an alternative API where
            # it is guaranteed to return the correct response type (i.e. the
            # rule below will be enforced during deserialization).
            if req.value().executionPayload.withdrawals.isNone:
              warn "Execution client returned a block without a " &
                   "'withdrawals' field for a post-Shanghai block",
                    url = m.elConnections[idx].engineUrl.url
              continue

          if engineApiWithdrawals !=
             req.value().executionPayload.withdrawals.maybeDeref:
            # otherwise it formats as "@[(index: ..., validatorIndex: ...,
            # address: ..., amount: ...), (index: ..., validatorIndex: ...,
            # address: ..., amount: ...)]"
            # TODO (cheatfate): should we have `continue` statement at the
            # end of this branch. If no such payload could be choosen as
            # best one.
            warn "Execution client did not return correct withdrawals",
              withdrawals_from_cl_len = engineApiWithdrawals.len,
              withdrawals_from_el_len =
                req.value().executionPayload.withdrawals.maybeDeref.len,
              withdrawals_from_cl =
                mapIt(engineApiWithdrawals, it.asConsensusWithdrawal),
              withdrawals_from_el =
                mapIt(
                  req.value().executionPayload.withdrawals.maybeDeref,
                  it.asConsensusWithdrawal),
              url = m.elConnections[idx].engineUrl.url
            # If we have more than one EL connection we consider this as
            # a failure.
            if len(requests) > 1:
              continue

        if req.value().executionPayload.extraData.len > MAX_EXTRA_DATA_BYTES:
          warn "Execution client provided a block with invalid extraData " &
               "(size exceeds limit)",
               url = m.elConnections[idx].engineUrl.url,
               size = req.value().executionPayload.extraData.len,
               limit = MAX_EXTRA_DATA_BYTES
          continue

        if bestPayloadIdx.isNone:
          bestPayloadIdx = Opt.some(idx)
        else:
          if cmpGetPayloadResponses(
               req.value(), requests[bestPayloadIdx.get].value()) > 0:
            bestPayloadIdx = Opt.some(idx)

    let pending =
      requests.filterIt(not(it.finished())).mapIt(it.cancelAndWait())
    await noCancel allFutures(pending)

    when PayloadType.kind == ConsensusFork.Fulu:
      if bestPayloadIdx.isSome():
        return ok(requests[bestPayloadIdx.get()].value().asConsensusTypeFulu)
    else:
      if bestPayloadIdx.isSome():
        return ok(requests[bestPayloadIdx.get()].value().asConsensusType)

    if timeoutExceeded:
      break

  err()

proc waitELToSyncDeposits(
    connection: ELConnection,
    minimalRequiredBlock: Hash32
) {.async: (raises: [CancelledError]).} =
  var rpcClient: RpcClient = nil

  if connection.depositContractSyncStatus == DepositContractSyncStatus.synced:
    return

  var attempt = 0

  while true:
    if isNil(rpcClient):
      rpcClient = await connection.connectedRpcClient()

    try:
      discard raiseIfNil await connection.engineApiRequest(
        rpcClient.getBlockByHash(minimalRequiredBlock),
        "getBlockByHash", Moment.now(),
        web3RequestsTimeout, failureAllowed = true)
      connection.depositContractSyncStatus = DepositContractSyncStatus.synced
      return
    except CancelledError as exc:
      trace "waitELToSyncDepositContract interrupted",
             url = connection.engineUrl.url
      raise exc
    except CatchableError as exc:
      connection.depositContractSyncStatus = DepositContractSyncStatus.notSynced
      if attempt == 0:
        warn "Failed to obtain the most recent known block from the " &
             "execution layer node (the node is probably not synced)",
             url = connection.engineUrl.url,
             blk = minimalRequiredBlock,
             reason = exc.msg
      elif attempt mod 60 == 0:
        # This warning will be produced every 30 minutes
        warn "Still failing to obtain the most recent known block from the " &
             "execution layer node (the node is probably still not synced)",
             url = connection.engineUrl.url,
             blk = minimalRequiredBlock,
             reason = exc.msg
      inc(attempt)
      await sleepAsync(seconds(30))
      rpcClient = nil

func networkHasDepositContract(m: ELManager): bool =
  not m.cfg.DEPOSIT_CONTRACT_ADDRESS.isDefaultValue

func mostRecentKnownBlock(m: ELManager): Hash32 =
  if m.eth1Chain.finalizedDepositsMerkleizer.getChunkCount() > 0:
    m.eth1Chain.finalizedBlockHash.asBlockHash
  else:
    m.depositContractBlockHash

proc selectConnectionForChainSyncing(
    m: ELManager
): Future[ELConnection] {.async: (raises: [CancelledError,
                                           DataProviderConnectionFailure]).} =
  doAssert m.elConnections.len > 0

  let pendingConnections = m.elConnections.mapIt(
    if m.networkHasDepositContract:
      FutureBase waitELToSyncDeposits(it, m.mostRecentKnownBlock)
    else:
      FutureBase connectedRpcClient(it))

  while true:
    var pendingFutures = pendingConnections
    try:
      discard await race(pendingFutures)
    except ValueError:
      raiseAssert "pendingFutures should not be empty at this moment"
    except CancelledError as exc:
      let pending = pendingConnections.filterIt(not(it.finished())).
                      mapIt(it.cancelAndWait())
      await noCancel allFutures(pending)
      raise exc

    pendingFutures.reset()
    for index, future in pendingConnections.pairs():
      if future.completed():
        let pending = pendingConnections.filterIt(not(it.finished())).
                        mapIt(it.cancelAndWait())
        await noCancel allFutures(pending)
        return m.elConnections[index]
      elif not(future.finished()):
        pendingFutures.add(future)

    if len(pendingFutures) == 0:
      raise newException(DataProviderConnectionFailure,
                         "Unable to establish connection for chain syncing")

proc sendNewPayloadToSingleEL(
    connection: ELConnection,
    payload: engine_api.ExecutionPayloadV1
): Future[PayloadStatusV1] {.async: (raises: [CatchableError]).} =
  let rpcClient = await connection.connectedRpcClient()
  await rpcClient.engine_newPayloadV1(payload)

proc sendNewPayloadToSingleEL(
    connection: ELConnection,
    payload: engine_api.ExecutionPayloadV2
): Future[PayloadStatusV1] {.async: (raises: [CatchableError]).} =
  let rpcClient = await connection.connectedRpcClient()
  await rpcClient.engine_newPayloadV2(payload)

proc sendNewPayloadToSingleEL(
    connection: ELConnection,
    payload: engine_api.ExecutionPayloadV3,
    versioned_hashes: seq[engine_api.VersionedHash],
    parent_beacon_block_root: FixedBytes[32]
): Future[PayloadStatusV1] {.async: (raises: [CatchableError]).} =
  let rpcClient = await connection.connectedRpcClient()
  await rpcClient.engine_newPayloadV3(
    payload, versioned_hashes, Hash32 parent_beacon_block_root)

proc sendNewPayloadToSingleEL(
    connection: ELConnection,
    payload: engine_api.ExecutionPayloadV3,
    versioned_hashes: seq[engine_api.VersionedHash],
    parent_beacon_block_root: FixedBytes[32],
    executionRequests: seq[seq[byte]]
): Future[PayloadStatusV1] {.async: (raises: [CatchableError]).} =
  let rpcClient = await connection.connectedRpcClient()
  await rpcClient.engine_newPayloadV4(
    payload, versioned_hashes, Hash32 parent_beacon_block_root,
    executionRequests)

type
  StatusRelation = enum
    newStatusIsPreferable
    oldStatusIsOk
    disagreement

func compareStatuses(
    newStatus, prevStatus: PayloadExecutionStatus
): StatusRelation =
  case prevStatus
  of PayloadExecutionStatus.syncing:
    if newStatus == PayloadExecutionStatus.syncing:
      oldStatusIsOk
    else:
      newStatusIsPreferable

  of PayloadExecutionStatus.valid:
    case newStatus
    of PayloadExecutionStatus.syncing,
       PayloadExecutionStatus.accepted,
       PayloadExecutionStatus.valid:
      oldStatusIsOk
    of PayloadExecutionStatus.invalid_block_hash,
       PayloadExecutionStatus.invalid:
      disagreement

  of PayloadExecutionStatus.invalid:
    case newStatus
    of PayloadExecutionStatus.syncing,
       PayloadExecutionStatus.invalid:
      oldStatusIsOk
    of PayloadExecutionStatus.valid,
       PayloadExecutionStatus.accepted,
       PayloadExecutionStatus.invalid_block_hash:
      disagreement

  of PayloadExecutionStatus.accepted:
    case newStatus
    of PayloadExecutionStatus.accepted,
       PayloadExecutionStatus.syncing:
      oldStatusIsOk
    of PayloadExecutionStatus.valid:
      newStatusIsPreferable
    of PayloadExecutionStatus.invalid_block_hash,
       PayloadExecutionStatus.invalid:
      disagreement

  of PayloadExecutionStatus.invalid_block_hash:
    if newStatus == PayloadExecutionStatus.invalid_block_hash:
      oldStatusIsOk
    else:
      disagreement

type
  ELConsensusViolationDetector = object
    selectedResponse: Opt[int]
    disagreementAlreadyDetected: bool

func init(T: type ELConsensusViolationDetector): T =
  ELConsensusViolationDetector(
    selectedResponse: Opt.none(int),
    disagreementAlreadyDetected: false
  )

proc processResponse(
    d: var ELConsensusViolationDetector,
    elResponseType: typedesc,
    connections: openArray[ELConnection],
    requests: auto,
    idx: int) =

  if not requests[idx].completed:
    return

  let status = requests[idx].value().status
  if d.selectedResponse.isNone:
    d.selectedResponse = Opt.some(idx)
  elif not d.disagreementAlreadyDetected:
    let prevStatus = requests[d.selectedResponse.get].value().status
    case compareStatuses(status, prevStatus)
    of newStatusIsPreferable:
      d.selectedResponse = Opt.some(idx)
    of oldStatusIsOk:
      discard
    of disagreement:
      d.disagreementAlreadyDetected = true
      error "Execution layer consensus violation detected",
            responseType = name(elResponseType),
            url1 = connections[d.selectedResponse.get].engineUrl.url,
            status1 = prevStatus,
            url2 = connections[idx].engineUrl.url,
            status2 = status

proc lazyWait(futures: seq[FutureBase]) {.async: (raises: []).} =
  block:
    let pending = futures.filterIt(not(it.finished()))
    if len(pending) > 0:
      try:
        await allFutures(pending).wait(30.seconds)
      except CancelledError:
        discard
      except AsyncTimeoutError:
        discard

  block:
    let pending = futures.filterIt(not(it.finished())).mapIt(it.cancelAndWait())
    if len(pending) > 0:
      await noCancel allFutures(pending)

proc sendNewPayload*(
    m: ELManager,
    blck: SomeForkyBeaconBlock,
    deadlineObj: DeadlineObject,
    maxRetriesCount: int
): Future[PayloadExecutionStatus] {.async: (raises: [CancelledError]).} =
  doAssert maxRetriesCount > 0

  let
    startTime = Moment.now()
    deadline = deadlineObj.future
    payload = blck.body.asEngineExecutionPayload
  var
    responseProcessor = ELConsensusViolationDetector.init()
    sleepCounter = 0
    retriesCount = 0

  while true:
    block mainLoop:
      let
        requests = m.elConnections.mapIt:
          let req =
            when typeof(blck).kind >= ConsensusFork.Electra:
              # https://github.com/ethereum/execution-apis/blob/4140e528360fea53c34a766d86a000c6c039100e/src/engine/prague.md#engine_newpayloadv4
              let
                versioned_hashes = mapIt(
                  blck.body.blob_kzg_commitments,
                  engine_api.VersionedHash(kzg_commitment_to_versioned_hash(it)))
                # https://github.com/ethereum/execution-apis/blob/7c9772f95c2472ccfc6f6128dc2e1b568284a2da/src/engine/prague.md#request
                # "Each list element is a `requests` byte array as defined by
                # EIP-7685. The first byte of each element is the `request_type`
                # and the remaining bytes are the `request_data`. Elements of
                # the list MUST be ordered by `request_type` in ascending order.
                # Elements with empty `request_data` MUST be excluded from the
                # list."
                execution_requests = block:
                  var requests: seq[seq[byte]]
                  for request_type, request_data in
                      [SSZ.encode(blck.body.execution_requests.deposits),
                       SSZ.encode(blck.body.execution_requests.withdrawals),
                       SSZ.encode(blck.body.execution_requests.consolidations)]:
                    if request_data.len > 0:
                      requests.add @[request_type.byte] & request_data
                  requests

              sendNewPayloadToSingleEL(
                it, payload, versioned_hashes,
                FixedBytes[32] blck.parent_root.data, execution_requests)
            elif typeof(blck).kind == ConsensusFork.Deneb:
              # https://github.com/ethereum/consensus-specs/blob/v1.4.0-alpha.1/specs/deneb/beacon-chain.md#process_execution_payload
              # Verify the execution payload is valid
              # [Modified in Deneb] Pass `versioned_hashes` to Execution Engine
              let versioned_hashes = mapIt(
                blck.body.blob_kzg_commitments,
                engine_api.VersionedHash(kzg_commitment_to_versioned_hash(it)))
              sendNewPayloadToSingleEL(
                it, payload, versioned_hashes,
                FixedBytes[32] blck.parent_root.data)
            elif typeof(blck).kind in [ConsensusFork.Bellatrix, ConsensusFork.Capella]:
              sendNewPayloadToSingleEL(it, payload)
            else:
              static: doAssert false
          engineApiRequest(it, req, "newPayload", startTime, noTimeout)

      var pendingRequests = requests

      while true:
        let timeoutExceeded =
          try:
            discard await race(pendingRequests).wait(deadline)
            false
          except AsyncTimeoutError:
            true
          except ValueError:
            raiseAssert "pendingRequests should not be empty!"
          except CancelledError as exc:
            let pending =
              requests.filterIt(not(it.finished())).mapIt(it.cancelAndWait())
            await noCancel allFutures(pending)
            raise exc

        var stillPending: type(pendingRequests)
        for request in pendingRequests:
          if not(request.finished()):
            stillPending.add(request)
          elif request.completed():
            let index = requests.find(request)
            doAssert(index >= 0)
            responseProcessor.processResponse(type(payload),
                                              m.elConnections, requests, index)
        pendingRequests = stillPending

        if responseProcessor.disagreementAlreadyDetected:
          let pending =
            pendingRequests.filterIt(not(it.finished())).
              mapIt(it.cancelAndWait())
          await noCancel allFutures(pending)
          return PayloadExecutionStatus.invalid
        elif responseProcessor.selectedResponse.isSome():
          # We spawn task which will wait for all other responses which are
          # still pending, after 30.seconds all pending requests will be
          # cancelled.
          asyncSpawn lazyWait(pendingRequests.mapIt(FutureBase(it)))
          return requests[responseProcessor.selectedResponse.get].value().status

        if timeoutExceeded:
          # Timeout exceeded, cancelling all pending requests.
          let pending =
            pendingRequests.filterIt(not(it.finished())).
              mapIt(it.cancelAndWait())
          await noCancel allFutures(pending)
          return PayloadExecutionStatus.syncing

        if len(pendingRequests) == 0:
          # All requests failed.
          inc(retriesCount)
          if retriesCount == maxRetriesCount:
            return PayloadExecutionStatus.syncing

          # To avoid continous spam of requests when EL node is offline we
          # going to sleep until next attempt.
          await variedSleep(sleepCounter, SleepDurations)
          break mainLoop

proc sendNewPayload*(
    m: ELManager,
    blck: SomeForkyBeaconBlock
): Future[PayloadExecutionStatus] {.
    async: (raises: [CancelledError], raw: true).} =
  sendNewPayload(m, blck, DeadlineObject.init(NEWPAYLOAD_TIMEOUT), high(int))

proc forkchoiceUpdatedForSingleEL(
    connection: ELConnection,
    state: ref ForkchoiceStateV1,
    payloadAttributes: Opt[PayloadAttributesV1] |
                       Opt[PayloadAttributesV2] |
                       Opt[PayloadAttributesV3]
): Future[PayloadStatusV1] {.async: (raises: [CatchableError]).} =
  let
    rpcClient = await connection.connectedRpcClient()
    response = await rpcClient.forkchoiceUpdated(state[], payloadAttributes)

  if response.payloadStatus.status notin {syncing, valid, invalid}:
    debug "Invalid fork-choice updated response from the EL",
          payloadStatus = response.payloadStatus
    return

  if response.payloadStatus.status == PayloadExecutionStatus.valid and
     response.payloadId.isSome:
    connection.lastPayloadId = response.payloadId

  return response.payloadStatus

proc forkchoiceUpdated*(
    m: ELManager,
    headBlockHash, safeBlockHash, finalizedBlockHash: Eth2Digest,
    payloadAttributes: Opt[PayloadAttributesV1] |
                       Opt[PayloadAttributesV2] |
                       Opt[PayloadAttributesV3],
    deadlineObj: DeadlineObject,
    maxRetriesCount: int
): Future[(PayloadExecutionStatus, Opt[Hash32])] {.
   async: (raises: [CancelledError]).} =

  doAssert not headBlockHash.isZero
  doAssert maxRetriesCount > 0

  # Allow finalizedBlockHash to be 0 to avoid sync deadlocks.
  #
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-3675.md#pos-events
  # has "Before the first finalized block occurs in the system the finalized
  # block hash provided by this event is stubbed with
  # `0x0000000000000000000000000000000000000000000000000000000000000000`."
  # and
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.10/specs/bellatrix/validator.md#executionpayload
  # notes "`finalized_block_hash` is the hash of the latest finalized execution
  # payload (`Hash32()` if none yet finalized)"

  if m.elConnections.len == 0:
    return (PayloadExecutionStatus.syncing, Opt.none Hash32)

  when payloadAttributes is Opt[PayloadAttributesV3]:
    template payloadAttributesV3(): auto =
      if payloadAttributes.isSome:
        payloadAttributes.get
      else:
        # As timestamp and prevRandao are both 0, won't false-positive match
        (static(default(PayloadAttributesV3)))
  elif payloadAttributes is Opt[PayloadAttributesV2]:
    template payloadAttributesV3(): auto =
      if payloadAttributes.isSome:
        PayloadAttributesV3(
          timestamp: payloadAttributes.get.timestamp,
          prevRandao: payloadAttributes.get.prevRandao,
          suggestedFeeRecipient: payloadAttributes.get.suggestedFeeRecipient,
          withdrawals: payloadAttributes.get.withdrawals,
          parentBeaconBlockRoot: default(Hash32))
      else:
        # As timestamp and prevRandao are both 0, won't false-positive match
        (static(default(PayloadAttributesV3)))
  elif payloadAttributes is Opt[PayloadAttributesV1]:
    template payloadAttributesV3(): auto =
      if payloadAttributes.isSome:
        PayloadAttributesV3(
          timestamp: payloadAttributes.get.timestamp,
          prevRandao: payloadAttributes.get.prevRandao,
          suggestedFeeRecipient: payloadAttributes.get.suggestedFeeRecipient,
          withdrawals: @[],
          parentBeaconBlockRoot: default(Hash32))
      else:
        # As timestamp and prevRandao are both 0, won't false-positive match
        (static(default(PayloadAttributesV3)))
  else:
    static: doAssert false

  let
    state = newClone ForkchoiceStateV1(
      headBlockHash: headBlockHash.asBlockHash,
      safeBlockHash: safeBlockHash.asBlockHash,
      finalizedBlockHash: finalizedBlockHash.asBlockHash)
    startTime = Moment.now
    deadline = deadlineObj.future

  var
    responseProcessor = ELConsensusViolationDetector.init()
    sleepCounter = 0
    retriesCount = 0

  while true:
    block mainLoop:
      let requests =
        m.elConnections.mapIt:
          let req = it.forkchoiceUpdatedForSingleEL(state, payloadAttributes)
          engineApiRequest(it, req, "forkchoiceUpdated", startTime, noTimeout)

      var pendingRequests = requests

      while true:
        let timeoutExceeded =
          try:
            discard await race(pendingRequests).wait(deadline)
            false
          except ValueError:
            raiseAssert "pendingRequests should not be empty!"
          except AsyncTimeoutError:
            true
          except CancelledError as exc:
            let pending =
              pendingRequests.filterIt(not(it.finished())).
                mapIt(it.cancelAndWait())
            await noCancel allFutures(pending)
            raise exc

        var stillPending: type(pendingRequests)
        for request in pendingRequests:
          if not(request.finished()):
            stillPending.add(request)
          elif request.completed():
            let index = requests.find(request)
            doAssert(index >= 0)
            responseProcessor.processResponse(
              PayloadStatusV1, m.elConnections, requests, index)
        pendingRequests = stillPending

        template assignNextExpectedPayloadParams() =
          # Ensure that there's no race condition window where getPayload's
          # check for whether it needs to trigger a new fcU payload, due to
          # cache invalidation, falsely suggests that the expected payload
          # matches, and similarly that if the fcU fails or times out for other
          # reasons, the expected payload params remain synchronized with
          # EL state.
          assign(
            m.nextExpectedPayloadParams,
            some NextExpectedPayloadParams(
              headBlockHash: headBlockHash,
              safeBlockHash: safeBlockHash,
              finalizedBlockHash: finalizedBlockHash,
              payloadAttributes: payloadAttributesV3))

        template getSelected: untyped =
          let data = requests[responseProcessor.selectedResponse.get].value()
          (data.status, data.latestValidHash)

        if responseProcessor.disagreementAlreadyDetected:
          let pending =
            pendingRequests.filterIt(not(it.finished())).
              mapIt(it.cancelAndWait())
          await noCancel allFutures(pending)
          return (PayloadExecutionStatus.invalid, Opt.none Hash32)
        elif responseProcessor.selectedResponse.isSome:
          # We spawn task which will wait for all other responses which are
          # still pending, after 30.seconds all pending requests will be
          # cancelled.
          asyncSpawn lazyWait(pendingRequests.mapIt(FutureBase(it)))
          assignNextExpectedPayloadParams()
          return getSelected()

        if timeoutExceeded:
          # Timeout exceeded, cancelling all pending requests.
          let pending =
            pendingRequests.filterIt(not(it.finished())).
              mapIt(it.cancelAndWait())
          await noCancel allFutures(pending)
          return (PayloadExecutionStatus.syncing, Opt.none Hash32)

        if len(pendingRequests) == 0:
          # All requests failed, we will continue our attempts until deadline
          # is not finished.
          inc(retriesCount)
          if retriesCount == maxRetriesCount:
            return (PayloadExecutionStatus.syncing, Opt.none Hash32)

          # To avoid continous spam of requests when EL node is offline we
          # going to sleep until next attempt.
          await variedSleep(sleepCounter, SleepDurations)
          break mainLoop

proc forkchoiceUpdated*(
    m: ELManager,
    headBlockHash, safeBlockHash, finalizedBlockHash: Eth2Digest,
    payloadAttributes: Opt[PayloadAttributesV1] |
                       Opt[PayloadAttributesV2] |
                       Opt[PayloadAttributesV3]
): Future[(PayloadExecutionStatus, Opt[Hash32])] {.
    async: (raises: [CancelledError], raw: true).} =
  forkchoiceUpdated(
    m, headBlockHash, safeBlockHash, finalizedBlockHash,
    payloadAttributes, DeadlineObject.init(FORKCHOICEUPDATED_TIMEOUT),
    high(int))

# TODO can't be defined within exchangeConfigWithSingleEL
func `==`(x, y: Quantity): bool {.borrow.}

proc exchangeConfigWithSingleEL(
    m: ELManager,
    connection: ELConnection
) {.async: (raises: [CancelledError]).} =
  let rpcClient = await connection.connectedRpcClient()

  if m.eth1Network.isSome and
     connection.etcStatus == EtcStatus.notExchangedYet:
    try:
      let
        providerChain = await connection.engineApiRequest(
          rpcClient.eth_chainId(), "chainId", Moment.now(),
          web3RequestsTimeout)

        # https://chainid.network/
        expectedChain = case m.eth1Network.get
          of mainnet: 1.Quantity
          of sepolia: 11155111.Quantity
          of holesky: 17000.Quantity
      if expectedChain != providerChain:
        warn "The specified EL client is connected to a different chain",
              url = connection.engineUrl,
              expectedChain = distinctBase(expectedChain),
              actualChain = distinctBase(providerChain)
        connection.etcStatus = EtcStatus.mismatch
        return
    except CancelledError as exc:
      debug "Configuration exchange was interrupted"
      raise exc
    except CatchableError as exc:
      # Typically because it's not synced through EIP-155, assuming this Web3
      # endpoint has been otherwise working.
      debug "Failed to obtain eth_chainId", reason = exc.msg

  connection.etcStatus = EtcStatus.match

proc exchangeTransitionConfiguration*(
    m: ELManager
) {.async: (raises: [CancelledError]).} =
  if m.elConnections.len == 0:
    return

  let requests = m.elConnections.mapIt(m.exchangeConfigWithSingleEL(it))
  try:
    await allFutures(requests).wait(3.seconds)
  except AsyncTimeoutError:
    discard
  except CancelledError as exc:
    let pending = requests.filterIt(not(it.finished())).
                    mapIt(it.cancelAndWait())
    await noCancel allFutures(pending)
    raise exc

  let (pending, failed, finished) =
    block:
      var
        failed = 0
        done = 0
        pending: seq[Future[void]]
      for req in requests:
        if not req.finished():
          pending.add(req.cancelAndWait())
        else:
          if req.completed():
            inc(done)
          else:
            inc(failed)
      (pending, failed, done)

  await noCancel allFutures(pending)

  if (len(pending) > 0) or (failed != 0):
    warn "Failed to exchange configuration with the configured EL end-points",
         completed = finished, failed = failed, timed_out = len(pending)

template readJsonField(logEvent, field: untyped, ValueType: type): untyped =
  if logEvent.field.isNone:
    raise newException(CatchableError,
      "Web3 provider didn't return needed logEvent field " & astToStr(field))
  logEvent.field.get

template init[N: static int](T: type DynamicBytes[N, N]): T =
  T newSeq[byte](N)

proc fetchTimestamp(
    connection: ELConnection,
    rpcClient: RpcClient,
    blk: Eth1Block
) {.async: (raises: [CatchableError]).} =
  debug "Fetching block timestamp", blockNum = blk.number

  let web3block = raiseIfNil await connection.engineApiRequest(
    rpcClient.getBlockByHash(blk.hash.asBlockHash),
    "getBlockByHash", Moment.now(), web3RequestsTimeout)

  blk.timestamp = Eth1BlockTimestamp(web3block.timestamp)

func depositEventsToBlocks(
    depositsList: openArray[JsonString]
): seq[Eth1Block] {.raises: [CatchableError].} =
  var lastEth1Block: Eth1Block

  for logEventData in depositsList:
    let
      logEvent = JrpcConv.decode(logEventData.string, LogObject)
      blockNumber = Eth1BlockNumber readJsonField(logEvent, blockNumber, Quantity)
      blockHash = readJsonField(logEvent, blockHash, Hash32)

    if lastEth1Block == nil or lastEth1Block.number != blockNumber:
      lastEth1Block = Eth1Block(
        hash: blockHash.asEth2Digest,
        number: blockNumber
        # The `timestamp` is set in `syncBlockRange` immediately
        # after calling this function, because we don't want to
        # make this function `async`
      )

      result.add lastEth1Block

    var
      pubkey = init PubKeyBytes
      withdrawalCredentials = init WithdrawalCredentialsBytes
      amount = init Int64LeBytes
      signature = init SignatureBytes
      index = init Int64LeBytes

    var offset = 0
    offset += decode(logEvent.data, 0, offset, pubkey)
    offset += decode(logEvent.data, 0, offset, withdrawalCredentials)
    offset += decode(logEvent.data, 0, offset, amount)
    offset += decode(logEvent.data, 0, offset, signature)
    offset += decode(logEvent.data, 0, offset, index)

    if pubkey.len != 48 or
       withdrawalCredentials.len != 32 or
       amount.len != 8 or
       signature.len != 96 or
       index.len != 8:
      raise newException(CorruptDataProvider,
                         "Web3 provider supplied invalid deposit logs")

    lastEth1Block.deposits.add DepositData(
      pubkey: ValidatorPubKey.init(pubkey.toArray),
      withdrawal_credentials: Eth2Digest(data: withdrawalCredentials.toArray),
      amount: bytes_to_uint64(amount.toArray).Gwei,
      signature: ValidatorSig.init(signature.toArray))

type
  DepositContractDataStatus = enum
    Fetched
    VerifiedCorrect
    DepositRootIncorrect
    DepositRootUnavailable
    DepositCountIncorrect
    DepositCountUnavailable

when hasDepositRootChecks:
  const
    contractCallTimeout = 60.seconds

  proc fetchDepositContractData(
      connection: ELConnection,
      rpcClient: RpcClient,
      depositContract: Sender[DepositContract],
      blk: Eth1Block
  ): Future[DepositContractDataStatus] {.async: (raises: [CancelledError]).} =
    let
      startTime = Moment.now()
      deadline = sleepAsync(contractCallTimeout)
      depositRootFut =
        depositContract.get_deposit_root.call(blockNumber = blk.number)
      rawCountFut =
        depositContract.get_deposit_count.call(blockNumber = blk.number)
      engineFut1 = connection.engineApiRequest(
        depositRootFut, "get_deposit_root", startTime, deadline,
        failureAllowed = true)
      engineFut2 = connection.engineApiRequest(
        rawCountFut, "get_deposit_count", startTime, deadline,
        failureAllowed = true)

    try:
      await allFutures(engineFut1, engineFut2)
    except CancelledError as exc:
      var pending: seq[Future[void]]
      if not(engineFut1.finished()):
        pending.add(engineFut1.cancelAndWait())
      if not(engineFut2.finished()):
        pending.add(engineFut2.cancelAndWait())
      await noCancel allFutures(pending)
      raise exc

    var res: DepositContractDataStatus

    try:
      # `engineFut1` could hold timeout exception `DataProviderTimeout`.
      discard engineFut1.read()
      let fetchedRoot = asEth2Digest(depositRootFut.read())
      if blk.depositRoot.isZero:
        blk.depositRoot = fetchedRoot
        res = Fetched
      elif blk.depositRoot == fetchedRoot:
        res = VerifiedCorrect
      else:
        res = DepositRootIncorrect
    except CatchableError as exc:
      debug "Failed to fetch deposits root", block_number = blk.number,
            reason = exc.msg
      res = DepositRootUnavailable

    try:
      # `engineFut2` could hold timeout exception `DataProviderTimeout`.
      discard engineFut2.read()
      let fetchedCount = bytes_to_uint64(rawCountFut.read().toArray)
      if blk.depositCount == 0:
        blk.depositCount = fetchedCount
      elif blk.depositCount != fetchedCount:
        res = DepositCountIncorrect
    except CatchableError as exc:
      debug "Failed to fetch deposits count", block_number = blk.number,
            reason = exc.msg
      res = DepositCountUnavailable
    res

template trackFinalizedState*(m: ELManager,
                              finalizedEth1Data: Eth1Data,
                              finalizedStateDepositIndex: uint64): bool =
  trackFinalizedState(m.eth1Chain, finalizedEth1Data, finalizedStateDepositIndex)

template getBlockProposalData*(m: ELManager,
                               state: ForkedHashedBeaconState,
                               finalizedEth1Data: Eth1Data,
                               finalizedStateDepositIndex: uint64):
                               BlockProposalEth1Data =
  getBlockProposalData(
    m.eth1Chain, state, finalizedEth1Data, finalizedStateDepositIndex)

func new*(T: type ELConnection, engineUrl: EngineApiUrl): T =
  ELConnection(
    engineUrl: engineUrl,
    depositContractSyncStatus: DepositContractSyncStatus.unknown)

proc new*(T: type ELManager,
          cfg: RuntimeConfig,
          depositContractBlockNumber: uint64,
          depositContractBlockHash: Eth2Digest,
          db: BeaconChainDB,
          engineApiUrls: seq[EngineApiUrl],
          eth1Network: Opt[Eth1Network]): T =
  let
    eth1Chain = Eth1Chain.init(
      cfg, db, depositContractBlockNumber, depositContractBlockHash)

  debug "Initializing ELManager",
         depositContractBlockNumber,
         depositContractBlockHash

  T(eth1Chain: eth1Chain,
    depositContractAddress: cfg.DEPOSIT_CONTRACT_ADDRESS,
    depositContractBlockNumber: depositContractBlockNumber,
    depositContractBlockHash: depositContractBlockHash.asBlockHash,
    elConnections: mapIt(engineApiUrls, ELConnection.new(it)),
    eth1Network: eth1Network,
    blocksPerLogsRequest: targetBlocksPerLogsRequest,
    managerState: ELManagerState.Running)

proc stop(m: ELManager) {.async: (raises: []).} =
  if m.managerState notin {ELManagerState.Closing, ELManagerState.Closed}:
    m.managerState = ELManagerState.Closing
    var pending: seq[Future[void].Raising([])]
    if not(m.chainSyncingLoopFut.isNil()) and
       not(m.chainSyncingLoopFut.finished()):
      pending.add(m.chainSyncingLoopFut.cancelAndWait())
    if not(m.exchangeTransitionConfigurationLoopFut.isNil()) and
       not(m.exchangeTransitionConfigurationLoopFut.finished()):
      pending.add(m.exchangeTransitionConfigurationLoopFut.cancelAndWait())
    for connection in m.elConnections:
      pending.add(connection.close())
    await noCancel allFutures(pending)
    m.managerState = ELManagerState.Closed

const
  votedBlocksSafetyMargin = 50

func earliestBlockOfInterest(
    m: ELManager,
    latestEth1BlockNumber: Eth1BlockNumber): Eth1BlockNumber =
  let blocksOfInterestRange =
    SLOTS_PER_ETH1_VOTING_PERIOD +
    (2 * m.cfg.ETH1_FOLLOW_DISTANCE) +
    votedBlocksSafetyMargin

  if latestEth1BlockNumber > blocksOfInterestRange.Eth1BlockNumber:
    latestEth1BlockNumber - blocksOfInterestRange
  else:
    0.Eth1BlockNumber

proc syncBlockRange(
    m: ELManager,
    connection: ELConnection,
    rpcClient: RpcClient,
    depositContract: Sender[DepositContract],
    fromBlock, toBlock,
    fullSyncFromBlock: Eth1BlockNumber
) {.async: (raises: [CatchableError]).} =
  doAssert m.eth1Chain.blocks.len > 0

  var currentBlock = fromBlock
  while currentBlock <= toBlock:
    var
      depositLogs: seq[JsonString]
      maxBlockNumberRequested: Eth1BlockNumber
      backoff = 100

    while true:
      maxBlockNumberRequested =
        min(toBlock, currentBlock + m.blocksPerLogsRequest - 1)

      debug "Obtaining deposit log events",
            fromBlock = currentBlock,
            toBlock = maxBlockNumberRequested,
            backoff

      debug.logTime "Deposit logs obtained":
        # Reduce all request rate until we have a more general solution
        # for dealing with Infura's rate limits
        await sleepAsync(milliseconds(backoff))

        depositLogs =
          try:
            await connection.engineApiRequest(
              depositContract.getJsonLogs(
                DepositEvent,
                fromBlock = Opt.some blockId(currentBlock),
                toBlock = Opt.some blockId(maxBlockNumberRequested)),
              "getLogs", Moment.now(), 30.seconds)
          except CancelledError as exc:
            debug "Request for deposit logs was interrupted"
            raise exc
          except CatchableError as exc:
            debug "Request for deposit logs failed", reason = exc.msg
            inc failed_web3_requests
            backoff = (backoff * 3) div 2
            m.blocksPerLogsRequest = m.blocksPerLogsRequest div 2
            if m.blocksPerLogsRequest == 0:
              m.blocksPerLogsRequest = 1
              raise exc
            continue
        m.blocksPerLogsRequest = min(
          (m.blocksPerLogsRequest * 3 + 1) div 2,
          targetBlocksPerLogsRequest)

      currentBlock = maxBlockNumberRequested + 1
      break

    let blocksWithDeposits = depositEventsToBlocks(depositLogs)

    for i in 0 ..< blocksWithDeposits.len:
      let blk = blocksWithDeposits[i]
      if blk.number > fullSyncFromBlock:
        try:
          await fetchTimestamp(connection, rpcClient, blk)
        except CancelledError as exc:
          debug "Request for block timestamp was interrupted",
                block_number = blk.number
          raise exc
        except CatchableError as exc:
          debug "Request for block timestamp failed",
                block_number = blk.number, reason = exc.msg

        let lastBlock = m.eth1Chain.blocks.peekLast
        for n in max(lastBlock.number + 1, fullSyncFromBlock) ..< blk.number:
          debug "Obtaining block without deposits", blockNum = n
          let noDepositsBlock =
            try:
              raiseIfNil await connection.engineApiRequest(
                rpcClient.getBlockByNumber(n),
                "getBlockByNumber", Moment.now(), web3RequestsTimeout)
            except CancelledError as exc:
              debug "The process of obtaining the block was interrupted",
                    block_number = n
              raise exc
            except CatchableError as exc:
              debug "Request for block failed", block_number = n,
                    reason = exc.msg
              raise exc

          m.eth1Chain.addBlock(
            lastBlock.makeSuccessorWithoutDeposits(noDepositsBlock))
          eth1_synced_head.set noDepositsBlock.number.toGaugeValue

      m.eth1Chain.addBlock blk
      eth1_synced_head.set blk.number.toGaugeValue

    if blocksWithDeposits.len > 0:
      let lastIdx = blocksWithDeposits.len - 1
      template lastBlock: auto = blocksWithDeposits[lastIdx]

      let status =
        when hasDepositRootChecks:
          await fetchDepositContractData(
            connection, rpcClient, depositContract, lastBlock)
        else:
          DepositRootUnavailable

      when hasDepositRootChecks:
        debug "Deposit contract state verified",
              status = $status,
              ourCount = lastBlock.depositCount,
              ourRoot = lastBlock.depositRoot

      case status
      of DepositRootIncorrect, DepositCountIncorrect:
        raise newException(CorruptDataProvider,
          "The deposit log events disagree with the deposit contract state")
      else:
        discard

      info "Eth1 sync progress",
        blockNumber = lastBlock.number,
        depositsProcessed = lastBlock.depositCount

func hasConnection*(m: ELManager): bool =
  m.elConnections.len > 0

func hasAnyWorkingConnection*(m: ELManager): bool =
  m.elConnections.anyIt(it.state == Working or it.state == NeverTested)

func hasProperlyConfiguredConnection*(m: ELManager): bool =
  for connection in m.elConnections:
    if connection.etcStatus == EtcStatus.match:
      return true

  false

proc startExchangeTransitionConfigurationLoop(
    m: ELManager
) {.async: (raises: [CancelledError]).} =
  debug "Starting exchange transition configuration loop"

  while true:
    # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.3/src/engine/paris.md#specification-3
    await m.exchangeTransitionConfiguration()
    await sleepAsync(60.seconds)

proc syncEth1Chain(
    m: ELManager,
    connection: ELConnection
) {.async: (raises: [CatchableError]).} =
  let rpcClient =
    try:
      await connection.connectedRpcClient().wait(1.seconds)
    except AsyncTimeoutError:
      raise newException(DataProviderTimeout, "Connection timed out")

  let
    # BEWARE
    # `connectedRpcClient` guarantees that connection.web3 will not be
    # `none` here, but it's not safe to initialize this later (e.g closer
    # to where it's used) because `connection.web3` may be set to `none`
    # at any time after a failed request. Luckily, the `contractSender`
    # object is very cheap to create.
    depositContract = connection.web3.get.contractSender(
      DepositContract, m.depositContractAddress)

    shouldProcessDeposits = not (
      m.depositContractAddress.isZeroMemory or
      m.eth1Chain.finalizedBlockHash.data.isZeroMemory)

  trace "Starting syncEth1Chain", shouldProcessDeposits

  logScope:
    url = connection.engineUrl.url

  # We might need to reset the chain if the new provider disagrees
  # with the previous one regarding the history of the chain or if
  # we have detected a conensus violation - our view disagreeing with
  # the majority of the validators in the network.
  #
  # Consensus violations happen in practice because the web3 providers
  # sometimes return incomplete or incorrect deposit log events even
  # when they don't indicate any errors in the response. When this
  # happens, we are usually able to download the data successfully
  # on the second attempt.
  #
  # TODO
  # Perhaps the above problem was manifesting only with the obsolete
  # JSON-RPC data providers, which can no longer be used with Nimbus.
  if m.eth1Chain.blocks.len > 0:
    let needsReset = m.eth1Chain.hasConsensusViolation or (block:
      let
        lastKnownBlock = m.eth1Chain.blocks.peekLast
        matchingBlockAtNewEl =
          try:
            raiseIfNil await connection.engineApiRequest(
              rpcClient.getBlockByNumber(lastKnownBlock.number),
              "getBlockByNumber", Moment.now(), web3RequestsTimeout)
          except CancelledError as exc:
            debug "getBlockByNumber request has been interrupted",
                  last_known_block_number = lastKnownBlock.number
            raise exc
          except CatchableError as exc:
            debug "getBlockByNumber request failed",
                  last_known_block_number = lastKnownBlock.number,
                  reason = exc.msg
            raise exc

      lastKnownBlock.hash.asBlockHash != matchingBlockAtNewEl.hash)

    if needsReset:
      trace "Resetting the Eth1 chain",
            hasConsensusViolation = m.eth1Chain.hasConsensusViolation
      m.eth1Chain.clear()

  var eth1SyncedTo: Eth1BlockNumber
  if shouldProcessDeposits:
    if m.eth1Chain.blocks.len == 0:
      let finalizedBlockHash = m.eth1Chain.finalizedBlockHash.asBlockHash
      let startBlock =
        try:
          raiseIfNil await connection.engineApiRequest(
            rpcClient.getBlockByHash(finalizedBlockHash),
            "getBlockByHash", Moment.now(), web3RequestsTimeout)
        except CancelledError as exc:
          debug "getBlockByHash() request has been interrupted",
                finalized_block_hash = finalizedBlockHash
          raise exc
        except CatchableError as exc:
          debug "getBlockByHash() request has failed",
                finalized_block_hash = finalizedBlockHash,
                reason = exc.msg
          raise exc

      m.eth1Chain.addBlock Eth1Block(
        hash: m.eth1Chain.finalizedBlockHash,
        number: Eth1BlockNumber startBlock.number,
        timestamp: Eth1BlockTimestamp startBlock.timestamp)

    eth1SyncedTo = m.eth1Chain.blocks[^1].number

    eth1_synced_head.set eth1SyncedTo.toGaugeValue
    eth1_finalized_head.set eth1SyncedTo.toGaugeValue
    eth1_finalized_deposits.set(
      m.eth1Chain.finalizedDepositsMerkleizer.getChunkCount.toGaugeValue)

    debug "Starting Eth1 syncing", `from` = shortLog(m.eth1Chain.blocks[^1])

  var latestBlockNumber: Eth1BlockNumber
  while true:
    debug "syncEth1Chain tick",
      shouldProcessDeposits, latestBlockNumber, eth1SyncedTo

    # TODO (cheatfate): This should be removed
    if bnStatus == BeaconNodeStatus.Stopping:
      await noCancel m.stop()
      return

    if m.eth1Chain.hasConsensusViolation:
      raise newException(CorruptDataProvider,
                         "Eth1 chain contradicts Eth2 consensus")

    let latestBlock =
      try:
        raiseIfNil await connection.engineApiRequest(
          rpcClient.eth_getBlockByNumber(blockId("latest"), false),
          "getBlockByNumber", Moment.now(), web3RequestsTimeout)
      except CancelledError as exc:
        debug "Latest block request has been interrupted"
        raise exc
      except CatchableError as exc:
        warn "Failed to obtain the latest block from the EL", reason = exc.msg
        raise exc

    latestBlockNumber = latestBlock.number

    m.syncTargetBlock = Opt.some(
      if latestBlock.number > m.cfg.ETH1_FOLLOW_DISTANCE.Eth1BlockNumber:
        latestBlock.number - m.cfg.ETH1_FOLLOW_DISTANCE
      else:
        0.Eth1BlockNumber)
    if m.syncTargetBlock.get <= eth1SyncedTo:
      # The chain reorged to a lower height.
      # It's relatively safe to ignore that.
      await sleepAsync(m.cfg.SECONDS_PER_ETH1_BLOCK.int.seconds)
      continue

    eth1_latest_head.set latestBlock.number.toGaugeValue

    if shouldProcessDeposits and
       latestBlock.number.uint64 > m.cfg.ETH1_FOLLOW_DISTANCE:
      try:
        await m.syncBlockRange(connection,
                               rpcClient,
                               depositContract,
                               eth1SyncedTo + 1,
                               m.syncTargetBlock.get,
                               m.earliestBlockOfInterest(latestBlock.number))
      except CancelledError as exc:
        debug "Syncing block range process has been interrupted"
        raise exc
      except CatchableError as exc:
        debug "Syncing block range process has been failed", reason = exc.msg
        raise exc

    eth1SyncedTo = m.syncTargetBlock.get
    eth1_synced_head.set eth1SyncedTo.toGaugeValue

proc startChainSyncingLoop(
    m: ELManager
) {.async: (raises: []).} =
  info "Starting execution layer deposit syncing",
        contract = $m.depositContractAddress

  var syncedConnectionFut = m.selectConnectionForChainSyncing()
  info "Connection attempt started"

  var runLoop = true
  while runLoop:
    try:
      let connection = await syncedConnectionFut.wait(60.seconds)
      await syncEth1Chain(m, connection)
    except AsyncTimeoutError:
      notice "No synced EL nodes available for deposit syncing"
      try:
        await sleepAsync(chronos.seconds(30))
      except CancelledError:
        runLoop = false
    except CancelledError:
      runLoop = false
    except CatchableError:
      try:
        await sleepAsync(10.seconds)
      except CancelledError:
        runLoop = false
        break
      debug "Restarting the deposit syncing loop"
      # A more detailed error is already logged by trackEngineApiRequest
      # To be extra safe, we will make a fresh connection attempt
      await syncedConnectionFut.cancelAndWait()
      syncedConnectionFut = m.selectConnectionForChainSyncing()

  debug "EL chain syncing process has been stopped"

proc start*(m: ELManager, syncChain = true) {.gcsafe.} =
  if m.elConnections.len == 0:
    return

  ## Calling `ELManager.start()` on an already started ELManager is a noop
  if syncChain and m.chainSyncingLoopFut.isNil:
    m.chainSyncingLoopFut =
      m.startChainSyncingLoop()

  if m.hasJwtSecret and m.exchangeTransitionConfigurationLoopFut.isNil:
    m.exchangeTransitionConfigurationLoopFut =
      m.startExchangeTransitionConfigurationLoop()

func `$`(x: Quantity): string =
  $(x.uint64)

func `$`(x: BlockObject): string =
  $(x.number) & " [" & $(x.hash) & "]"

proc testWeb3Provider*(
    web3Url: Uri,
    depositContractAddress: Eth1Address,
    jwtSecret: Opt[seq[byte]]
) {.async: (raises: [CatchableError]).} =

  stdout.write "Establishing web3 connection..."
  let web3 =
    try:
      await newWeb3($web3Url,
                    getJsonRpcRequestHeaders(jwtSecret)).wait(5.seconds)
    except CatchableError as exc:
      stdout.write "\rEstablishing web3 connection: Failure(" & exc.msg & ")\n"
      quit 1

  stdout.write "\rEstablishing web3 connection: Connected\n"

  template request(actionDesc: static string,
                   action: untyped): untyped =
    stdout.write actionDesc & "..."
    stdout.flushFile()
    var res: typeof(read action)
    try:
      let fut = action
      res = await fut.wait(web3RequestsTimeout)
      when res is BlockObject:
        res = raiseIfNil res
      stdout.write "\r" & actionDesc & ": " & $res
    except CatchableError as err:
      stdout.write "\r" & actionDesc & ": Error(" & err.msg & ")"
    stdout.write "\n"
    res

  discard request "Chain ID":
    web3.provider.eth_chainId()

  discard request "Sync status":
    web3.provider.eth_syncing()

  let
    latestBlock = request "Latest block":
      web3.provider.eth_getBlockByNumber(blockId("latest"), false)

    ns = web3.contractSender(DepositContract, depositContractAddress)

  discard request "Deposit root":
    ns.get_deposit_root.call(blockNumber = latestBlock.number)
