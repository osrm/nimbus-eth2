# beacon_chain
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  # Std lib
  std/[typetraits, os, sequtils, strutils, algorithm, math, tables, macrocache],

  # Status libs
  results,
  stew/[leb128, endians2, byteutils, io2, bitops2],
  stew/shims/macros,
  snappy,
  json_serialization, json_serialization/std/[net, sets, options],
  chronos, chronos/ratelimit, chronicles, metrics,
  libp2p/[switch, peerinfo, multiaddress, multicodec, crypto/crypto,
    crypto/secp, builders],
  libp2p/protocols/pubsub/[
      pubsub, gossipsub, rpc/message, rpc/messages, peertable, pubsubpeer],
  libp2p/stream/connection,
  libp2p/services/wildcardresolverservice,
  eth/[common/keys, async_utils],
  eth/net/nat, eth/p2p/discoveryv5/[enr, node, random2],
  ".."/[version, conf, beacon_clock, conf_light_client],
  ../spec/[eth2_ssz_serialization, network, helpers, forks],
  ../validators/keystore_management,
  "."/[eth2_discovery, eth2_protocol_dsl, eth2_agents,
       libp2p_json_serialization, peer_pool, peer_scores]

export
  tables, chronos, ratelimit, version, multiaddress, peerinfo, p2pProtocol,
  connection, libp2p_json_serialization, eth2_ssz_serialization, results,
  eth2_discovery, peer_pool, peer_scores, eth2_agents

logScope:
  topics = "networking"

type
  NetKeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  ErrorMsg = List[byte, 256]
  SendResult* = Result[void, cstring]

  DirectPeers = Table[PeerId, seq[MultiAddress]]

  # TODO: This is here only to eradicate a compiler
  # warning about unused import (rpc/messages).
  GossipMsg = messages.Message

  SeenItem* = object
    peerId*: PeerId
    stamp*: chronos.Moment

  Eth2Node* = ref object of RootObj
    switch*: Switch
    pubsub*: GossipSub
    discovery*: Eth2DiscoveryProtocol
    discoveryEnabled*: bool
    wantedPeers*: int
    hardMaxPeers*: int
    peerPool*: PeerPool[Peer, PeerId]
    protocols: seq[ProtocolInfo]
      ## Protocols managed by the DSL and mounted on the switch
    protocolStates*: seq[RootRef]
    metadata*: fulu.MetaData
    connectTimeout*: chronos.Duration
    seenThreshold*: chronos.Duration
    connQueue: AsyncQueue[PeerAddr]
    seenTable: Table[PeerId, SeenItem]
    connWorkers: seq[Future[void].Raising([CancelledError])]
    connTable: HashSet[PeerId]
    forkId*: ENRForkID
    discoveryForkId*: ENRForkID
    forkDigests*: ref ForkDigests
    rng*: ref HmacDrbgContext
    peers*: Table[PeerId, Peer]
    directPeers*: DirectPeers
    announcedAddresses*: seq[MultiAddress]
    validTopics: HashSet[string]
    peerPingerHeartbeatFut: Future[void].Raising([CancelledError])
    peerTrimmerHeartbeatFut: Future[void].Raising([CancelledError])
    cfg: RuntimeConfig
    getBeaconTime: GetBeaconTimeFn

    quota: TokenBucket ## Global quota mainly for high-bandwidth stuff

  AverageThroughput* = object
    count*: uint64
    average*: float

  Peer* = ref object
    network*: Eth2Node
    peerId*: PeerId
    remoteAgent*: Eth2Agent
    discoveryId*: Eth2DiscoveryId
    connectionState*: ConnectionState
    protocolStates*: seq[RootRef]
    netThroughput: AverageThroughput
    score*: int
    quota*: TokenBucket
    lastReqTime*: Moment
    connections*: int
    enr*: Opt[enr.Record]
    metadata*: Opt[fulu.MetaData]
    failedMetadataRequests: int
    lastMetadataTime*: Moment
    direction*: PeerType
    disconnectedFut: Future[void]
    statistics*: SyncResponseStats

  PeerAddr* = object
    peerId*: PeerId
    addrs*: seq[MultiAddress]

  ConnectionState* = enum
    None,
    Connecting,
    Connected,
    Disconnecting,
    Disconnected

  UntypedResponse* = ref object
    peer*: Peer
    stream*: Connection
    writtenChunks*: int

  SingleChunkResponse*[MsgType] = distinct UntypedResponse
    ## Protocol requests using this type will produce request-making
    ## client-side procs that return `NetRes[MsgType]`

  MultipleChunksResponse*[MsgType; maxLen: static Limit] = distinct UntypedResponse
    ## Protocol requests using this type will produce request-making
    ## client-side procs that return `NetRes[List[MsgType, maxLen]]`.
    ## In the future, such procs will return an `InputStream[NetRes[MsgType]]`.

  MessageInfo* = object
    name*: string

    # Private fields:
    libp2pCodecName: string
    protocolMounter*: MounterProc

  ProtocolInfoObj* = object
    name*: string
    messages*: seq[MessageInfo]
    index*: int # the position of the protocol in the
                # ordered list of supported protocols

    # Private fields:
    peerStateInitializer*: PeerStateInitializer
    networkStateInitializer*: NetworkStateInitializer
    onPeerConnected*: OnPeerConnectedHandler
    onPeerDisconnected*: OnPeerDisconnectedHandler

  ProtocolInfo* = ptr ProtocolInfoObj

  ResponseCode* = enum
    Success
    InvalidRequest
    ServerError
    ResourceUnavailable

  PeerStateInitializer* = proc(peer: Peer): RootRef {.gcsafe, raises: [].}
  NetworkStateInitializer* = proc(network: Eth2Node): RootRef {.gcsafe, raises: [].}
  OnPeerConnectedHandler* = proc(peer: Peer, incoming: bool): Future[void] {.async: (raises: [CancelledError]).}
  OnPeerDisconnectedHandler* = proc(peer: Peer): Future[void] {.async: (raises: [CancelledError]).}
  ThunkProc* = LPProtoHandler
  MounterProc* = proc(network: Eth2Node) {.gcsafe, raises: [].}
  MessageContentPrinter* = proc(msg: pointer): string {.gcsafe, raises: [].}

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/p2p-interface.md#goodbye
  DisconnectionReason* = enum
    # might see other values on the wire!
    ClientShutDown = 1
    IrrelevantNetwork = 2
    FaultOrError = 3
    # Clients MAY use reason codes above 128 to indicate alternative,
    # erroneous request-specific responses.
    PeerScoreLow = 237 # 79 * 3

  TransmissionError* = object of CatchableError

  Eth2NetworkingErrorKind* = enum
    # Potentially benign errors (network conditions)
    BrokenConnection
    ReceivedErrorResponse
    UnexpectedEOF
    PotentiallyExpectedEOF
    StreamOpenTimeout
    ReadResponseTimeout

    # Errors for which we descore heavily (protocol violations)
    InvalidResponseCode
    InvalidSnappyBytes
    InvalidSszBytes
    InvalidSizePrefix
    ZeroSizePrefix
    SizePrefixOverflow
    InvalidContextBytes
    ResponseChunkOverflow

    UnknownError

  Eth2NetworkingError = object
    case kind*: Eth2NetworkingErrorKind
    of ReceivedErrorResponse:
      responseCode*: ResponseCode
      errorMsg*: string
    else:
      discard

  InvalidInputsError* = object of CatchableError

  ResourceUnavailableError* = object of CatchableError

  NetRes*[T] = Result[T, Eth2NetworkingError]
    ## This is type returned from all network requests

const
  clientId* = "Nimbus beacon node " & fullVersionStr

  requestPrefix = "/eth2/beacon_chain/req/"
  requestSuffix = "/ssz_snappy"

  ConcurrentConnections = 20
    ## Maximum number of active concurrent connection requests.

  SeenTableTimeTimeout =
    when not defined(local_testnet): 5.minutes else: 10.seconds

    ## Seen period of time for timeout connections
  SeenTableTimeDeadPeer =
    when not defined(local_testnet): 5.minutes else: 10.seconds

    ## Period of time for dead peers.
  SeenTableTimeIrrelevantNetwork = 24.hours
    ## Period of time for `IrrelevantNetwork` error reason.
  SeenTableTimeClientShutDown = 10.minutes
    ## Period of time for `ClientShutDown` error reason.
  SeenTableTimeFaultOrError = 10.minutes
    ## Period of time for `FaultOnError` error reason.
  SeenTablePenaltyError = 60.minutes
    ## Period of time for peers which score below or equal to zero.
  SeenTableTimeReconnect = 1.minutes
    ## Minimal time between disconnection and reconnection attempt

  ProtocolViolations = {InvalidResponseCode..Eth2NetworkingErrorKind.high()}

template neterr*(kindParam: Eth2NetworkingErrorKind): auto =
  err(type(result), Eth2NetworkingError(kind: kindParam))

# Metrics for tracking attestation and beacon block loss
declareCounter nbc_gossip_messages_sent,
  "Number of gossip messages sent by this peer"

declareCounter nbc_gossip_messages_received,
  "Number of gossip messages received by this peer"

declareCounter nbc_gossip_failed_snappy,
  "Number of gossip messages that failed snappy decompression"

declareCounter nbc_gossip_failed_ssz,
  "Number of gossip messages that failed SSZ parsing"

declareCounter nbc_successful_dials,
  "Number of successfully dialed peers"

declareCounter nbc_failed_dials,
  "Number of dialing attempts that failed"

declareCounter nbc_timeout_dials,
  "Number of dialing attempts that exceeded timeout"

declareGauge nbc_peers,
  "Number of active libp2p peers"

declareCounter nbc_successful_discoveries,
  "Number of successful discoveries"

declareCounter nbc_cycling_kicked_peers,
  "Number of peers kicked for peer cycling"

declareGauge nbc_gossipsub_low_fanout,
  "numbers of topics with low fanout"

declareGauge nbc_gossipsub_good_fanout,
  "numbers of topics with good fanout"

declareGauge nbc_gossipsub_healthy_fanout,
  "numbers of topics with dHigh fanout"

declareHistogram nbc_resolve_time,
  "Time(s) used while resolving peer information",
   buckets = [1.0, 5.0, 10.0, 20.0, 40.0, 60.0]

declareCounter nbc_reqresp_messages_sent,
  "Number of Req/Resp messages sent", labels = ["protocol"]

declareCounter nbc_reqresp_messages_received,
  "Number of Req/Resp messages received", labels = ["protocol"]

declareCounter nbc_reqresp_messages_failed,
  "Number of Req/Resp messages that failed decoding", labels = ["protocol"]

declareCounter nbc_reqresp_messages_throttled,
  "Number of Req/Resp messages that were throttled", labels = ["protocol"]

const
  libp2p_pki_schemes {.strdefine.} = ""

when libp2p_pki_schemes != "secp256k1":
  {.fatal: "Incorrect building process, please use -d:\"libp2p_pki_schemes=secp256k1\"".}

const
  NetworkInsecureKeyPassword = "INSECUREPASSWORD"

template libp2pProtocol*(name: string, version: int) {.pragma.}

func shortLog*(peer: Peer): string = shortLog(peer.peerId)
chronicles.formatIt(Peer): shortLog(it)
chronicles.formatIt(PublicKey): byteutils.toHex(it.getBytes().tryGet())

func shortProtocolId(protocolId: string): string =
  let
    start = if protocolId.startsWith(requestPrefix): requestPrefix.len else: 0
    ends = if protocolId.endsWith(requestSuffix):
      protocolId.high - requestSuffix.len
    else:
      protocolId.high
  protocolId[start..ends]

func updateAgent*(peer: Peer) =
  let
    agent = toLowerAscii(peer.network.switch.peerStore[AgentBook][peer.peerId])
    # proto = peer.network.switch.peerStore[ProtoVersionBook][peer.peerId]

  if "nimbus" in agent:
    peer.remoteAgent = Eth2Agent.Nimbus
  elif "lighthouse" in agent:
    peer.remoteAgent = Eth2Agent.Lighthouse
  elif "teku" in agent:
    peer.remoteAgent = Eth2Agent.Teku
  elif "lodestar" in agent:
    peer.remoteAgent = Eth2Agent.Lodestar
  elif "prysm" in agent:
    peer.remoteAgent = Eth2Agent.Prysm
  elif "grandine" in agent:
    peer.remoteAgent = Eth2Agent.Grandine
  else:
    peer.remoteAgent = Eth2Agent.Unknown

func getRemoteAgent*(peer: Peer): Eth2Agent =
  if peer.remoteAgent == Eth2Agent.Unknown:
    peer.updateAgent()
  peer.remoteAgent

proc openStream(node: Eth2Node,
                peer: Peer,
                protocolId: string): Future[NetRes[Connection]]
                {.async: (raises: [CancelledError]).} =
  # When dialing here, we do not provide addresses - all new connection
  # attempts are handled via `connect` which also takes into account
  # reconnection timeouts
  try:
    ok await dial(node.switch, peer.peerId, protocolId)
  except LPError as exc:
    debug "Dialing failed", exc = exc.msg
    neterr BrokenConnection
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    # TODO remove once libp2p supports `raises`
    debug "Unexpected error when opening stream", exc = exc.msg
    neterr UnknownError

proc init(T: type Peer, network: Eth2Node, peerId: PeerId): Peer {.gcsafe.}

