# beacon_chain
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  chronicles, chronos, stew/io2,
  eth/db/kvstore_sqlite3,
  ./el/el_manager,
  ./gossip_processing/optimistic_processor,
  ./networking/[topic_params, network_metadata_downloads],
  ./spec/beaconstate,
  ./spec/datatypes/[phase0, altair, bellatrix, capella, deneb],
  "."/[filepath, light_client, light_client_db, nimbus_binary_common, version]

from ./gossip_processing/block_processor import newExecutionPayload
from ./gossip_processing/eth2_processor import toValidationResult

# this needs to be global, so it can be set in the Ctrl+C signal handler
var globalRunning = true

programMain:
  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      try:
        setupForeignThreadGc()
      except Exception as exc: raiseAssert exc.msg # shouldn't happen
    notice "Shutting down after having received SIGINT"
    globalRunning = false
  try:
    setControlCHook(controlCHandler)
  except Exception as exc: # TODO Exception
    warn "Cannot set ctrl-c handler", msg = exc.msg

  var config = makeBannerAndConfig(
    "Nimbus light client " & fullVersionStr, LightClientConf)
  setupLogging(config.logLevel, config.logStdout, config.logFile)

  notice "Launching light client",
    version = fullVersionStr, cmdParams = commandLineParams(), config

  let dbDir = config.databaseDir
  if (let res = secureCreatePath(dbDir); res.isErr):
    fatal "Failed to create create database directory",
      path = dbDir, err = ioErrorMsg(res.error)
    quit 1
  let backend = SqStoreRef.init(dbDir, "nlc").expect("Database OK")
  defer: backend.close()
  let db = backend.initLightClientDB(LightClientDBNames(
    legacyAltairHeaders: "altair_lc_headers",
    headers: "lc_headers",
    altairSyncCommittees: "altair_sync_committees")).expect("Database OK")
  defer: db.close()

  let metadata = loadEth2Network(config.eth2Network)
  for node in metadata.bootstrapNodes:
    config.bootstrapNodes.add node
  template cfg(): auto = metadata.cfg

  let
    genesisBytes = try: waitFor metadata.fetchGenesisBytes()
                   except CatchableError as err:
                     error "Failed to obtain genesis state",
                            source = metadata.genesis.sourceDesc,
                            err = err.msg
                     quit 1
    genesisState =
      try:
        newClone(readSszForkedHashedBeaconState(cfg, genesisBytes))
      except CatchableError as err:
        raiseAssert "Invalid baked-in state: " & err.msg

    genesisTime = getStateField(genesisState[], genesis_time)
    beaconClock = BeaconClock.init(genesisTime).valueOr:
      error "Invalid genesis time in state", genesisTime
      quit 1
    getBeaconTime = beaconClock.getBeaconTimeFn()

    genesis_validators_root =
      getStateField(genesisState[], genesis_validators_root)
    forkDigests = newClone ForkDigests.init(cfg, genesis_validators_root)

    genesisBlockRoot = get_initial_beacon_block(genesisState[]).root

    rng = HmacDrbgContext.new()
    netKeys = getRandomNetKeys(rng[])
    network = createEth2Node(
      rng, config, netKeys, cfg,
      forkDigests, getBeaconTime, genesis_validators_root)
    engineApiUrls = config.engineApiUrls
    elManager =
      if engineApiUrls.len > 0:
        ELManager.new(
          cfg,
          metadata.depositContractBlock,
          metadata.depositContractBlockHash,
          db = nil,
          engineApiUrls,
          metadata.eth1Network)
      else:
        nil

    optimisticHandler = proc(
        signedBlock: ForkedSignedBeaconBlock
    ): Future[void] {.async: (raises: [CancelledError]).} =
      withBlck(signedBlock):
        when consensusFork >= ConsensusFork.Bellatrix:
          if forkyBlck.message.is_execution_block:
            template payload(): auto = forkyBlck.message.body.execution_payload
            if elManager != nil and not payload.block_hash.isZero:
              discard await elManager.newExecutionPayload(forkyBlck.message)
        else: discard
    optimisticProcessor = initOptimisticProcessor(
      getBeaconTime, optimisticHandler)

    lightClient = createLightClient(
      network, rng, config, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Optimistic)

  # Run `exchangeTransitionConfiguration` loop
  if elManager != nil:
    elManager.start(syncChain = false)

  info "Listening to incoming network requests"
  network.registerProtocol(
    PeerSync, PeerSync.NetworkState.init(
      cfg, forkDigests, genesisBlockRoot, getBeaconTime))

  withAll(ConsensusFork):
    let forkDigest = forkDigests[].atConsensusFork(consensusFork)
    network.addValidator(
      getBeaconBlocksTopic(forkDigest), proc (
          signedBlock: consensusFork.SignedBeaconBlock
      ): ValidationResult =
        toValidationResult(
          optimisticProcessor.processSignedBeaconBlock(signedBlock)))
  lightClient.installMessageValidators()
  waitFor network.startListening()
  waitFor network.start()

  func isSynced(optimisticSlot: Slot, wallSlot: Slot): bool =
    # Check whether light client has synced sufficiently close to wall slot
    const maxAge = 2 * SLOTS_PER_EPOCH
    optimisticSlot >= max(wallSlot, maxAge.Slot) - maxAge

  proc onFinalizedHeader(
      lightClient: LightClient, finalizedHeader: ForkedLightClientHeader) =
    withForkyHeader(finalizedHeader):
      when lcDataFork > LightClientDataFork.None:
        info "New LC finalized header",
          finalized_header = shortLog(forkyHeader)
        let
          period = forkyHeader.beacon.slot.sync_committee_period
          syncCommittee = lightClient.finalizedSyncCommittee.expect("Init OK")
        db.putSyncCommittee(period, syncCommittee)
        db.putLatestFinalizedHeader(finalizedHeader)

  var optimisticFcuFut: Future[(PayloadExecutionStatus, Opt[BlockHash])]
    .Raising([CancelledError])
  proc onOptimisticHeader(
      lightClient: LightClient, optimisticHeader: ForkedLightClientHeader) =
    if optimisticFcuFut != nil:
      return
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        logScope: optimistic_header = shortLog(forkyHeader)
        when lcDataFork >= LightClientDataFork.Capella:
          let
            bid = forkyHeader.beacon.toBlockId()
            consensusFork = cfg.consensusForkAtEpoch(bid.slot.epoch)
            blockHash = forkyHeader.execution.block_hash

          info "New LC optimistic header"
          if elManager == nil or blockHash.isZero or
              not isSynced(bid.slot, getBeaconTime().slotOrZero()):
            return

          withConsensusFork(consensusFork):
            when lcDataForkAtConsensusFork(consensusFork) == lcDataFork:
              optimisticFcuFut = elManager.forkchoiceUpdated(
                headBlockHash = blockHash,
                safeBlockHash = blockHash,  # stub value
                finalizedBlockHash = ZERO_HASH,
                payloadAttributes = Opt.none(consensusFork.PayloadAttributes))
              optimisticFcuFut.addCallback do (future: pointer):
                optimisticFcuFut = nil
        else:
          info "Ignoring new LC optimistic header until Capella"

  lightClient.onFinalizedHeader = onFinalizedHeader
  lightClient.onOptimisticHeader = onOptimisticHeader
  lightClient.trustedBlockRoot = some config.trustedBlockRoot

  let latestHeader = db.getLatestFinalizedHeader()
  withForkyHeader(latestHeader):
    when lcDataFork > LightClientDataFork.None:
      let
        period = forkyHeader.beacon.slot.sync_committee_period
        syncCommittee = db.getSyncCommittee(period)
      if syncCommittee.isErr:
        error "LC store lacks sync committee", finalized_header = forkyHeader
      else:
        lightClient.resetToFinalizedHeader(latestHeader, syncCommittee.get)

  # Full blocks gossip is required to portably drive an EL client:
  # - EL clients may not sync when only driven with `forkChoiceUpdated`,
  #   e.g., Geth: "Forkchoice requested unknown head"
  # - `newPayload` requires the full `ExecutionPayload` (most of block content)
  # - `ExecutionPayload` block hash is not available in
  #   `altair.LightClientHeader`, so won't be exchanged via light client gossip
  #
  # Future `ethereum/consensus-specs` versions may remove need for full blocks.
  # Therefore, this current mechanism is to be seen as temporary; it is not
  # optimized for reducing code duplication, e.g., with `nimbus_beacon_node`.

  func isSynced(wallSlot: Slot): bool =
    let optimisticHeader = lightClient.optimisticHeader
    withForkyHeader(optimisticHeader):
      when lcDataFork > LightClientDataFork.None:
        isSynced(forkyHeader.beacon.slot, wallSlot)
      else:
        false

  func shouldSyncOptimistically(wallSlot: Slot): bool =
    # Check whether an EL is connected
    if elManager == nil:
      return false

    isSynced(wallSlot)

  var blocksGossipState: GossipState = {}
  proc updateBlocksGossipStatus(slot: Slot) =
    let
      isBehind = not shouldSyncOptimistically(slot)

      targetGossipState = getTargetGossipState(
        slot.epoch, cfg.ALTAIR_FORK_EPOCH, cfg.BELLATRIX_FORK_EPOCH,
        cfg.CAPELLA_FORK_EPOCH, cfg.DENEB_FORK_EPOCH, cfg.ELECTRA_FORK_EPOCH,
        cfg.FULU_FORK_EPOCH, isBehind)

    template currentGossipState(): auto = blocksGossipState
    if currentGossipState == targetGossipState:
      return

    if currentGossipState.card == 0 and targetGossipState.card > 0:
      debug "Enabling blocks topic subscriptions",
        wallSlot = slot, targetGossipState
    elif currentGossipState.card > 0 and targetGossipState.card == 0:
      debug "Disabling blocks topic subscriptions",
        wallSlot = slot
    else:
      # Individual forks added / removed
      discard

    let
      newGossipForks = targetGossipState - currentGossipState
      oldGossipForks = currentGossipState - targetGossipState

    for gossipFork in oldGossipForks:
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
      network.unsubscribe(getBeaconBlocksTopic(forkDigest))

    for gossipFork in newGossipForks:
      let forkDigest = forkDigests[].atConsensusFork(gossipFork)
      network.subscribe(
        getBeaconBlocksTopic(forkDigest), blocksTopicParams,
        enableTopicMetrics = true)

    blocksGossipState = targetGossipState

  proc onSlot(wallTime: BeaconTime, lastSlot: Slot) =
    let
      wallSlot = wallTime.slotOrZero()
      expectedSlot = lastSlot + 1
      delay = wallTime - expectedSlot.start_beacon_time()

      finalizedHeader = lightClient.finalizedHeader
      optimisticHeader = lightClient.optimisticHeader

      finalizedBid = withForkyHeader(finalizedHeader):
        when lcDataFork > LightClientDataFork.None:
          forkyHeader.beacon.toBlockId()
        else:
          BlockId(root: genesisBlockRoot, slot: GENESIS_SLOT)
      optimisticBid = withForkyHeader(optimisticHeader):
        when lcDataFork > LightClientDataFork.None:
          forkyHeader.beacon.toBlockId()
        else:
          BlockId(root: genesisBlockRoot, slot: GENESIS_SLOT)

      syncStatus =
        if optimisticHeader.kind == LightClientDataFork.None:
          "bootstrapping(" & $config.trustedBlockRoot & ")"
        elif not isSynced(wallSlot):
          "syncing"
        else:
          "synced"

    info "Slot start",
      slot = shortLog(wallSlot),
      epoch = shortLog(wallSlot.epoch),
      sync = syncStatus,
      peers = len(network.peerPool),
      head = shortLog(optimisticBid),
      finalized = shortLog(finalizedBid),
      delay = shortLog(delay)

  proc runOnSlotLoop() {.async.} =
    var
      curSlot = getBeaconTime().slotOrZero()
      nextSlot = curSlot + 1
      timeToNextSlot = nextSlot.start_beacon_time() - getBeaconTime()
    while true:
      await sleepAsync(timeToNextSlot)

      let
        wallTime = getBeaconTime()
        wallSlot = wallTime.slotOrZero()

      onSlot(wallTime, curSlot)

      curSlot = wallSlot
      nextSlot = wallSlot + 1
      timeToNextSlot = nextSlot.start_beacon_time() - getBeaconTime()

  proc onSecond(time: Moment) =
    let wallSlot = getBeaconTime().slotOrZero()
    if checkIfShouldStopAtEpoch(wallSlot, config.stopAtEpoch):
      quit(0)

    updateBlocksGossipStatus(wallSlot + 1)
    lightClient.updateGossipStatus(wallSlot + 1)

  proc runOnSecondLoop() {.async.} =
    let sleepTime = chronos.seconds(1)
    while true:
      let start = chronos.now(chronos.Moment)
      await chronos.sleepAsync(sleepTime)
      let afterSleep = chronos.now(chronos.Moment)
      let sleepTime = afterSleep - start
      onSecond(start)
      let finished = chronos.now(chronos.Moment)
      let processingTime = finished - afterSleep
      trace "onSecond task completed", sleepTime, processingTime

  onSecond(Moment.now())
  lightClient.start()

  asyncSpawn runOnSlotLoop()
  asyncSpawn runOnSecondLoop()
  while globalRunning:
    poll()

  notice "Exiting light client"
