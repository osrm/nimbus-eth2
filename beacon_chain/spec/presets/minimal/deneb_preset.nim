# beacon_chain
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

# Minimal preset - Deneb
# https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.3/presets/minimal/deneb.yaml
const
  # `uint64(4096)`
  FIELD_ELEMENTS_PER_BLOB*: uint64 = 4096
  # [customized]
  MAX_BLOB_COMMITMENTS_PER_BLOCK*: uint64 = 32
  # `uint64(6)`
  MAX_BLOBS_PER_BLOCK*: uint64 = 6
  # [customized] `floorlog2(get_generalized_index(BeaconBlockBody, 'blob_kzg_commitments')) + 1 + ceillog2(MAX_BLOB_COMMITMENTS_PER_BLOCK)` = 4 + 1 + 5 = 10
  KZG_COMMITMENT_INCLUSION_PROOF_DEPTH* = 10