func getState*(peer: Peer, proto: ProtocolInfo): RootRef =
  doAssert peer.protocolStates[proto.index] != nil, $proto.index
  peer.protocolStates[proto.index]

template state*(peer: Peer, Protocol: type): untyped =
  ## Returns the state object of a particular protocol for a
  ## particular connection.
  mixin State
  bind getState
  type S = Protocol.State
  S(getState(peer, Protocol.protocolInfo))

func getNetworkState*(node: Eth2Node, proto: ProtocolInfo): RootRef =
  doAssert node.protocolStates[proto.index] != nil, $proto.index
  node.protocolStates[proto.index]

template protocolState*(node: Eth2Node, Protocol: type): untyped =
  mixin NetworkState
  bind getNetworkState
  type S = Protocol.NetworkState
  S(getNetworkState(node, Protocol.protocolInfo))

func initProtocolState*[T](state: T, x: Peer|Eth2Node) {.raises: [].} =
  discard

template networkState*(connection: Peer, Protocol: type): untyped =
  ## Returns the network state object of a particular protocol for a
  ## particular connection.
  protocolState(connection.network, Protocol)

func peerId*(node: Eth2Node): PeerId =
  node.switch.peerInfo.peerId

func nodeId*(node: Eth2Node): NodeId =
  # `secp256k1` keys are always stored inside PeerId.
  toNodeId(keys.PublicKey(node.switch.peerInfo.publicKey.skkey))

func enrRecord*(node: Eth2Node): Record =
  node.discovery.localNode.record

proc getPeer(node: Eth2Node, peerId: PeerId): Peer =
  node.peers.withValue(peerId, peer) do:
    return peer[]
  do:
    let peer = Peer.init(node, peerId)
    return node.peers.mgetOrPut(peerId, peer)

proc peerFromStream(network: Eth2Node, conn: Connection): Peer =
  result = network.getPeer(conn.peerId)
  result.peerId = conn.peerId

func getKey*(peer: Peer): PeerId {.inline.} =
  peer.peerId

proc getFuture(peer: Peer): Future[void] {.inline.} =
  if isNil(peer.disconnectedFut):
    peer.disconnectedFut = newFuture[void]("Peer.disconnectedFut")
  peer.disconnectedFut

func getScore*(a: Peer): int =
  ## Returns current score value for peer ``peer``.
  a.score

func updateScore*(peer: Peer, score: int) {.inline.} =
  ## Update peer's ``peer`` score with value ``score``.
  peer.score = peer.score + score
  if peer.score > PeerScoreHighLimit:
    peer.score = PeerScoreHighLimit

func updateStats*(peer: Peer, index: SyncResponseKind,
                  value: uint64) {.inline.} =
  ## Update peer's ``peer`` specific ``index`` statistics with value ``value``.
  peer.statistics.update(index, value)

func getStats*(peer: Peer, index: SyncResponseKind): uint64 {.inline.} =
  ## Returns current statistics value for peer ``peer`` and index ``index``.
  peer.statistics.get(index)

func calcThroughput(dur: Duration, value: uint64): float =
  let secs = float(chronos.seconds(1).nanoseconds)
  if isZero(dur):
    0.0
  else:
    float(value) * (secs / float(dur.nanoseconds))

func updateNetThroughput(peer: Peer, dur: Duration,
                         bytesCount: uint64) {.inline.} =
  ## Update peer's ``peer`` network throughput.
  let bytesPerSecond = calcThroughput(dur, bytesCount)
  let a = peer.netThroughput.average
  let n = peer.netThroughput.count
  peer.netThroughput.average = a + (bytesPerSecond - a) / float(n + 1)
  inc(peer.netThroughput.count)

func netKbps*(peer: Peer): float {.inline.} =
  ## Returns current network throughput average value in Kbps for peer ``peer``.
  round(((peer.netThroughput.average / 1024) * 10_000) / 10_000)

# /!\ Must be exported to be seen by `peerCmp`
func `<`*(a, b: Peer): bool =
  ## Comparison function indicating `true` if peer `a` ranks worse than peer `b`
  if a.score != b.score:
    a.score < b.score
  elif a.netThroughput.average != b.netThroughput.average:
    a.netThroughput.average < b.netThroughput.average
  else:
    system.`<`(a, b)

const
  maxRequestQuota = 1000000
  maxGlobalQuota = 2 * maxRequestQuota
    ## Roughly, this means we allow 2 peers to sync from us at a time
  fullReplenishTime = 5.seconds

template awaitQuota*(peerParam: Peer, costParam: float, protocolIdParam: string) =
  let
    peer = peerParam
    cost = int(costParam)

  if not peer.quota.tryConsume(cost.int):
    let protocolId = protocolIdParam
    debug "Awaiting peer quota", peer, cost = cost, protocolId = protocolId
    nbc_reqresp_messages_throttled.inc(1, [protocolId])
    await peer.quota.consume(cost.int)

template awaitQuota*(
    networkParam: Eth2Node, costParam: float, protocolIdParam: string) =
  let
    network = networkParam
    cost = int(costParam)

  if not network.quota.tryConsume(cost.int):
    let protocolId = protocolIdParam
    debug "Awaiting network quota", peer, cost = cost, protocolId = protocolId
    nbc_reqresp_messages_throttled.inc(1, [protocolId])
    await network.quota.consume(cost.int)

