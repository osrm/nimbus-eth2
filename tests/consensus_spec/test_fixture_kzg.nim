# beacon_chain
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}
{.used.}

import
  std/json,
  yaml/tojson,
  kzg4844/[kzg, kzg_abi],
  stew/byteutils,
  ../testutil,
  ./fixtures_utils, ./os_ops

from std/sequtils import anyIt, mapIt, toSeq
from std/strutils import rsplit

func toUInt64(s: int): Opt[uint64] =
  if s < 0:
    return Opt.none uint64
  try:
    Opt.some uint64(s)
  except ValueError:
    Opt.none uint64

func fromHex[N: static int](s: string): Opt[array[N, byte]] =
  if s.len != 2*(N+1):
    # 0x prefix
    return Opt.none array[N, byte]

  try:
    Opt.some fromHex(array[N, byte], s)
  except ValueError:
    Opt.none array[N, byte]

block:
  template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
  doAssert loadTrustedSetup(
    sourceDir &
      "/../../vendor/nim-kzg4844/kzg4844/csources/src/trusted_setup.txt", 0).isOk

proc runBlobToKzgCommitmentTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Blob to KZG commitment - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      blob = fromHex[131072](data["input"]["blob"].getStr)

    # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.0/tests/formats/kzg/blob_to_kzg_commitment.md#condition
    # If the blob is invalid (e.g. incorrect length or one of the 32-byte
    # blocks does not represent a BLS field element) it should error, i.e. the
    # output should be `null`.
    if blob.isNone:
      check output.kind == JNull
    else:
      let commitment = blobToKzgCommitment(KzgBlob(bytes: blob.get))
      check:
        if commitment.isErr:
          output.kind == JNull
        else:
          commitment.get().bytes == fromHex[48](output.getStr).get

proc runVerifyKzgProofTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Verify KZG proof - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      commitment = fromHex[48](data["input"]["commitment"].getStr)
      z = fromHex[32](data["input"]["z"].getStr)
      y = fromHex[32](data["input"]["y"].getStr)
      proof = fromHex[48](data["input"]["proof"].getStr)

    # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/tests/formats/kzg/verify_kzg_proof.md#condition
    # "If the commitment or proof is invalid (e.g. not on the curve or not in
    # the G1 subgroup of the BLS curve) or `z` or `y` are not a valid BLS
    # field element, it should error, i.e. the output should be `null`."
    if commitment.isNone or z.isNone or y.isNone or proof.isNone:
      check output.kind == JNull
    else:
      let v = verifyKzgProof(
        KzgCommitment(bytes: commitment.get),
        KzgBytes32(bytes: z.get), KzgBytes32(bytes: y.get),
        KzgBytes48(bytes: proof.get))
      check:
        if v.isErr:
          output.kind == JNull
        else:
          v.get == output.getBool

proc runVerifyBlobKzgProofTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Verify blob KZG proof - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      blob = fromHex[131072](data["input"]["blob"].getStr)
      commitment = fromHex[48](data["input"]["commitment"].getStr)
      proof = fromHex[48](data["input"]["proof"].getStr)

    # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/tests/formats/kzg/verify_blob_kzg_proof.md#condition
    # "If the commitment or proof is invalid (e.g. not on the curve or not in
    # the G1 subgroup of the BLS curve) or `blob` is invalid (e.g. incorrect
    # length or one of the 32-byte blocks does not represent a BLS field
    # element), it should error, i.e. the output should be `null`."
    if blob.isNone or commitment.isNone or proof.isNone:
      check output.kind == JNull
    else:
      let v = verifyBlobKzgProof(
        KzgBlob(bytes: blob.get),
        KzgBytes48(bytes: commitment.get),
        KzgBytes48(bytes: proof.get))
      check:
        if v.isErr:
          output.kind == JNull
        else:
          v.get == output.getBool

proc runVerifyBlobKzgProofBatchTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Verify blob KZG proof batch - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      blobs = data["input"]["blobs"].mapIt(fromHex[131072](it.getStr))
      commitments = data["input"]["commitments"].mapIt(fromHex[48](it.getStr))
      proofs = data["input"]["proofs"].mapIt(fromHex[48](it.getStr))

    # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.0/tests/formats/kzg/verify_blob_kzg_proof_batch.md#condition
    # "If any of the commitments or proofs are invalid (e.g. not on the curve or
    # not in the G1 subgroup of the BLS curve) or any blob is invalid (e.g.
    # incorrect length or one of the 32-byte blocks does not represent a BLS
    # field element), it should error, i.e. the output should be null."
    if  blobs.anyIt(it.isNone) or commitments.anyIt(it.isNone) or
        proofs.anyIt(it.isNone):
      check output.kind == JNull
    else:
      let v = verifyBlobKzgProofBatch(
        blobs.mapIt(KzgBlob(bytes: it.get)),
        commitments.mapIt(KzgCommitment(bytes: it.get)),
        proofs.mapIt(KzgProof(bytes: it.get)))
      check:
        if v.isErr:
          output.kind == JNull
        else:
          v.get == output.getBool

proc runComputeKzgProofTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Compute KZG proof - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      blob = fromHex[131072](data["input"]["blob"].getStr)
      z = fromHex[32](data["input"]["z"].getStr)

    # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.0/tests/formats/kzg/compute_kzg_proof.md#condition
    # "If the blob is invalid (e.g. incorrect length or one of the 32-byte
    # blocks does not represent a BLS field element) or z is not a valid BLS
    # field element, it should error, i.e. the output should be null."
    if blob.isNone or z.isNone:
      check output.kind == JNull
    else:
      let p = computeKzgProof(
        KzgBlob(bytes: blob.get), KzgBytes32(bytes: z.get))
      if p.isErr:
        check output.kind == JNull
      else:
        let
          proof = fromHex[48](output[0].getStr)
          y = fromHex[32](output[1].getStr)
        check:
          p.get.proof.bytes == proof.get
          p.get.y.bytes == y.get

proc runComputeBlobKzgProofTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Compute blob KZG proof - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      blob = fromHex[131072](data["input"]["blob"].getStr)
      commitment = fromHex[48](data["input"]["commitment"].getStr)

    # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/tests/formats/kzg/compute_blob_kzg_proof.md#condition
    # If the blob is invalid (e.g. incorrect length or one of the 32-byte
    # blocks does not represent a BLS field element) it should error, i.e. the
    # output should be `null`.
    if blob.isNone or commitment.isNone:
      check output.kind == JNull
    else:
      let p = computeBlobKzgProof(
        KzgBlob(bytes: blob.get), KzgBytes48(bytes: commitment.get))
      if p.isErr:
        check output.kind == JNull
      else:
        check p.get.bytes == fromHex[48](output.getStr).get

proc runComputeCellsAndKzgProofsTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Compute Cells And Proofs - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      blob = fromHex[131072](data["input"]["blob"].getStr)

    # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5/tests/formats/kzg_7594/verify_cell_kzg_proof.md#condition
    # If the blob is invalid (e.g. incorrect length or one of the 32-byte
    # blocks does not represent a BLS field element) it should error, i.e. the
    # the output should be `null`.
    if blob.isNone:
      check output.kind == JNull
    else:
      let p = newClone computeCellsAndKzgProofs(KzgBlob(bytes: blob.get))
      if p[].isErr:
        check output.kind == JNull
      else:
        let p_val = p[].get
        for i in 0..<CELLS_PER_EXT_BLOB:
          check p_val.cells[i].bytes == fromHex[2048](output[0][i].getStr).get
          check p_val.proofs[i].bytes == fromHex[48](output[1][i].getStr).get

proc runVerifyCellKzgProofBatchTest(suiteName, suitePath, path: string) =
  let relativePathCompnent = path.relativeTestPathComponent(suitePath)
  test "KZG - Verify Cell Kzg Proof Batch - " & relativePathCompnent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      commitments = data["input"]["commitments"].mapIt(fromHex[48](it.getStr))
      cell_indices = data["input"]["cell_indices"].mapIt(toUInt64(it.getInt))
      cells = data["input"]["cells"].mapIt(fromHex[2048](it.getStr))
      proofs = data["input"]["proofs"].mapIt(fromHex[48](it.getStr))

    # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.10/tests/formats/kzg_7594/verify_cell_kzg_proof_batch.md#condition
    # If the blob is invalid (e.g. incorrect length or one of the 32-byte
    # blocks does not represent a BLS field element) it should error, i.e. the
    # the output should be `null`.
    if commitments.anyIt(it.isNone) or
        cell_indices.anyIt(it.isNone) or
        proofs.anyIt(it.isNone) or
        cells.anyIt(it.isNone):
      check output.kind == JNull
    else:
      let v = newClone verifyCellKzgProofBatch(
            commitments.mapIt(KzgCommitment(bytes: it.get)),
            cell_indices.mapIt(it.get),
            cells.mapIt(KzgCell(bytes: it.get)),
            proofs.mapIt(KzgBytes48(bytes: it.get))
          )
      check:
        if v[].isErr:
          output.kind == JNull
        else:
          v[].get == output.getBool