func allowedOpsPerSecondCost*(n: int): float =
  const replenishRate = (maxRequestQuota / fullReplenishTime.nanoseconds.float)
  (replenishRate * 1000000000'f / n.float)

const
  libp2pRequestCost = allowedOpsPerSecondCost(8)
    ## Maximum number of libp2p requests per peer per second

proc isSeen(network: Eth2Node, peerId: PeerId): bool =
  ## Returns ``true`` if ``peerId`` present in SeenTable and time period is not
  ## yet expired.
  let currentTime = now(chronos.Moment)
  if peerId notin network.seenTable:
    false
  else:
    let item = try: network.seenTable[peerId]
    except KeyError: raiseAssert "checked with notin"
    if currentTime >= item.stamp:
      # Peer is in SeenTable, but the time period has expired.
      network.seenTable.del(peerId)
      false
    else:
      true

proc addSeen(network: Eth2Node, peerId: PeerId,
              period: chronos.Duration) =
  ## Adds peer with PeerId ``peerId`` to SeenTable and timeout ``period``.
  let item = SeenItem(peerId: peerId, stamp: now(chronos.Moment) + period)
  withValue(network.seenTable, peerId, entry) do:
    if entry.stamp < item.stamp:
      entry.stamp = item.stamp
  do:
    network.seenTable[peerId] = item

proc disconnect*(peer: Peer, reason: DisconnectionReason,
                 notifyOtherPeer = false) {.async: (raises: [CancelledError]).} =
  # Per the specification, we MAY send a disconnect reason to the other peer but
  # we currently don't - the fact that we're disconnecting is obvious and the
  # reason already known (wrong network is known from status message) or doesn't
  # greatly matter for the listening side (since it can't be trusted anyway)
  try:
    if peer.connectionState notin {Disconnecting, Disconnected}:
      peer.connectionState = Disconnecting
      # We adding peer in SeenTable before actual disconnect to avoid races.
      let seenTime = case reason
        of ClientShutDown:
          SeenTableTimeClientShutDown
        of IrrelevantNetwork:
          SeenTableTimeIrrelevantNetwork
        of FaultOrError:
          SeenTableTimeFaultOrError
        of PeerScoreLow:
          SeenTablePenaltyError
      peer.network.addSeen(peer.peerId, seenTime)
      await peer.network.switch.disconnect(peer.peerId)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    # switch.disconnect shouldn't raise
    warn "Unexpected error while disconnecting peer",
      peer = peer.peerId,
      reason = reason,
      exc = exc.msg

proc releasePeer(peer: Peer) =
  ## Checks for peer's score and disconnects peer if score is less than
  ## `PeerScoreLowLimit`.
  if peer.connectionState notin {ConnectionState.Disconnecting,
                                 ConnectionState.Disconnected}:
    if peer.score < PeerScoreLowLimit:
      debug "Peer was disconnected due to low score", peer = peer,
            peer_score = peer.score, score_low_limit = PeerScoreLowLimit,
            score_high_limit = PeerScoreHighLimit
      asyncSpawn(peer.disconnect(PeerScoreLow))

proc getRequestProtoName(fn: NimNode): NimNode =
  # `getCustomPragmaVal` doesn't work yet on regular nnkProcDef nodes
  # (TODO: file as an issue)

  let pragmas = fn.pragma
  if pragmas.kind == nnkPragma and pragmas.len > 0:
    for pragma in pragmas:
      try:
        if pragma.len > 0 and $pragma[0] == "libp2pProtocol":
          let protoName = $(pragma[1])
          let protoVer = $(pragma[2].intVal)
          return newLit(requestPrefix & protoName & "/" & protoVer & requestSuffix)
      except Exception as exc: raiseAssert exc.msg # TODO https://github.com/nim-lang/Nim/issues/17454

  return newLit("")

func add(s: var seq[byte], pos: var int, bytes: openArray[byte]) =
  s[pos..<pos+bytes.len] = bytes
  pos += bytes.len

proc writeChunkSZ(
    conn: Connection, responseCode: Opt[ResponseCode],
    uncompressedLen: uint64, payloadSZ: openArray[byte],
    contextBytes: openArray[byte] = []): Future[void] =
  let
    uncompressedLenBytes = toBytes(uncompressedLen, Leb128)

  var
    data = newSeqUninitialized[byte](
      ord(responseCode.isSome) + contextBytes.len + uncompressedLenBytes.len +
      payloadSZ.len)
    pos = 0

  if responseCode.isSome:
    data.add(pos, [byte responseCode.get])
  data.add(pos, contextBytes)
  data.add(pos, uncompressedLenBytes.toOpenArray())
  data.add(pos, payloadSZ)
  conn.write(data)

proc writeChunk(conn: Connection,
                responseCode: Opt[ResponseCode],
                payload: openArray[byte],
                contextBytes: openArray[byte] = []): Future[void] =
  let
    uncompressedLenBytes = toBytes(payload.lenu64, Leb128)
  var
    data = newSeqUninitialized[byte](
      ord(responseCode.isSome) + contextBytes.len + uncompressedLenBytes.len +
      snappy.maxCompressedLenFramed(payload.len).int)
    pos = 0

  if responseCode.isSome:
    data.add(pos, [byte responseCode.get])
  data.add(pos, contextBytes)
  data.add(pos, uncompressedLenBytes.toOpenArray())
  let
    pre = pos
    written = snappy.compressFramed(payload, data.toOpenArray(pos, data.high))
      .expect("compression shouldn't fail with correctly preallocated buffer")
  data.setLen(pre + written)

  conn.write(data)

template errorMsgLit(x: static string): ErrorMsg =
  const val = ErrorMsg toBytes(x)
  val

func formatErrorMsg(msg: ErrorMsg): string =
  # ErrorMsg "usually" contains a human-readable string - we'll try to parse it
  # as ASCII and return hex if that fails
  for c in msg:
    if c < 32 or c > 127:
      return byteutils.toHex(asSeq(msg))

  string.fromBytes(asSeq(msg))

proc sendErrorResponse(peer: Peer,
                       conn: Connection,
                       responseCode: ResponseCode,
                       errMsg: ErrorMsg): Future[void] =
  debug "Error processing request",
    peer, responseCode, errMsg = formatErrorMsg(errMsg)
  conn.writeChunk(Opt.some responseCode, SSZ.encode(errMsg))

proc sendNotificationMsg(peer: Peer, protocolId: string, requestBytes: seq[byte])
    {.async: (raises: [CancelledError]).} =
  # Notifications are sent as a best effort, ie errors are not reported back
  # to the caller
  let
    deadline = sleepAsync RESP_TIMEOUT_DUR
    streamRes = awaitWithTimeout(peer.network.openStream(peer, protocolId), deadline):
      debug "Timeout while opening stream for notification", peer, protocolId
      return

  let stream = streamRes.valueOr:
    debug "Could not open stream for notification",
      peer, protocolId, error = streamRes.error
    return

  try:
    await stream.writeChunk(Opt.none ResponseCode, requestBytes)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "Error while writing notification", peer, protocolId, exc = exc.msg
  finally:
    try:
      await noCancel stream.close()
    except CatchableError as exc:
      debug "Unexpected error while closing notification stream",
        peer, protocolId, exc = exc.msg

proc sendResponseChunkBytesSZ(
    response: UntypedResponse, uncompressedLen: uint64,
    payloadSZ: openArray[byte],
    contextBytes: openArray[byte] = []): Future[void] =
  inc response.writtenChunks
  response.stream.writeChunkSZ(
    Opt.some ResponseCode.Success, uncompressedLen, payloadSZ, contextBytes)

proc sendResponseChunkBytes(
    response: UntypedResponse, payload: openArray[byte],
    contextBytes: openArray[byte] = []): Future[void] =
  inc response.writtenChunks
  response.stream.writeChunk(Opt.some ResponseCode.Success, payload, contextBytes)

proc sendResponseChunk(
    response: UntypedResponse, val: auto,
    contextBytes: openArray[byte] = []): Future[void] =
  sendResponseChunkBytes(response, SSZ.encode(val), contextBytes)

template sendUserHandlerResultAsChunkImpl*(stream: Connection,
                                           handlerResultFut: Future): untyped =
  let handlerRes = await handlerResultFut
  writeChunk(stream, Opt.some ResponseCode.Success, SSZ.encode(handlerRes))

template sendUserHandlerResultAsChunkImpl*(stream: Connection,
                                           handlerResult: auto): untyped =
  writeChunk(stream, Opt.some ResponseCode.Success, SSZ.encode(handlerResult))

proc uncompressFramedStream(conn: Connection,
                            expectedSize: int): Future[Result[seq[byte], string]]
                            {.async: (raises: [CancelledError]).} =
  var header: array[framingHeader.len, byte]
  try:
    await conn.readExactly(addr header[0], header.len)
  except LPStreamEOFError, LPStreamIncompleteError:
    return err "Unexpected EOF before snappy header"
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return err "Unexpected error reading header: " & exc.msg

  if header != framingHeader:
    return err "Incorrect snappy header"

  static:
    doAssert maxCompressedFrameDataLen >= maxUncompressedFrameDataLen.uint64

  var
    frameData = newSeqUninitialized[byte](maxCompressedFrameDataLen + 4)
    output = newSeqUninitialized[byte](expectedSize)
    written = 0

  while written < expectedSize:
    var frameHeader: array[4, byte]
    try:
      await conn.readExactly(addr frameHeader[0], frameHeader.len)
    except LPStreamEOFError, LPStreamIncompleteError:
      return err "Snappy frame header missing"
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      return err "Unexpected error reading frame header: " & exc.msg

    let (id, dataLen) = decodeFrameHeader(frameHeader)

    if dataLen > frameData.len:
      # In theory, compressed frames could be bigger and still result in a
      # valid, small snappy frame, but this would mean they are not getting
      # compressed correctly
      return err "Snappy frame too big"

    if dataLen > 0:
      try:
        await conn.readExactly(addr frameData[0], dataLen)
      except LPStreamEOFError, LPStreamIncompleteError:
        return err "Incomplete snappy frame"
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        return err "Unexpected error reading frame data: " & exc.msg

    if id == chunkCompressed:
      if dataLen < 6: # At least CRC + 2 bytes of frame data
        return err "Compressed snappy frame too small"

      let
        crc = uint32.fromBytesLE frameData.toOpenArray(0, 3)
        uncompressed =
          snappy.uncompress(
            frameData.toOpenArray(4, dataLen - 1),
            output.toOpenArray(written, output.high)).valueOr:
              return err "Failed to decompress content"

      if maskedCrc(
          output.toOpenArray(written, written + uncompressed-1)) != crc:
        return err "Snappy content CRC checksum failed"

      written += uncompressed

    elif id == chunkUncompressed:
      if dataLen < 5: # At least one byte of data
        return err "Uncompressed snappy frame too small"

      let uncompressed = dataLen - 4

      if uncompressed > maxUncompressedFrameDataLen.int:
        return err "Snappy frame size too large"

      if uncompressed > output.len - written:
        return err "Too much data"

      let crc = uint32.fromBytesLE frameData.toOpenArray(0, 3)
      if maskedCrc(frameData.toOpenArray(4, dataLen - 1)) != crc:
        return err "Snappy content CRC checksum failed"

      output[written..<written + uncompressed] =
        frameData.toOpenArray(4, dataLen-1)
      written += uncompressed

    elif id < 0x80:
      # Reserved unskippable chunks (chunk types 0x02-0x7f)
      # if we encounter this type of chunk, stop decoding
      # the spec says it is an error
      return err "Invalid snappy chunk type"

    else:
      # Reserved skippable chunks (chunk types 0x80-0xfe)
      # including STREAM_HEADER (0xff) should be skipped
      continue

  return ok output

func chunkMaxSize[T](): uint32 =
  # compiler error on (T: type) syntax...
  when isFixedSize(T):
    uint32 fixedPortionSize(T)
  else:
    static: doAssert MAX_CHUNK_SIZE < high(uint32).uint64
    MAX_CHUNK_SIZE.uint32

template gossipMaxSize(T: untyped): uint32 =
  const maxSize = static:
    when isFixedSize(T):
      fixedPortionSize(T).uint32
    elif T is bellatrix.SignedBeaconBlock or T is capella.SignedBeaconBlock or
         T is deneb.SignedBeaconBlock or T is electra.SignedBeaconBlock or
         T is fulu.SignedBeaconBlock:
      GOSSIP_MAX_SIZE
    # TODO https://github.com/status-im/nim-ssz-serialization/issues/20 for
    # Attestation, AttesterSlashing, and SignedAggregateAndProof, which all
    # have lists bounded at MAX_VALIDATORS_PER_COMMITTEE (2048) items, thus
    # having max sizes significantly smaller than GOSSIP_MAX_SIZE.
    elif T is phase0.Attestation or T is phase0.AttesterSlashing or
         T is phase0.SignedAggregateAndProof or T is phase0.SignedBeaconBlock or
         T is electra.SignedAggregateAndProof or T is electra.Attestation or
         T is electra.AttesterSlashing or T is altair.SignedBeaconBlock or
         T is SomeForkyLightClientObject:
      GOSSIP_MAX_SIZE
    else:
      {.fatal: "unknown type " & name(T).}
  static: doAssert maxSize <= GOSSIP_MAX_SIZE
  maxSize.uint32

proc readVarint2(conn: Connection): Future[NetRes[uint64]] {.
    async: (raises: [CancelledError]).} =
  try:
    ok await conn.readVarint()
  except LPStreamEOFError: #, LPStreamIncompleteError, InvalidVarintError
    # TODO compiler error - haha, uncaught exception
    # Error: unhandled exception: closureiters.nim(322, 17) `c[i].kind == nkType`  [AssertionError]
    neterr UnexpectedEOF
  except LPStreamIncompleteError:
    neterr UnexpectedEOF
  except InvalidVarintError:
    neterr InvalidSizePrefix
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "Unexpected error", exc = exc.msg
    neterr UnknownError

proc readChunkPayload*(conn: Connection, peer: Peer,
                       MsgType: type): Future[NetRes[MsgType]]
                       {.async: (raises: [CancelledError]).} =
  let
    sm = now(chronos.Moment)
    size = ? await readVarint2(conn)

  const maxSize = chunkMaxSize[MsgType]()
  if size > maxSize:
    return neterr SizePrefixOverflow
  if size == 0:
    return neterr ZeroSizePrefix

  # The `size.int` conversion is safe because `size` is bounded to `MAX_CHUNK_SIZE`
  let
    dataRes = await conn.uncompressFramedStream(size.int)
    data = dataRes.valueOr:
      debug "Snappy decompression/read failed", msg = $dataRes.error, conn
      return neterr InvalidSnappyBytes

  # `10` is the maximum size of variable integer on wire, so error could
  # not be significant.
  peer.updateNetThroughput(now(chronos.Moment) - sm,
                            uint64(10 + size))
  try:
    ok SSZ.decode(data, MsgType)
  except SerializationError:
    neterr InvalidSszBytes

proc readResponseChunk(
    conn: Connection, peer: Peer, MsgType: typedesc):
    Future[NetRes[MsgType]] {.async: (raises: [CancelledError]).} =
  mixin readChunkPayload

  var responseCodeByte: byte
  try:
    await conn.readExactly(addr responseCodeByte, 1)
  except LPStreamEOFError, LPStreamIncompleteError:
    return neterr PotentiallyExpectedEOF
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "Unexpected error", exc = exc.msg
    return neterr UnknownError

  static: assert ResponseCode.low.ord == 0
  if responseCodeByte > ResponseCode.high.byte:
    return neterr InvalidResponseCode

  let responseCode = ResponseCode responseCodeByte
  case responseCode:
  of InvalidRequest, ServerError, ResourceUnavailable:
    let
      errorMsg = ? await readChunkPayload(conn, peer, ErrorMsg)
      errorMsgStr = toPrettyString(errorMsg.asSeq)
    debug "Error response from peer", responseCode, errMsg = errorMsgStr
    return err Eth2NetworkingError(kind: ReceivedErrorResponse,
                                    responseCode: responseCode,
                                    errorMsg: errorMsgStr)
  of Success:
    discard

  return await readChunkPayload(conn, peer, MsgType)

proc readResponse(conn: Connection, peer: Peer,
                  MsgType: type, timeout: Duration): Future[NetRes[MsgType]]
                  {.async: (raises: [CancelledError]).} =
  when MsgType is List:
    type E = MsgType.T
    var results: MsgType
    while true:
      # Because we interleave networking with response processing, it may
      # happen that reading all chunks takes longer than a strict dealine
      # timeout would allow, so we allow each chunk a new timeout instead.
      # The problem is exacerbated by the large number of round-trips to the
      # poll loop that each future along the way causes.
      trace "reading chunk", conn
      let nextFut = conn.readResponseChunk(peer, E)
      if not await nextFut.withTimeout(timeout):
        return neterr(ReadResponseTimeout)
      let nextRes = await nextFut
      if nextRes.isErr:
        if nextRes.error.kind == PotentiallyExpectedEOF:
          trace "EOF chunk", conn, err = nextRes.error

          return ok results
        trace "Error chunk", conn, err = nextRes.error

        return err nextRes.error
      else:
        trace "Got chunk", conn
        if not results.add nextRes.value:
          return neterr(ResponseChunkOverflow)
  else:
    let nextFut = conn.readResponseChunk(peer, MsgType)
    if not await nextFut.withTimeout(timeout):
      return neterr(ReadResponseTimeout)
    return await nextFut # Guaranteed to complete without waiting

proc makeEth2Request(peer: Peer, protocolId: string, requestBytes: seq[byte],
                     ResponseMsg: type,
                     timeout: Duration): Future[NetRes[ResponseMsg]]
                    {.async: (raises: [CancelledError]).} =
  let
    deadline = sleepAsync timeout
    streamRes =
      awaitWithTimeout(peer.network.openStream(peer, protocolId), deadline):
        peer.updateScore(PeerScorePoorRequest)
        return neterr StreamOpenTimeout
    stream = streamRes.valueOr:
      if streamRes.error().kind in ProtocolViolations:
        peer.updateScore(PeerScoreInvalidRequest)
      else:
        peer.updateScore(PeerScorePoorRequest)
      return err streamRes.error()

  try:
    # Send the request
    # Some clients don't want a length sent for empty requests
    # So don't send anything on empty requests
    if requestBytes.len > 0:
      await stream.writeChunk(Opt.none ResponseCode, requestBytes)
    # Half-close the stream to mark the end of the request - if this is not
    # done, the other peer might never send us the response.
    await stream.close()

    nbc_reqresp_messages_sent.inc(1, [shortProtocolId(protocolId)])

    # Read the response
    let res = await readResponse(stream, peer, ResponseMsg, timeout)
    if res.isErr():
      if res.error().kind in ProtocolViolations:
        peer.updateScore(PeerScoreInvalidRequest)
      else:
        peer.updateScore(PeerScorePoorRequest)
    res
  except CancelledError as exc:
    raise exc
  except CatchableError:
    peer.updateScore(PeerScorePoorRequest)
    neterr BrokenConnection
  finally:
    try:
      await noCancel stream.closeWithEOF()
    except CatchableError as exc:
      debug "Unexpected error while closing stream",
        peer, protocolId, exc = exc.msg

func init*(T: type MultipleChunksResponse, peer: Peer, conn: Connection): T =
  T(UntypedResponse(peer: peer, stream: conn))

func init*[MsgType](T: type SingleChunkResponse[MsgType],
                    peer: Peer, conn: Connection): T =
  T(UntypedResponse(peer: peer, stream: conn))

template write*[M; maxLen: static Limit](
    r: MultipleChunksResponse[M, maxLen], val: M,
    contextBytes: openArray[byte] = []): untyped =
  mixin sendResponseChunk
  sendResponseChunk(UntypedResponse(r), val, contextBytes)

template writeSSZ*[M; maxLen: static Limit](
    r: MultipleChunksResponse[M, maxLen], val: auto,
    contextBytes: openArray[byte] = []): untyped =
  mixin sendResponseChunk
  sendResponseChunk(UntypedResponse(r), val, contextBytes)

template writeBytesSZ*(
    r: MultipleChunksResponse, uncompressedLen: uint64,
    bytes: openArray[byte], contextBytes: openArray[byte]): untyped =
  sendResponseChunkBytesSZ(UntypedResponse(r), uncompressedLen, bytes, contextBytes)

template send*[M](
    r: SingleChunkResponse[M], val: M,
    contextBytes: openArray[byte] = []): untyped =
  mixin sendResponseChunk
  doAssert UntypedResponse(r).writtenChunks == 0
  sendResponseChunk(UntypedResponse(r), val, contextBytes)

template sendSSZ*[M](
    r: SingleChunkResponse[M], val: auto,
    contextBytes: openArray[byte] = []): untyped =
  mixin sendResponseChunk
  doAssert UntypedResponse(r).writtenChunks == 0
  sendResponseChunk(UntypedResponse(r), val, contextBytes)

proc performProtocolHandshakes(peer: Peer, incoming: bool) {.async: (raises: [CancelledError]).} =
  # Loop down serially because it's easier to reason about the connection state
  # when there are fewer async races, specially during setup
  for protocol in peer.network.protocols:
    if protocol.onPeerConnected != nil:
      await protocol.onPeerConnected(peer, incoming)

func initProtocol(name: string,
                  peerInit: PeerStateInitializer,
                  networkInit: NetworkStateInitializer,
                  index: int): ProtocolInfoObj =
  ProtocolInfoObj(
    name: name,
    messages: @[],
    index: index,
    peerStateInitializer: peerInit,
    networkStateInitializer: networkInit)

func setEventHandlers(p: ProtocolInfo,
                      onPeerConnected: OnPeerConnectedHandler,
                      onPeerDisconnected: OnPeerDisconnectedHandler) =
  p.onPeerConnected = onPeerConnected
  p.onPeerDisconnected = onPeerDisconnected

proc implementSendProcBody(sendProc: SendProc) =
  let
    msg = sendProc.msg
    UntypedResponse = bindSym "UntypedResponse"

  proc sendCallGenerator(peer, bytes: NimNode): NimNode =
    if msg.kind != msgResponse:
      let msgProto = getRequestProtoName(msg.procDef)
      case msg.kind
      of msgRequest:
        let ResponseRecord = msg.response.recName
        quote:
          makeEth2Request(`peer`, `msgProto`, `bytes`,
                          `ResponseRecord`, `timeoutVar`)
      else:
        quote: sendNotificationMsg(`peer`, `msgProto`, `bytes`)
    else:
      quote: sendResponseChunkBytes(`UntypedResponse`(`peer`), `bytes`)

  sendProc.useStandardBody(nil, nil, sendCallGenerator)

proc handleIncomingStream(network: Eth2Node,
                          conn: Connection,
                          protocolId: string,
                          MsgType: type) {.async: (raises: [CancelledError]).} =
  mixin callUserHandler, RecType

  type MsgRec = RecType(MsgType)
  const msgName {.used.} = typetraits.name(MsgType)

  ## Uncomment this to enable tracing on all incoming requests
  ## You can include `msgNameLit` in the condition to select
  ## more specific requests:
  # when chronicles.runtimeFilteringEnabled:
  #   setLogLevel(LogLevel.TRACE)
  #   defer: setLogLevel(LogLevel.DEBUG)
  #   trace "incoming " & `msgNameLit` & " conn"

  let peer = peerFromStream(network, conn)
  try:
    case peer.connectionState
    of Disconnecting, Disconnected, None:
      # We got incoming stream request while disconnected or disconnecting.
      debug "Got incoming request from disconnected peer", peer = peer,
           message = msgName
      return
    of Connecting:
      # We got incoming stream request while handshake is not yet finished,
      # TODO: We could check it here.
      debug "Got incoming request from peer while in handshake", peer = peer,
            msgName
    of Connected:
      # We got incoming stream from peer with proper connection state.
      debug "Got incoming request from peer", peer = peer, msgName

    template returnInvalidRequest(msg: ErrorMsg) =
      peer.updateScore(PeerScoreInvalidRequest)
      await sendErrorResponse(peer, conn, InvalidRequest, msg)
      return

    template returnInvalidRequest(msg: string) =
      returnInvalidRequest(ErrorMsg msg.toBytes)

    template returnResourceUnavailable(msg: ErrorMsg) =
      await sendErrorResponse(peer, conn, ResourceUnavailable, msg)
      return

    template returnResourceUnavailable(msg: string) =
      returnResourceUnavailable(ErrorMsg msg.toBytes)

    nbc_reqresp_messages_received.inc(1, [shortProtocolId(protocolId)])

    const isEmptyMsg = when MsgRec is object:
      # We need nested `when` statements here, because Nim doesn't properly
      # apply boolean short-circuit logic at compile time and this causes
      # `totalSerializedFields` to be applied to non-object types that it
      # doesn't know how to support.
      when totalSerializedFields(MsgRec) == 0: true
      else: false
    else:
      false

    let msg =
      try:
        when isEmptyMsg:
          NetRes[MsgRec].ok default(MsgRec)
        else:
          # TODO(zah) The TTFB timeout is not implemented in LibP2P streams
          # back-end
          let deadline = sleepAsync RESP_TIMEOUT_DUR

          awaitWithTimeout(
            readChunkPayload(conn, peer, MsgRec), deadline):
              # Timeout, e.g., cancellation due to fulfillment by different peer.
              # Treat this similarly to `UnexpectedEOF`, `PotentiallyExpectedEOF`.
              nbc_reqresp_messages_failed.inc(1, [shortProtocolId(protocolId)])
              await sendErrorResponse(
                peer, conn, InvalidRequest,
                errorMsgLit "Request full data not sent in time")
              return

      finally:
        # The request quota is shared between all requests - it represents the
        # cost to perform a service on behalf of a client and is incurred
        # regardless if the request succeeds or fails - we don't count waiting
        # for this quota against timeouts so as not to prematurely disconnect
        # clients that are on the edge - nonetheless, the client will count it.

        # When a client exceeds their quota, they will be slowed down without
        # notification - as long as they don't make parallel requests (which is
        # limited by libp2p), this will naturally adapt them to the available
        # quota.

        # Note that the `msg` will be stored in memory while we wait for the
        # quota to be available. The amount of such messages in memory is
        # bounded by the libp2p limit of parallel streams

        # This quota also applies to invalid requests thanks to the use of
        # `finally`.

        awaitQuota(peer, libp2pRequestCost, shortProtocolId(protocolId))

    if msg.isErr:
      if msg.error.kind in ProtocolViolations:
        peer.updateScore(PeerScoreInvalidRequest)
      else:
        peer.updateScore(PeerScorePoorRequest)

      nbc_reqresp_messages_failed.inc(1, [shortProtocolId(protocolId)])
      let (responseCode, errMsg) = case msg.error.kind
        of UnexpectedEOF, PotentiallyExpectedEOF:
          nbc_reqresp_messages_failed.inc(1, [shortProtocolId(protocolId)])
          (InvalidRequest, errorMsgLit "Incomplete request")

        of InvalidContextBytes:
          (ServerError, errorMsgLit "Unrecognized context bytes")

        of InvalidSnappyBytes:
          (InvalidRequest, errorMsgLit "Failed to decompress snappy payload")

        of InvalidSszBytes:
          (InvalidRequest, errorMsgLit "Failed to decode SSZ payload")

        of InvalidSizePrefix:
          (InvalidRequest, errorMsgLit "Invalid chunk size prefix")

        of ZeroSizePrefix:
          (InvalidRequest, errorMsgLit "The request chunk cannot have a size of zero")

        of SizePrefixOverflow:
          (InvalidRequest, errorMsgLit "The chunk size exceed the maximum allowed")

        of InvalidResponseCode, ReceivedErrorResponse,
           StreamOpenTimeout, ReadResponseTimeout:
          # These shouldn't be possible in a request, because
          # there are no response codes being read, no stream
          # openings and no reading of responses:
          (ServerError, errorMsgLit "Internal server error")

        of BrokenConnection:
          return

        of ResponseChunkOverflow:
          (InvalidRequest, errorMsgLit "Too many chunks in response")

        of UnknownError:
          (InvalidRequest, errorMsgLit "Unknown error while processing request")

      await sendErrorResponse(peer, conn, responseCode, errMsg)
      return

    try:
      # logReceivedMsg(peer, MsgType(msg.get))
      await callUserHandler(MsgType, peer, conn, msg.get)
    except InvalidInputsError as exc:
      nbc_reqresp_messages_failed.inc(1, [shortProtocolId(protocolId)])
      returnInvalidRequest exc.msg
    except ResourceUnavailableError as exc:
      returnResourceUnavailable exc.msg
    except CatchableError as exc:
      nbc_reqresp_messages_failed.inc(1, [shortProtocolId(protocolId)])
      await sendErrorResponse(peer, conn, ServerError, ErrorMsg exc.msg.toBytes)

  except CatchableError as exc:
    nbc_reqresp_messages_failed.inc(1, [shortProtocolId(protocolId)])
    debug "Error processing an incoming request", exc = exc.msg, msgName

  finally:
    try:
      await noCancel conn.closeWithEOF()
    except CatchableError as exc:
      debug "Unexpected error while closing incoming connection", exc = exc.msg
    releasePeer(peer)

func toPeerAddr*(r: enr.TypedRecord,
                 proto: IpTransportProtocol): Result[PeerAddr, cstring] =
  if not r.secp256k1.isSome:
    return err("enr: no secp256k1 key in record")

  let
    pubKey = ? keys.PublicKey.fromRaw(r.secp256k1.get)
    peerId = ? PeerId.init(crypto.PublicKey(
      scheme: Secp256k1, skkey: secp.SkPublicKey(pubKey)))

  var addrs = newSeq[MultiAddress]()

  case proto
  of tcpProtocol:
    if r.ip.isSome and r.tcp.isSome:
      let ip = IpAddress(
        family: IpAddressFamily.IPv4,
        address_v4: r.ip.get)
      addrs.add MultiAddress.init(ip, tcpProtocol, Port r.tcp.get)

    if r.ip6.isSome:
      let ip = IpAddress(
        family: IpAddressFamily.IPv6,
        address_v6: r.ip6.get)
      if r.tcp6.isSome:
        addrs.add MultiAddress.init(ip, tcpProtocol, Port r.tcp6.get)
      elif r.tcp.isSome:
        addrs.add MultiAddress.init(ip, tcpProtocol, Port r.tcp.get)
      else:
        discard

  of udpProtocol:
    if r.ip.isSome and r.udp.isSome:
      let ip = IpAddress(
        family: IpAddressFamily.IPv4,
        address_v4: r.ip.get)
      addrs.add MultiAddress.init(ip, udpProtocol, Port r.udp.get)

    if r.ip6.isSome:
      let ip = IpAddress(
        family: IpAddressFamily.IPv6,
        address_v6: r.ip6.get)
      if r.udp6.isSome:
        addrs.add MultiAddress.init(ip, udpProtocol, Port r.udp6.get)
      elif r.udp.isSome:
        addrs.add MultiAddress.init(ip, udpProtocol, Port r.udp.get)
      else:
        discard

  if addrs.len == 0:
    return err("enr: no addresses in record")

  ok(PeerAddr(peerId: peerId, addrs: addrs))

proc checkPeer(node: Eth2Node, peerAddr: PeerAddr): bool =
  logScope: peer = peerAddr.peerId
  let peerId = peerAddr.peerId
  if node.peerPool.hasPeer(peerId):
    trace "Already connected"
    false
  else:
    if node.isSeen(peerId):
      trace "Recently connected"
      false
    else:
      true

proc dialPeer(node: Eth2Node, peerAddr: PeerAddr, index = 0) {.async: (raises: [CancelledError]).} =
  ## Establish connection with remote peer identified by address ``peerAddr``.
  logScope:
    peer = peerAddr.peerId
    index = index

  if not(node.checkPeer(peerAddr)):
    return

  debug "Connecting to discovered peer"
  var deadline = sleepAsync(node.connectTimeout)
  var workfut = node.switch.connect(
    peerAddr.peerId,
    peerAddr.addrs,
    forceDial = true
  )

  try:
    # `or` operation will only raise exception of `workfut`, because `deadline`
    # could not raise exception.
    await workfut or deadline
    if workfut.finished():
      if not deadline.finished():
        deadline.cancelSoon()
      inc nbc_successful_dials
    else:
      debug "Connection to remote peer timed out"
      inc nbc_timeout_dials
      node.addSeen(peerAddr.peerId, SeenTableTimeTimeout)
      await cancelAndWait(workfut)
  except CatchableError as exc:
    debug "Connection to remote peer failed", msg = exc.msg
    inc nbc_failed_dials
    node.addSeen(peerAddr.peerId, SeenTableTimeDeadPeer)

proc connectWorker(node: Eth2Node, index: int) {.async: (raises: [CancelledError]).} =
  debug "Connection worker started", index = index
  while true:
    # This loop will never produce HIGH CPU usage because it will wait
    # and block until it not obtains new peer from the queue ``connQueue``.
    let remotePeerAddr = await node.connQueue.popFirst()
    # Previous worker dial might have hit the maximum peers.
    # TODO: could clear the whole connTable and connQueue here also, best
    # would be to have this event based coming from peer pool or libp2p.

    if node.peerPool.len < node.hardMaxPeers:
      await node.dialPeer(remotePeerAddr, index)
    # Peer was added to `connTable` before adding it to `connQueue`, so we
    # excluding peer here after processing.
    node.connTable.excl(remotePeerAddr.peerId)

func toPeerAddr(node: Node): Result[PeerAddr, cstring] =
  let nodeRecord = TypedRecord.fromRecord(node.record)
  let peerAddr = ? nodeRecord.toPeerAddr(tcpProtocol)
  ok(peerAddr)

proc trimConnections(node: Eth2Node, count: int) =
  # Kill `count` peers, scoring them to remove the least useful ones

  var scores = initOrderedTable[PeerId, int]()

  # Take into account the stabilitySubnets
  # During sync, only this will be used to score peers
  # since gossipsub is not running yet
  #
  # A peer subscribed to all stabilitySubnets will
  # have 640 points
  var peersInGracePeriod = 0
  for peer in node.peers.values:
    if peer.connectionState != Connected: continue

    # Metadata pinger is used as grace period
    if peer.metadata.isNone:
      peersInGracePeriod.inc()
      continue

    let
      stabilitySubnets = peer.metadata.get().attnets
      stabilitySubnetsCount = stabilitySubnets.countOnes()
      thisPeersScore = 10 * stabilitySubnetsCount

    scores[peer.peerId] = thisPeersScore


  # Safegard: if we have too many peers in the grace
  # period, don't kick anyone. Otherwise, they will be
  # preferred over long-standing peers
  if peersInGracePeriod > scores.len div 2:
    return

  # Split a 1000 points for each topic's peers
  # + 5 000 points for each subbed topic
  # This gives priority to peers in topics with few peers
  # For instance, a topic with `dHigh` peers will give 80 points to each peer
  # Whereas a topic with `dLow` peers will give 250 points to each peer
  #
  # Then, use the average of all topics per peers, to avoid giving too much
  # point to big peers

  var gossipScores = initTable[PeerId, tuple[sum: int, count: int]]()
  for topic, _ in node.pubsub.gossipsub:
    let
      peersInMesh = node.pubsub.mesh.peers(topic)
      peersSubbed = node.pubsub.gossipsub.peers(topic)
      scorePerMeshPeer = 5_000 div max(peersInMesh, 1)
      scorePerSubbedPeer = 1_000 div max(peersSubbed, 1)

    for peer in node.pubsub.gossipsub.getOrDefault(topic):
      if peer.peerId notin scores: continue
      let currentVal = gossipScores.getOrDefault(peer.peerId)
      gossipScores[peer.peerId] = (
        currentVal.sum + scorePerSubbedPeer,
        currentVal.count + 1
      )

    # Avoid global topics (>75% of peers), which would greatly reduce
    # the average score for small peers
    if peersSubbed > scores.len div 4 * 3: continue

    for peer in node.pubsub.mesh.getOrDefault(topic):
      if peer.peerId notin scores: continue
      let currentVal = gossipScores.getOrDefault(peer.peerId)
      gossipScores[peer.peerId] = (
        currentVal.sum + scorePerMeshPeer,
        currentVal.count + 1
      )

  for peerId, gScore in gossipScores:
    scores[peerId] =
      scores.getOrDefault(peerId) + (gScore.sum div gScore.count)

  proc sortPerScore(a, b: (PeerId, int)): int =
    system.cmp(a[1], b[1])

  scores.sort(sortPerScore)

  var toKick = count

  for peerId in scores.keys:
    if peerId in node.directPeers: continue
    debug "kicking peer", peerId, score=scores[peerId]
    asyncSpawn node.getPeer(peerId).disconnect(PeerScoreLow)
    dec toKick
    inc(nbc_cycling_kicked_peers)
    if toKick <= 0: return

proc getLowSubnets(node: Eth2Node, epoch: Epoch):
                  (AttnetBits, SyncnetBits, CscBits) =
  # Returns the subnets required to have a healthy mesh
  # The subnets are computed, to, in order:
  # - Have 0 subnet with < `dLow` peers from topic subscription
  # - Have 0 subscribed subnet below `dLow`
  # - Have 0 subscribed subnet below `dOut` outgoing peers
  # - Have 0 subnet with < `dHigh` peers from topic subscription

  nbc_gossipsub_low_fanout.set(0)
  nbc_gossipsub_good_fanout.set(0)
  nbc_gossipsub_healthy_fanout.set(0)

  template findLowSubnets(topicNameGenerator: untyped,
                          SubnetIdType: type,
                          totalSubnets: static int): auto =
    var
      lowOutgoingSubnets: BitArray[totalSubnets]
      notHighOutgoingSubnets: BitArray[totalSubnets]
      belowDSubnets: BitArray[totalSubnets]
      belowDOutSubnets: BitArray[totalSubnets]

    for subNetId in 0 ..< totalSubnets:
      let topic =
        topicNameGenerator(node.forkId.fork_digest, SubnetIdType(subNetId))

      if node.pubsub.gossipsub.peers(topic) < node.pubsub.parameters.dLow:
        lowOutgoingSubnets.setBit(subNetId)

      if node.pubsub.gossipsub.peers(topic) < node.pubsub.parameters.dHigh:
        notHighOutgoingSubnets.setBit(subNetId)

      # Not subscribed
      if topic notin node.pubsub.mesh: continue

      if node.pubsub.mesh.peers(topic) < node.pubsub.parameters.dLow:
        belowDSubnets.setBit(subNetId)

      let outPeers = node.pubsub.mesh.getOrDefault(topic).countIt(it.outbound)
      if outPeers < node.pubsub.parameters.dOut:
        belowDOutSubnets.setBit(subNetId)

    nbc_gossipsub_low_fanout.inc(int64(lowOutgoingSubnets.countOnes()))
    nbc_gossipsub_good_fanout.inc(int64(
      notHighOutgoingSubnets.countOnes() -
      lowOutgoingSubnets.countOnes()
    ))
    nbc_gossipsub_healthy_fanout.inc(int64(
      totalSubnets - notHighOutgoingSubnets.countOnes()))

    if lowOutgoingSubnets.countOnes() > 0:
      lowOutgoingSubnets
    elif belowDSubnets.countOnes() > 0:
      belowDSubnets
    elif belowDOutSubnets.countOnes() > 0:
      belowDOutSubnets
    else:
      notHighOutgoingSubnets

  return (
    findLowSubnets(getAttestationTopic, SubnetId, ATTESTATION_SUBNET_COUNT.int),
    # We start looking one epoch before the transition in order to allow
    # some time for the gossip meshes to get healthy:
    if epoch + 1 >= node.cfg.ALTAIR_FORK_EPOCH:
      findLowSubnets(getSyncCommitteeTopic, SyncSubcommitteeIndex, SYNC_COMMITTEE_SUBNET_COUNT)
    else:
      default(SyncnetBits),
    if epoch >= node.cfg.FULU_FORK_EPOCH:
      findLowSubnets(getDataColumnSidecarTopic, uint64, (DATA_COLUMN_SIDECAR_SUBNET_COUNT).int)
    else:
      default(CscBits)
  )

proc runDiscoveryLoop(node: Eth2Node) {.async: (raises: [CancelledError]).} =
  debug "Starting discovery loop"

  while true:
    let
      currentEpoch = node.getBeaconTime().slotOrZero.epoch
      (wantedAttnets, wantedSyncnets, wantedCscnets) = node.getLowSubnets(currentEpoch)
      wantedAttnetsCount = wantedAttnets.countOnes()
      wantedSyncnetsCount = wantedSyncnets.countOnes()
      wantedCscnetsCount = wantedCscnets.countOnes()
      outgoingPeers = node.peerPool.lenCurrent({PeerType.Outgoing})
      targetOutgoingPeers = max(node.wantedPeers div 10, 3)

    if wantedAttnetsCount > 0 or wantedSyncnetsCount > 0 or
        wantedCscnetsCount > 0 or outgoingPeers < targetOutgoingPeers:

      let
        minScore =
          if wantedAttnetsCount > 0 or wantedSyncnetsCount > 0 or
              wantedCscnetsCount > 0:
            1
          else:
            0
        discoveredNodes = await node.discovery.queryRandom(
          node.discoveryForkId,
          wantedAttnets,
          wantedSyncnets,
          wantedCscnets,
          minScore)

      let newPeers = block:
        var np = newSeq[PeerAddr]()
        for discNode in discoveredNodes:
          let res = discNode.toPeerAddr()
          if res.isErr():
            debug "Failed to decode discovery's node address",
                  node = discNode, errMsg = res.error
            continue

          let peerAddr = res.get()
          if node.checkPeer(peerAddr) and
            peerAddr.peerId notin node.connTable:
            np.add(peerAddr)
        np

      let
        roomCurrent = node.hardMaxPeers - len(node.peerPool)
        peersToKick = min(newPeers.len - roomCurrent, node.hardMaxPeers div 5)

      if peersToKick > 0 and newPeers.len > 0:
        node.trimConnections(peersToKick)

      for peerAddr in newPeers:
          # We adding to pending connections table here, but going
          # to remove it only in `connectWorker`.
          node.connTable.incl(peerAddr.peerId)
          await node.connQueue.addLast(peerAddr)

      debug "Discovery tick",
            wanted_peers = node.wantedPeers,
            current_peers = len(node.peerPool),
            discovered_nodes = len(discoveredNodes),
            new_peers = len(newPeers)

      if len(newPeers) == 0:
        let currentPeers = len(node.peerPool)
        if currentPeers <= node.wantedPeers shr 2: #  25%
          warn "Peer count low, no new peers discovered",
            discovered_nodes = len(discoveredNodes), new_peers = newPeers,
            current_peers = currentPeers, wanted_peers = node.wantedPeers

    # Discovery `queryRandom` can have a synchronous fast path for example
    # when no peers are in the routing table. Don't run it in continuous loop.
    #
    # Also, give some time to dial the discovered nodes and update stats etc
    await sleepAsync(5.seconds)

proc fetchNodeIdFromPeerId*(peer: Peer): NodeId=
  # Convert peer id to node id by extracting the peer's public key
  let nodeId =
    block:
      var key: PublicKey
      discard peer.peerId.extractPublicKey(key)
      keys.PublicKey.fromRaw(key.skkey.getBytes()).get().toNodeId()
  nodeId

proc resolvePeer(peer: Peer) =
  # Resolve task which performs searching of peer's public key and recovery of
  # ENR using discovery5. We only resolve ENR for peers we know about to avoid
  # querying the network - as of now, the ENR is not needed, except for
  # debuggging
  logScope: peer = peer.peerId
  let startTime = now(chronos.Moment)
  let nodeId =
    block:
      var key: PublicKey
      # `secp256k1` keys are always stored inside PeerId.
      discard peer.peerId.extractPublicKey(key)
      keys.PublicKey.fromRaw(key.skkey.getBytes()).get().toNodeId()

  debug "Peer's ENR recovery task started", node_id = $nodeId

  # This is "fast-path" for peers which was dialed. In this case discovery
  # already has most recent ENR information about this peer.
  let gnode = peer.network.discovery.getNode(nodeId)
  if gnode.isSome():
    peer.enr = Opt.some(gnode.get().record)
    inc(nbc_successful_discoveries)
    let delay = now(chronos.Moment) - startTime
    nbc_resolve_time.observe(delay.toFloatSeconds())
    debug "Peer's ENR recovered", delay

proc handlePeer*(peer: Peer) {.async: (raises: [CancelledError]).} =
  let res = peer.network.peerPool.addPeerNoWait(peer, peer.direction)
  case res:
  of PeerStatus.LowScoreError, PeerStatus.NoSpaceError:
    # Peer has low score or we do not have enough space in PeerPool,
    # we are going to disconnect it gracefully.
    # Peer' state will be updated in connection event.
    debug "Peer has low score or there no space in PeerPool",
          peer = peer, reason = res
    await peer.disconnect(FaultOrError)
  of PeerStatus.DeadPeerError:
    # Peer's lifetime future is finished, so its already dead,
    # we do not need to perform gracefull disconect.
    # Peer's state will be updated in connection event.
    discard
  of PeerStatus.DuplicateError:
    # Peer is already present in PeerPool, we can't perform disconnect,
    # because in such case we could kill both connections (connection
    # which is present in PeerPool and new one).
    # This is possible bug, because we could enter here only if number
    # of `peer.connections == 1`, it means that Peer's lifetime is not
    # tracked properly and we still not received `Disconnected` event.
    debug "Peer is already present in PeerPool", peer = peer
  of PeerStatus.Success:
    # Peer was added to PeerPool.
    peer.score = NewPeerScore
    peer.connectionState = Connected
    # We spawn task which will obtain ENR for this peer.
    resolvePeer(peer)
    debug "Peer successfully connected", peer = peer,
                                         connections = peer.connections

proc onConnEvent(
    node: Eth2Node, peerId: PeerId, event: ConnEvent) {.
    async: (raises: [CancelledError]).} =
  let peer = node.getPeer(peerId)
  case event.kind
  of ConnEventKind.Connected:
    inc peer.connections
    debug "Peer connection upgraded", peer = $peerId,
                                      connections = peer.connections
    if peer.connections == 1:
      # Libp2p may connect multiple times to the same peer - using different
      # transports for both incoming and outgoing. For now, we'll count our
      # "fist" encounter with the peer as the true connection, leaving the
      # other connections be - libp2p limits the number of concurrent
      # connections to the same peer, and only one of these connections will be
      # active. Nonetheless, this quirk will cause a number of odd behaviours:
      # * For peer limits, we might miscount the incoming vs outgoing quota
      # * Protocol handshakes are wonky: we'll not necessarily use the newly
      #   connected transport - instead we'll just pick a random one!
      case peer.connectionState
      of Disconnecting:
        # We got connection with peer which we currently disconnecting.
        # Normally this does not happen, but if a peer is being disconnected
        # while a concurrent (incoming for example) connection attempt happens,
        # we might end up here
        debug "Got connection attempt from peer that we are disconnecting",
             peer = peerId
        try:
          await node.switch.disconnect(peerId)
        except CancelledError as exc:
          raise exc
        except CatchableError as exc:
          debug "Unexpected error while disconnecting peer", exc = exc.msg
        return
      of None:
        # We have established a connection with the new peer.
        peer.connectionState = Connecting
      of Disconnected:
        # We have established a connection with the peer that we have seen
        # before - reusing the existing peer object is fine
        peer.connectionState = Connecting
        peer.score = 0 # Will be set to NewPeerScore after handshake
      of Connecting, Connected:
        # This means that we got notification event from peer which we already
        # connected or connecting right now. If this situation will happened,
        # it means bug on `nim-libp2p` side.
        warn "Got connection attempt from peer which we already connected",
             peer = peerId
        await peer.disconnect(FaultOrError)
        return

      # Store connection direction inside Peer object.
      if event.incoming:
        peer.direction = PeerType.Incoming
      else:
        peer.direction = PeerType.Outgoing

      await performProtocolHandshakes(peer, event.incoming)

  of ConnEventKind.Disconnected:
    dec peer.connections
    debug "Lost connection to peer", peer = peerId,
                                     connections = peer.connections

    if peer.connections == 0:
      debug "Peer disconnected", peer = $peerId, connections = peer.connections

      # Whatever caused disconnection, avoid connection spamming
      node.addSeen(peerId, SeenTableTimeReconnect)

      let fut = peer.disconnectedFut
      if not(isNil(fut)):
        fut.complete()
        peer.disconnectedFut = nil
      else:
        # TODO (cheatfate): This could be removed when bug will be fixed inside
        # `nim-libp2p`.
        debug "Got new event while peer is already disconnected",
              peer = peerId, peer_state = peer.connectionState
      peer.connectionState = Disconnected

proc new(T: type Eth2Node,
         config: BeaconNodeConf | LightClientConf, runtimeCfg: RuntimeConfig,
         enrForkId: ENRForkID, discoveryForkId: ENRForkID,
         forkDigests: ref ForkDigests, getBeaconTime: GetBeaconTimeFn,
         switch: Switch, pubsub: GossipSub,
         ip: Opt[IpAddress], tcpPort, udpPort: Opt[Port],
         privKey: keys.PrivateKey, discovery: bool,
         directPeers: DirectPeers, announcedAddresses: openArray[MultiAddress],
         rng: ref HmacDrbgContext): T {.raises: [CatchableError].} =
  when not defined(local_testnet):
    let
      connectTimeout = chronos.minutes(1)
      seenThreshold = chronos.minutes(5)
  else:
    let
      connectTimeout = chronos.seconds(10)
      seenThreshold = chronos.seconds(10)
  type MetaData = fulu.MetaData # Weird bug without this..

  # Versions up to v22.3.0 would write an empty `MetaData` to
  #`data-dir/node-metadata.json` which would then be reloaded on startup - don't
  # write a file with this name or downgrades will break!
  const metadata = MetaData()

  let node = T(
    switch: switch,
    pubsub: pubsub,
    wantedPeers: config.maxPeers,
    hardMaxPeers: config.hardMaxPeers.get(config.maxPeers * 3 div 2), #*1.5
    cfg: runtimeCfg,
    peerPool: newPeerPool[Peer, PeerId](),
    # Its important here to create AsyncQueue with limited size, otherwise
    # it could produce HIGH cpu usage.
    connQueue: newAsyncQueue[PeerAddr](ConcurrentConnections),
    metadata: metadata,
    forkId: enrForkId,
    discoveryForkId: discoveryForkId,
    forkDigests: forkDigests,
    getBeaconTime: getBeaconTime,
    discovery: Eth2DiscoveryProtocol.new(
      config, ip, tcpPort, udpPort, privKey,
      {
        enrForkIdField: SSZ.encode(enrForkId),
        enrAttestationSubnetsField: SSZ.encode(metadata.attnets)
      },
    rng),
    discoveryEnabled: discovery,
    rng: rng,
    connectTimeout: connectTimeout,
    seenThreshold: seenThreshold,
    directPeers: directPeers,
    announcedAddresses: @announcedAddresses,
    quota: TokenBucket.new(maxGlobalQuota, fullReplenishTime)
  )

  proc peerHook(peerId: PeerId, event: ConnEvent): Future[void] {.gcsafe.} =
    onConnEvent(node, peerId, event)

  switch.addConnEventHandler(peerHook, ConnEventKind.Connected)
  switch.addConnEventHandler(peerHook, ConnEventKind.Disconnected)

  proc scoreCheck(peer: Peer): bool =
    peer.score >= PeerScoreLowLimit

  proc onDeletePeer(peer: Peer) =
    peer.releasePeer()

  node.peerPool.setScoreCheck(scoreCheck)
  node.peerPool.setOnDeletePeer(onDeletePeer)

  node

proc registerProtocol*(node: Eth2Node, Proto: type, state: Proto.NetworkState) =
  # This convoluted registration process is a leftover from the shared p2p macro
  # and should be refactored
  let proto = Proto.protocolInfo()
  node.protocols.add(proto)
  node.protocolStates.setLen(max(proto.index + 1, node.protocolStates.len))
  node.protocolStates[proto.index] = state

  for msg in proto.messages:
    if msg.protocolMounter != nil:
      msg.protocolMounter node

proc startListening*(node: Eth2Node) {.async.} =
  if node.discoveryEnabled:
    try:
       node.discovery.open()
    except CatchableError as exc:
      fatal "Failed to start discovery service. UDP port may be already in use",
            exc = exc.msg
      quit 1

  try:
    await node.switch.start()
  except CatchableError as exc:
    fatal "Failed to start LibP2P transport. TCP port may be already in use",
          exc = exc.msg
    quit 1

proc peerPingerHeartbeat(node: Eth2Node): Future[void] {.async: (raises: [CancelledError]).}
proc peerTrimmerHeartbeat(node: Eth2Node): Future[void] {.async: (raises: [CancelledError]).}

proc start*(node: Eth2Node) {.async: (raises: [CancelledError]).} =
  proc onPeerCountChanged() =
    trace "Number of peers has been changed", length = len(node.peerPool)
    nbc_peers.set int64(len(node.peerPool))

  node.peerPool.setPeerCounter(onPeerCountChanged)

  for i in 0 ..< ConcurrentConnections:
    node.connWorkers.add connectWorker(node, i)

  if node.discoveryEnabled:
    node.discovery.start()
    traceAsyncErrors node.runDiscoveryLoop()
  else:
    notice "Discovery disabled; trying bootstrap nodes",
      nodes = node.discovery.bootstrapRecords.len
    for enr in node.discovery.bootstrapRecords:
      let pa = TypedRecord.fromRecord(enr).toPeerAddr(tcpProtocol)
      if pa.isOk():
        await node.connQueue.addLast(pa.get())
  node.peerPingerHeartbeatFut = node.peerPingerHeartbeat()
  node.peerTrimmerHeartbeatFut = node.peerTrimmerHeartbeat()

proc stop*(node: Eth2Node) {.async: (raises: [CancelledError]).} =
  # Ignore errors in futures, since we're shutting down (but log them on the
  # TRACE level, if a timeout is reached).
  var waitedFutures =
    @[
        node.switch.stop(),
        node.peerPingerHeartbeat.cancelAndWait(),
        node.peerTrimmerHeartbeatFut.cancelAndWait(),
    ]

  if node.discoveryEnabled:
    waitedFutures &= node.discovery.closeWait()

  let
    timeout = 5.seconds
    completed = await withTimeout(allFutures(waitedFutures), timeout)
  if not completed:
    trace "Eth2Node.stop(): timeout reached", timeout,
      futureErrors = waitedFutures.filterIt(it.error != nil).mapIt(it.error.msg)

proc init(T: type Peer, network: Eth2Node, peerId: PeerId): Peer =
  let res = Peer(
    peerId: peerId,
    network: network,
    connectionState: ConnectionState.None,
    lastReqTime: now(chronos.Moment),
    lastMetadataTime: now(chronos.Moment),
    quota: TokenBucket.new(maxRequestQuota.int, fullReplenishTime)
  )
  res.protocolStates.setLen(network.protocolStates.len())
  for proto in network.protocols:
    if not(isNil(proto.peerStateInitializer)):
      res.protocolStates[proto.index] = proto.peerStateInitializer(res)
  res

func registerMsg(protocol: ProtocolInfo,
                 name: string,
                 mounter: MounterProc,
                 libp2pCodecName: string) =
  protocol.messages.add MessageInfo(name: name,
                                    protocolMounter: mounter,
                                    libp2pCodecName: libp2pCodecName)

proc p2pProtocolBackendImpl*(p: P2PProtocol): Backend =
  var
    Format = ident "SSZ"
    Connection = bindSym "Connection"
    Peer = bindSym "Peer"
    Eth2Node = bindSym "Eth2Node"
    registerMsg = bindSym "registerMsg"
    initProtocol = bindSym "initProtocol"
    msgVar = ident "msg"
    networkVar = ident "network"
    callUserHandler = ident "callUserHandler"
    MSG = ident "MSG"

  new result

  result.PeerType = Peer
  result.NetworkType = Eth2Node
  result.setEventHandlers = bindSym "setEventHandlers"
  result.SerializationFormat = Format
  result.RequestResultsWrapper = ident "NetRes"

  result.implementMsg = proc (msg: eth2_protocol_dsl.Message) =
    if msg.kind == msgResponse:
      return

    let
      protocol = msg.protocol
      msgName = $msg.ident
      msgNameLit = newLit msgName
      MsgRecName = msg.recName
      MsgStrongRecName = msg.strongRecName
      codecNameLit = getRequestProtoName(msg.procDef)
      protocolMounterName = ident(msgName & "Mounter")

    ##
    ## Implement the Thunk:
    ##
    ## The protocol handlers in nim-libp2p receive only a `Connection`
    ## parameter and there is no way to access the wider context (such
    ## as the current `Switch`). In our handlers, we may need to list all
    ## peers in the current network, so we must keep a reference to the
    ## network object in the closure environment of the installed handlers.
    ##
    ## For this reason, we define a `protocol mounter` proc that will
    ## initialize the network object by creating handlers bound to the
    ## specific network.
    ##
    var userHandlerCall = newTree(nnkDiscardStmt)

    if msg.userHandler != nil:
      var OutputParamType = if msg.kind == msgRequest: msg.outputParamType
                            else: nil

      if OutputParamType == nil:
        userHandlerCall = msg.genUserHandlerCall(msgVar, [peerVar])
        if msg.kind == msgRequest:
          userHandlerCall = newCall(ident"sendUserHandlerResultAsChunkImpl",
                                    streamVar,
                                    userHandlerCall)
      else:
        if OutputParamType.kind == nnkVarTy:
          OutputParamType = OutputParamType[0]

        let isChunkStream = eqIdent(OutputParamType[0], "MultipleChunksResponse")
        msg.response.recName = if isChunkStream:
          newTree(nnkBracketExpr, ident"List", OutputParamType[1], OutputParamType[2])
        else:
          OutputParamType[1]

        let responseVar = ident("response")
        userHandlerCall = newStmtList(
          newVarStmt(responseVar,
                     newCall(ident"init", OutputParamType,
                                          peerVar, streamVar)),
          msg.genUserHandlerCall(msgVar, [peerVar], outputParam = responseVar))

    protocol.outRecvProcs.add quote do:
      template `callUserHandler`(`MSG`: type `MsgStrongRecName`,
                                 `peerVar`: `Peer`,
                                 `streamVar`: `Connection`,
                                 `msgVar`: `MsgRecName`): untyped =
        `userHandlerCall`

      proc `protocolMounterName`(`networkVar`: `Eth2Node`) {.raises: [].} =
        proc snappyThunk(`streamVar`: `Connection`,
                         `protocolVar`: string): Future[void] {.gcsafe.} =
          return handleIncomingStream(`networkVar`, `streamVar`, `protocolVar`,
                                      `MsgStrongRecName`)

        try:
          mount `networkVar`.switch,
                LPProtocol.new(
                  codecs = @[`codecNameLit`], handler = snappyThunk)
        except LPError as exc:
          # Failure here indicates that the mounting was done incorrectly which
          # would be a programming error
          raiseAssert exc.msg
    ##
    ## Implement Senders and Handshake
    ##

    var sendProc = msg.createSendProc()
    implementSendProcBody sendProc

    protocol.outProcRegistrations.add(
      newCall(registerMsg,
              protocol.protocolInfoVar,
              msgNameLit,
              protocolMounterName,
              codecNameLit))

  result.implementProtocolInit = proc (p: P2PProtocol): NimNode =
    # This `macrocache` counter gives each protocol its own integer index which
    # is later used to index per-protocol, per-instace data kept in the peer and
    # network - the counter is global across all modules / protocols of the
    # application
    let
      id = CacheCounter"eth2_network_protocol_id"
      tmp = id.value
    id.inc(1)

    newCall(initProtocol, newLit(p.name), p.peerInit, p.netInit, newLit(tmp))

#Must import here because of cyclicity
import ./peer_protocol
export peer_protocol

func updateMetadataV2ToV3(metadataRes: NetRes[altair.MetaData]):
                          NetRes[fulu.MetaData] =
  if metadataRes.isOk:
    let metadata = metadataRes.get
    ok(fulu.MetaData(seq_number: metadata.seq_number,
                     attnets: metadata.attnets,
                     syncnets: metadata.syncnets))
  else:
    err(metadataRes.error)

proc getMetadata_vx(node: Eth2Node, peer: Peer):
                    Future[NetRes[fulu.MetaData]]
                   {.async: (raises: [CancelledError]).} =
  let
    res =
      if node.getBeaconTime().slotOrZero.epoch >= node.cfg.FULU_FORK_EPOCH:
        # Directly fetch fulu metadata if available
        await getMetadata_v3(peer)
      else:
        updateMetadataV2ToV3(await getMetadata_v2(peer))
  return res

proc updatePeerMetadata(node: Eth2Node, peerId: PeerId) {.async: (raises: [CancelledError]).} =
  trace "updating peer metadata", peerId
  let
    peer = node.getPeer(peerId)
    newMetadataRes = await node.getMetadata_vx(peer)
    newMetadata = newMetadataRes.valueOr:
      debug "Failed to retrieve metadata from peer!", peerId, error = newMetadataRes.error
      peer.failedMetadataRequests.inc()
      return

  peer.metadata = Opt.some(newMetadata)
  peer.failedMetadataRequests = 0
  peer.lastMetadataTime = Moment.now()

const
  # For Phase0, metadata change every +27 hours
  MetadataRequestFrequency = 30.minutes
  MetadataRequestMaxFailures = 3

proc peerPingerHeartbeat(node: Eth2Node) {.async: (raises: [CancelledError]).} =
  while true:
    let heartbeatStart_m = Moment.now()
    var updateFutures: seq[Future[void]]

    for peer in node.peers.values:
      if peer.connectionState != Connected: continue

      if peer.metadata.isNone or
          heartbeatStart_m - peer.lastMetadataTime > MetadataRequestFrequency:
        updateFutures.add(node.updatePeerMetadata(peer.peerId))

    await allFutures(updateFutures)

    reset(updateFutures)

    for peer in node.peers.values:
      if peer.connectionState != Connected: continue

      if peer.failedMetadataRequests > MetadataRequestMaxFailures:
        debug "no metadata from peer, kicking it", peer
        updateFutures.add(peer.disconnect(PeerScoreLow))

    await allFutures(updateFutures)

    await sleepAsync(5.seconds)

proc peerTrimmerHeartbeat(node: Eth2Node) {.async: (raises: [CancelledError]).} =
  # Disconnect peers in excess of the (soft) max peer count
  while true:
    # Only count Connected peers (to avoid counting Disconnecting ones)
    let
      connectedPeers = node.peers.values.countIt(
        it.connectionState == Connected)
      excessPeers = connectedPeers - node.wantedPeers

    if excessPeers > 0:
      # Let chronos take back control every trimming
      node.trimConnections(1)

    await sleepAsync(1.seconds div max(1, excessPeers))

func asEthKey*(key: PrivateKey): keys.PrivateKey =
  keys.PrivateKey(key.skkey)

template tcpEndPoint(address, port): auto =
  MultiAddress.init(address, tcpProtocol, port)

func initNetKeys(privKey: PrivateKey): NetKeyPair =
  let pubKey = privKey.getPublicKey().expect("working public key from random")
  NetKeyPair(seckey: privKey, pubkey: pubKey)

proc getRandomNetKeys*(rng: var HmacDrbgContext): NetKeyPair =
  let privKey = PrivateKey.random(Secp256k1, rng).valueOr:
    fatal "Could not generate random network key file"
    quit QuitFailure
  initNetKeys(privKey)

proc getPersistentNetKeys*(
    rng: var HmacDrbgContext,
    dataDir, netKeyFile: string,
    netKeyInsecurePassword: bool,
    allowLoadExisting: bool): NetKeyPair =
  if netKeyFile == "random":
    let
      keys = rng.getRandomNetKeys()
      pres = PeerId.init(keys.pubkey).valueOr:
        fatal "Could not obtain PeerId from network key", error
        quit QuitFailure
    info "Generating new networking key",
      network_public_key = keys.pubkey, network_peer_id = $pres
    keys
  else:
    let
      # Insecure password used only for automated testing.
      insecurePassword =
        if netKeyInsecurePassword:
          Opt.some(NetworkInsecureKeyPassword)
        else:
          Opt.none(string)

      keyPath =
        if isAbsolute(netKeyFile):
          netKeyFile
        else:
          dataDir / netKeyFile
    logScope: key_path = keyPath

    if fileAccessible(keyPath, {AccessFlags.Find}) and allowLoadExisting:
      info "Network key storage is present, unlocking"

      let
        privKey = loadNetKeystore(keyPath, insecurePassword).valueOr:
          fatal "Could not load network key file"
          quit QuitFailure
        keys = initNetKeys(privKey)
      info "Network key storage was successfully unlocked",
        network_public_key = keys.pubkey
      keys
    else:
      if allowLoadExisting:
        info "Network key storage is missing, creating a new one",
            key_path = keyPath
      let
        keys = rng.getRandomNetKeys()
        sres = saveNetKeystore(rng, keyPath, keys.seckey, insecurePassword)
      if sres.isErr():
        fatal "Could not create network key file"
        quit QuitFailure

      info "New network key storage was created",
        network_public_key = keys.pubkey
      keys

proc getPersistentNetKeys*(
    rng: var HmacDrbgContext, config: BeaconNodeConf): NetKeyPair =
  case config.cmd
  of BNStartUpCmd.noCommand, BNStartUpCmd.record:
    rng.getPersistentNetKeys(
      string(config.dataDir), config.netKeyFile, config.netKeyInsecurePassword,
      allowLoadExisting = true)
  else:
    rng.getRandomNetKeys()

func gossipId(
    data: openArray[byte], phase0Prefix, topic: string): seq[byte] =
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/p2p-interface.md#topics-and-messages
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.9/specs/altair/p2p-interface.md#topics-and-messages
  const MESSAGE_DOMAIN_VALID_SNAPPY = [0x01'u8, 0x00, 0x00, 0x00]
  let messageDigest = withEth2Hash:
    h.update(MESSAGE_DOMAIN_VALID_SNAPPY)

    if not topic.startsWith(phase0Prefix):
      # everything >= altair
      h.update topic.len.uint64.toBytesLE
      h.update topic

    h.update data

  messageDigest.data[0..19]

proc newBeaconSwitch(config: BeaconNodeConf | LightClientConf,
                     seckey: PrivateKey, address: MultiAddress,
                     rng: ref HmacDrbgContext): Switch {.raises: [CatchableError].} =
  let service: Service = WildcardAddressResolverService.new()

  var sb = SwitchBuilder.new()
  # Order of multiplexers matters, the first will be default

  sb
    .withPrivateKey(seckey)
    .withAddress(address)
    .withRng(rng)
    .withNoise()
    .withMplex(chronos.minutes(5), chronos.minutes(5))
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withTcpTransport({ServerFlags.ReuseAddr})
    .withServices(@[service])
    .build()

proc createEth2Node*(rng: ref HmacDrbgContext,
                     config: BeaconNodeConf | LightClientConf,
                     netKeys: NetKeyPair,
                     cfg: RuntimeConfig,
                     forkDigests: ref ForkDigests,
                     getBeaconTime: GetBeaconTimeFn,
                     genesis_validators_root: Eth2Digest): Eth2Node
                    {.raises: [CatchableError].} =
  let
    enrForkId = getENRForkID(
      cfg, getBeaconTime().slotOrZero.epoch, genesis_validators_root)

    discoveryForkId = getDiscoveryForkID(
      cfg, getBeaconTime().slotOrZero.epoch, genesis_validators_root)

    listenAddress =
      if config.listenAddress.isSome():
        config.listenAddress.get()
      else:
        getAutoAddress(Port(0)).toIpAddress()

    (extIp, extTcpPort, extUdpPort) =
      setupAddress(config.nat, listenAddress, config.tcpPort,
                   config.udpPort, clientId)

    directPeers = block:
      var res: DirectPeers
      for s in config.directPeers:
        let (peerId, address) =
          if s.startsWith("enr:"):
            let
              enr = parseBootstrapAddress(s).valueOr:
                fatal "Failed to parse bootstrap address", enr=s
                quit 1
              typedEnr = TypedRecord.fromRecord(enr)
              peerAddress = toPeerAddr(typedEnr, tcpProtocol).get()
            (peerAddress.peerId, peerAddress.addrs[0])
          elif s.startsWith("/"):
            parseFullAddress(s).tryGet()
          else:
            fatal "direct peers address should start with / (multiaddress) or enr:", conf=s
            quit 1
        res.mgetOrPut(peerId, @[]).add(address)
        info "Adding privileged direct peer", peerId, address
      res

    hostAddress = tcpEndPoint(listenAddress, config.tcpPort)
    announcedAddresses =
      if extIp.isNone() or extTcpPort.isNone(): @[]
      else: @[tcpEndPoint(extIp.get(), extTcpPort.get())]

  debug "Initializing networking", hostAddress,
                                   network_public_key = netKeys.pubkey,
                                   announcedAddresses

  # TODO nim-libp2p still doesn't have support for announcing addresses
  # that are different from the host address (this is relevant when we
  # are running behind a NAT).
  var switch = newBeaconSwitch(config, netKeys.seckey, hostAddress, rng)

  let phase0Prefix = "/eth2/" & $forkDigests.phase0

  func msgIdProvider(m: messages.Message): Result[seq[byte], ValidationResult] =
    try:
      # This doesn't have to be a tight bound, just enough to avoid denial of
      # service attacks.
      let decoded = snappy.decode(m.data, static(GOSSIP_MAX_SIZE.uint32))
      ok(gossipId(decoded, phase0Prefix, m.topic))
    except CatchableError:
      err(ValidationResult.Reject)

  let
    params = GossipSubParams.init(
      pruneBackoff = chronos.minutes(1),
      unsubscribeBackoff = chronos.seconds(10),
      floodPublish = true,
      gossipFactor = 0.05,
      d = 8,
      dLow = 6,
      dHigh = 12,
      dScore = 6,
      dOut = 6 div 2, # less than dlow and no more than dlow/2
      dLazy = 6,
      heartbeatInterval = chronos.milliseconds(700),
      historyLength = 6,
      historyGossip = 3,
      fanoutTTL = chronos.seconds(60),
      # 2 epochs matching maximum valid attestation lifetime
      seenTTL = chronos.seconds(int(SECONDS_PER_SLOT * SLOTS_PER_EPOCH * 2)),
      gossipThreshold = -4000,
      publishThreshold = -8000,
      graylistThreshold = -16000, # also disconnect threshold
      opportunisticGraftThreshold = 0,
      decayInterval = chronos.seconds(12),
      decayToZero = 0.01,
      retainScore = chronos.seconds(385),
      appSpecificWeight = 0.0,
      ipColocationFactorWeight = -53.75,
      ipColocationFactorThreshold = 3.0,
      behaviourPenaltyWeight = -15.9,
      behaviourPenaltyDecay = 0.986,
      disconnectBadPeers = true,
      directPeers = directPeers,
      bandwidthEstimatebps = config.bandwidthEstimate.get(100_000_000)
    )
    pubsub = GossipSub.init(
      switch = switch,
      msgIdProvider = msgIdProvider,
      # We process messages in the validator, so we don't need data callbacks
      triggerSelf = false,
      sign = false,
      verifySignature = false,
      anonymize = true,
      maxMessageSize = static(GOSSIP_MAX_SIZE.int),
      parameters = params)

  switch.mount(pubsub)

  let node = Eth2Node.new(
    config, cfg, enrForkId, discoveryForkId, forkDigests, getBeaconTime, switch, pubsub, extIp,
    extTcpPort, extUdpPort, netKeys.seckey.asEthKey,
    discovery = config.discv5Enabled, directPeers, announcedAddresses,
    rng = rng)

  node.pubsub.subscriptionValidator =
    proc(topic: string): bool {.gcsafe, raises: [].} =
      topic in node.validTopics

  node

func announcedENR*(node: Eth2Node): enr.Record =
  doAssert node.discovery != nil, "The Eth2Node must be initialized"
  node.discovery.localNode.record

proc lookupCscFromPeer*(peer: Peer): uint64 =
  # Fetches the custody column count from a remote peer.
  # If the peer advertises their custody column count via the `csc` ENR field,
  # that value is returned. Otherwise, the default value `CUSTODY_REQUIREMENT`
  # is assumed.

  let metadata = peer.metadata
  if metadata.isOk:
    return metadata.get.custody_subnet_count

  # Try getting the custody count from ENR if metadata fetch fails.
  debug "Could not get csc from metadata, trying from ENR",
        peer_id = peer.peerId
  let enrOpt = peer.enr
  if not enrOpt.isNone:
    let enr = enrOpt.get
    let enrFieldOpt = enr.get(enrCustodySubnetCountField, seq[byte])
    if enrFieldOpt.isOk:
      try:
        let csc = SSZ.decode(enrFieldOpt.get, uint8)
        return csc.uint64
      except SszError, SerializationError:
        discard  # Ignore decoding errors and fallback to default

  # Return default value if no valid custody subnet count is found.
  return CUSTODY_REQUIREMENT.uint64

func shortForm*(id: NetKeyPair): string =
  $PeerId.init(id.pubkey)

proc subscribe*(
    node: Eth2Node, topic: string, topicParams: TopicParams,
    enableTopicMetrics: bool = false) =
  if enableTopicMetrics:
    node.pubsub.knownTopics.incl(topic)

  node.pubsub.topicParams[topic] = topicParams

  # Passing in `nil` because we do all message processing in the validator
  node.pubsub.subscribe(topic, nil)

proc newValidationResultFuture(v: ValidationResult): Future[ValidationResult]
    {.async: (raises: [CancelledError], raw: true).} =
  let res = newFuture[ValidationResult]("eth2_network.execValidator")
  res.complete(v)
  res

func addValidator*[MsgType](node: Eth2Node,
                            topic: string,
                            msgValidator: proc(msg: MsgType):
                            ValidationResult {.gcsafe, raises: [].} ) =
  # Message validators run when subscriptions are enabled - they validate the
  # data and return an indication of whether the message should be broadcast
  # or not - validation is `async` but implemented without the macro because
  # this is a performance hotspot.
  proc execValidator(topic: string, message: GossipMsg):
      Future[ValidationResult] {.raises: [].} =
    inc nbc_gossip_messages_received
    trace "Validating incoming gossip message", len = message.data.len, topic

    var decompressed = snappy.decode(message.data, gossipMaxSize(MsgType))
    let res = if decompressed.len > 0:
      try:
        let decoded = SSZ.decode(decompressed, MsgType)
        decompressed = newSeq[byte](0) # release memory before validating
        msgValidator(decoded) # doesn't raise!
      except SerializationError as e:
        inc nbc_gossip_failed_ssz
        debug "Error decoding gossip",
          topic, len = message.data.len, decompressed = decompressed.len,
          error = e.msg
        ValidationResult.Reject
    else: # snappy returns empty seq on failed decompression
      inc nbc_gossip_failed_snappy
      debug "Error decompressing gossip", topic, len = message.data.len
      ValidationResult.Reject

    newValidationResultFuture(res)

  node.validTopics.incl topic # Only allow subscription to validated topics
  node.pubsub.addValidator(topic, execValidator)

proc addAsyncValidator*[MsgType](node: Eth2Node,
                            topic: string,
                            msgValidator: proc(msg: MsgType):
                            Future[ValidationResult] {.async: (raises: [CancelledError]).} ) =
  proc execValidator(topic: string, message: GossipMsg):
      Future[ValidationResult] {.async: (raw: true).} =
    inc nbc_gossip_messages_received
    trace "Validating incoming gossip message", len = message.data.len, topic

    var decompressed = snappy.decode(message.data, gossipMaxSize(MsgType))
    if decompressed.len > 0:
      try:
        let decoded = SSZ.decode(decompressed, MsgType)
        decompressed = newSeq[byte](0) # release memory before validating
        msgValidator(decoded) # doesn't raise!
      except SerializationError as e:
        inc nbc_gossip_failed_ssz
        debug "Error decoding gossip",
          topic, len = message.data.len, decompressed = decompressed.len,
          error = e.msg
        newValidationResultFuture(ValidationResult.Reject)
    else: # snappy returns empty seq on failed decompression
      inc nbc_gossip_failed_snappy
      debug "Error decompressing gossip", topic, len = message.data.len
      newValidationResultFuture(ValidationResult.Reject)

  node.validTopics.incl topic # Only allow subscription to validated topics

  node.pubsub.addValidator(topic, execValidator)

proc unsubscribe*(node: Eth2Node, topic: string) =
  node.pubsub.unsubscribeAll(topic)

func gossipEncode(msg: auto): seq[byte] =
  let uncompressed = SSZ.encode(msg)
  # This function only for messages we create. A message this large amounts to
  # an internal logic error.
  doAssert uncompressed.lenu64 <= GOSSIP_MAX_SIZE

  snappy.encode(uncompressed)

proc broadcast(node: Eth2Node, topic: string, msg: seq[byte]):
    Future[SendResult] {.async: (raises: [CancelledError]).} =
  let peers =
    try:
      await node.pubsub.publish(topic, msg)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Unexpected error during broadcast", exc = exc.msg
      return err("Broadcast failed")

  # TODO remove workaround for sync committee BN/VC log spam
  if peers > 0 or find(topic, "sync_committee_") != -1:
    inc nbc_gossip_messages_sent
    ok()
  else:
    # Increments libp2p_gossipsub_failed_publish metric
    err("No peers on libp2p topic")

proc broadcast(node: Eth2Node, topic: string, msg: auto):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  # Avoid {.async.} copies of message while broadcasting
  broadcast(node, topic, gossipEncode(msg))

proc subscribeAttestationSubnets*(
    node: Eth2Node, subnets: AttnetBits, forkDigest: ForkDigest) =
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/p2p-interface.md#attestations-and-aggregation
  # Nimbus won't score attestation subnets for now, we just rely on block and
  # aggregate which are more stable and reliable

  for subnet_id, enabled in subnets:
    if enabled:
      node.subscribe(getAttestationTopic(
        forkDigest, SubnetId(subnet_id)), TopicParams.init()) # don't score attestation subnets for now

proc unsubscribeAttestationSubnets*(
    node: Eth2Node, subnets: AttnetBits, forkDigest: ForkDigest) =
  # https://github.com/ethereum/consensus-specs/blob/v1.4.0/specs/phase0/p2p-interface.md#attestations-and-aggregation
  # Nimbus won't score attestation subnets for now; we just rely on block and
  # aggregate which are more stable and reliable

  for subnet_id, enabled in subnets:
    if enabled:
      node.unsubscribe(getAttestationTopic(forkDigest, SubnetId(subnet_id)))

proc updateStabilitySubnetMetadata*(node: Eth2Node, attnets: AttnetBits) =
  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.5/specs/phase0/p2p-interface.md#metadata
  if node.metadata.attnets == attnets:
    return

  node.metadata.seq_number += 1
  node.metadata.attnets = attnets

  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/p2p-interface.md#attestation-subnet-subscription
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.8/specs/phase0/p2p-interface.md#attestation-subnet-bitfield
  let res = node.discovery.updateRecord({
    enrAttestationSubnetsField: SSZ.encode(node.metadata.attnets)
  })
  if res.isErr():
    # This should not occur in this scenario as the private key would always
    # be the correct one and the ENR will not increase in size.
    warn "Failed to update the ENR attnets field", error = res.error
  else:
    debug "Stability subnets changed; updated ENR attnets", attnets

proc loadCscnetMetadataAndEnr*(node: Eth2Node, cscnets: CscCount) =
  node.metadata.custody_subnet_count = cscnets.uint64
  let res =
    node.discovery.updateRecord({
      enrCustodySubnetCountField: SSZ.encode(cscnets)
    })

  if res.isErr:
    # This should not occur in this scenario as the private key would always
    # be the correct one and the ENR will not increase in size
    warn "Failed to update the ENR csc field", error = res.error
  else:
    debug "Updated ENR csc", cscnets

proc updateSyncnetsMetadata*(node: Eth2Node, syncnets: SyncnetBits) =
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.10/specs/altair/validator.md#sync-committee-subnet-stability
  if node.metadata.syncnets == syncnets:
    return

  node.metadata.seq_number += 1
  node.metadata.syncnets = syncnets

  let res = node.discovery.updateRecord({
    enrSyncSubnetsField: SSZ.encode(node.metadata.syncnets)
  })
  if res.isErr():
    # This should not occur in this scenario as the private key would always
    # be the correct one and the ENR will not increase in size.
    warn "Failed to update the ENR syncnets field", error = res.error
  else:
    debug "Sync committees changed; updated ENR syncnets", syncnets

proc updateForkId(node: Eth2Node, value: ENRForkID) =
  node.forkId = value
  let res = node.discovery.updateRecord({enrForkIdField: SSZ.encode value})
  if res.isErr():
    # This should not occur in this scenario as the private key would always
    # be the correct one and the ENR will not increase in size.
    warn "Failed to update the ENR fork id", value, error = res.error
  else:
    debug "ENR fork id changed", value

proc updateForkId*(node: Eth2Node, epoch: Epoch, genesis_validators_root: Eth2Digest) =
  node.updateForkId(getENRForkID(node.cfg, epoch, genesis_validators_root))
  node.discoveryForkId = getDiscoveryForkID(node.cfg, epoch, genesis_validators_root)

func forkDigestAtEpoch*(node: Eth2Node, epoch: Epoch): ForkDigest =
  node.forkDigests[].atEpoch(epoch, node.cfg)

proc getWallEpoch(node: Eth2Node): Epoch =
  node.getBeaconTime().slotOrZero.epoch

proc broadcastAttestation*(
    node: Eth2Node, subnet_id: SubnetId,
    attestation: phase0.Attestation | electra.Attestation):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  # Regardless of the contents of the attestation,
  # https://github.com/ethereum/consensus-specs/blob/v1.5.0-alpha.9/specs/altair/p2p-interface.md#transitioning-the-gossip
  # implies that pre-fork, messages using post-fork digests might be
  # ignored, whilst post-fork, there is effectively a seen_ttl-based
  # timer unsubscription point that means no new pre-fork-forkdigest
  # should be sent.
  let
    forkPrefix = node.forkDigestAtEpoch(node.getWallEpoch)
    topic = getAttestationTopic(forkPrefix, subnet_id)
  node.broadcast(topic, attestation)

proc broadcastVoluntaryExit*(
    node: Eth2Node, exit: SignedVoluntaryExit):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getVoluntaryExitsTopic(node.forkDigestAtEpoch(node.getWallEpoch))
  node.broadcast(topic, exit)

proc broadcastAttesterSlashing*(
    node: Eth2Node,
    slashing: phase0.AttesterSlashing | electra.AttesterSlashing):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getAttesterSlashingsTopic(
    node.forkDigestAtEpoch(node.getWallEpoch))
  node.broadcast(topic, slashing)

proc broadcastProposerSlashing*(
    node: Eth2Node, slashing: ProposerSlashing):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getProposerSlashingsTopic(
    node.forkDigestAtEpoch(node.getWallEpoch))
  node.broadcast(topic, slashing)

proc broadcastBlsToExecutionChange*(
    node: Eth2Node, bls_to_execution_change: SignedBLSToExecutionChange):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBlsToExecutionChangeTopic(
    node.forkDigestAtEpoch(node.getWallEpoch))
  node.broadcast(topic, bls_to_execution_change)

proc broadcastAggregateAndProof*(
    node: Eth2Node,
    proof: phase0.SignedAggregateAndProof | electra.SignedAggregateAndProof):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getAggregateAndProofsTopic(
    node.forkDigestAtEpoch(node.getWallEpoch))
  node.broadcast(topic, proof)

proc broadcastBeaconBlock*(
    node: Eth2Node, blck: phase0.SignedBeaconBlock):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBeaconBlocksTopic(node.forkDigests.phase0)
  node.broadcast(topic, blck)

proc broadcastBeaconBlock*(
    node: Eth2Node, blck: altair.SignedBeaconBlock):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBeaconBlocksTopic(node.forkDigests.altair)
  node.broadcast(topic, blck)

proc broadcastBeaconBlock*(
    node: Eth2Node, blck: bellatrix.SignedBeaconBlock):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBeaconBlocksTopic(node.forkDigests.bellatrix)
  node.broadcast(topic, blck)

proc broadcastBeaconBlock*(
    node: Eth2Node, blck: capella.SignedBeaconBlock):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBeaconBlocksTopic(node.forkDigests.capella)
  node.broadcast(topic, blck)

proc broadcastBeaconBlock*(
    node: Eth2Node, blck: deneb.SignedBeaconBlock):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBeaconBlocksTopic(node.forkDigests.deneb)
  node.broadcast(topic, blck)

proc broadcastBeaconBlock*(
    node: Eth2Node, blck: electra.SignedBeaconBlock):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBeaconBlocksTopic(node.forkDigests.electra)
  node.broadcast(topic, blck)

proc broadcastBeaconBlock*(
    node: Eth2Node, blck: fulu.SignedBeaconBlock):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getBeaconBlocksTopic(node.forkDigests.fulu)
  node.broadcast(topic, blck)

proc broadcastBlobSidecar*(
    node: Eth2Node, subnet_id: BlobId, blob: deneb.BlobSidecar):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let
    contextEpoch = blob.signed_block_header.message.slot.epoch
    topic = getBlobSidecarTopic(
      node.forkDigestAtEpoch(contextEpoch), subnet_id)
  node.broadcast(topic, blob)

proc broadcastSyncCommitteeMessage*(
    node: Eth2Node, msg: SyncCommitteeMessage,
    subcommitteeIdx: SyncSubcommitteeIndex):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let
    contextEpoch = msg.slot.epoch
    topic = getSyncCommitteeTopic(
      node.forkDigestAtEpoch(contextEpoch), subcommitteeIdx)
  node.broadcast(topic, msg)

proc broadcastSignedContributionAndProof*(
    node: Eth2Node, msg: SignedContributionAndProof):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let
    contextEpoch = msg.message.contribution.slot.epoch
    topic = getSyncCommitteeContributionAndProofTopic(
      node.forkDigestAtEpoch(contextEpoch))
  node.broadcast(topic, msg)

proc broadcastLightClientFinalityUpdate*(
    node: Eth2Node, msg: ForkyLightClientFinalityUpdate):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getLightClientFinalityUpdateTopic(
    node.forkDigestAtEpoch(msg.contextEpoch))
  node.broadcast(topic, msg)

proc broadcastLightClientOptimisticUpdate*(
    node: Eth2Node, msg: ForkyLightClientOptimisticUpdate):
    Future[SendResult] {.async: (raises: [CancelledError], raw: true).} =
  let topic = getLightClientOptimisticUpdateTopic(
    node.forkDigestAtEpoch(msg.contextEpoch))
  node.broadcast(topic, msg)