proc runRecoverCellsAndKzgProofsTest(suiteName, suitePath, path: string) =
  let relativePathComponent = path.relativeTestPathComponent(suitePath)
  test "KZG - Recover Cells And Kzg Proofs - " & relativePathComponent:
    let
      data = loadToJson(os_ops.readFile(path/"data.yaml"))[0]
      output = data["output"]
      cell_ids = data["input"]["cell_indices"].mapIt(toUInt64(it.getInt))
      cells = data["input"]["cells"].mapIt(fromHex[2048](it.getStr))
    # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.5 /tests/formats/kzg_7594/recover_all_cells.md#condition
    # If the blob is invalid (e.g. incorrect length or one of the 32-byte
    # blocks does not represent a BLS field element) it should error, i.e. the
    # the output should be `null`.
    if cell_ids.anyIt(it.isNone) or
        cells.anyIt(it.isNone):
      check output.kind == JNull
    else:
      let v = newClone recoverCellsAndKzgProofs(
            cell_ids.mapIt(it.get),
            cells.mapIt(KzgCell(bytes: it.get)))
      if v[].isErr:
        check output.kind == JNull
      else:
        let val = v[].get
        for i in 0..<CELLS_PER_EXT_BLOB:
          check val.cells[i].bytes == fromHex[2048](output[0][i].getStr).get
          check val.proofs[i].bytes == fromHex[48](output[1][i].getStr).get

from std/algorithm import sorted

var suiteName = "EF - KZG"

suite suiteName:
  const suitePath = SszTestsDir/"general"/"deneb"/"kzg"

  # TODO also check that the only direct subdirectory of each is kzg-mainnet
  doAssert sorted(mapIt(
      toSeq(walkDir(suitePath, relative = true, checkDir = true)), it.path)) ==
    ["blob_to_kzg_commitment", "compute_blob_kzg_proof", "compute_kzg_proof",
     "verify_blob_kzg_proof", "verify_blob_kzg_proof_batch",
     "verify_kzg_proof"]

  block:
    let testsDir = suitePath/"blob_to_kzg_commitment"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runBlobToKzgCommitmentTest(suiteName, testsDir, testsDir/path)

  block:
    let testsDir = suitePath/"verify_kzg_proof"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runVerifyKzgProofTest(suiteName, testsDir, testsDir/path)

  block:
    let testsDir = suitePath/"verify_blob_kzg_proof"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runVerifyBlobKzgProofTest(suiteName, testsDir, testsDir/path)

  block:
    let testsDir = suitePath/"verify_blob_kzg_proof_batch"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runVerifyBlobKzgProofBatchTest(suiteName, testsDir, testsDir/path)

  block:
    let testsDir = suitePath/"compute_kzg_proof"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runComputeKzgProofTest(suiteName, testsDir, testsDir / path)

  block:
    let testsDir = suitePath/"compute_blob_kzg_proof"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runComputeBlobKzgProofTest(suiteName, testsDir, testsDir / path)

suiteName = "EF - KZG - EIP7594"

suite suiteName:
  const suitePath = SszTestsDir/"general"/"fulu"/"kzg"

  # TODO also check that the only direct subdirectory of each is kzg-mainnet
  doAssert sorted(mapIt(
      toSeq(walkDir(suitePath, relative = true, checkDir = true)), it.path)) ==
    ["compute_cells_and_kzg_proofs", "recover_cells_and_kzg_proofs",
     "verify_cell_kzg_proof_batch"]

  block:
    let testsDir = suitePath/"compute_cells_and_kzg_proofs"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runComputeCellsAndKzgProofsTest(suiteName, testsDir, testsDir/path)

  block:
    let testsDir = suitePath/"recover_cells_and_kzg_proofs"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runRecoverCellsAndKzgProofsTest(suiteName, testsDir, testsDir/path)

  block:
    let testsDir = suitePath/"verify_cell_kzg_proof_batch"/"kzg-mainnet"
    for kind, path in walkDir(testsDir, relative = true, checkDir = true):
      runVerifyCellKzgProofBatchTest(suiteName, testsDir, testsDir/path)

doAssert freeTrustedSetup().isOk
