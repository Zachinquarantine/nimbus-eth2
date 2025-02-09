# beacon_chain
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  options, tables, sets, macros,
  chronicles, chronos, stew/ranges/bitranges, libp2p/switch,
  ../spec/datatypes/[phase0, altair, bellatrix],
  ../spec/[helpers, forks, network],
  ".."/[beacon_clock],
  ../networking/eth2_network,
  ../consensus_object_pools/blockchain_dag

logScope:
  topics = "sync"

const
  MAX_REQUEST_BLOCKS = 1024

  blockByRootLookupCost = allowedOpsPerSecondCost(50)
  blockResponseCost = allowedOpsPerSecondCost(100)
  blockByRangeLookupCost = allowedOpsPerSecondCost(20)

type
  StatusMsg* = object
    forkDigest*: ForkDigest
    finalizedRoot*: Eth2Digest
    finalizedEpoch*: Epoch
    headRoot*: Eth2Digest
    headSlot*: Slot

  ValidatorSetDeltaFlags {.pure.} = enum
    Activation = 0
    Exit = 1

  ValidatorChangeLogEntry* = object
    case kind*: ValidatorSetDeltaFlags
    of Activation:
      pubkey: ValidatorPubKey
    else:
      index: uint32

  BeaconSyncNetworkState* = ref object
    dag*: ChainDAGRef
    getBeaconTime*: GetBeaconTimeFn

  BeaconSyncPeerState* = ref object
    statusLastTime*: chronos.Moment
    statusMsg*: StatusMsg

  BlockRootSlot* = object
    blockRoot: Eth2Digest
    slot: Slot

  BlockRootsList* = List[Eth2Digest, Limit MAX_REQUEST_BLOCKS]

proc readChunkPayload*(conn: Connection, peer: Peer,
                       MsgType: type ForkedSignedBeaconBlock): Future[NetRes[ForkedSignedBeaconBlock]] {.async.} =
  var contextBytes: ForkDigest
  try:
    await conn.readExactly(addr contextBytes, sizeof contextBytes)
  except CatchableError:
    return neterr UnexpectedEOF

  if contextBytes == peer.network.forkDigests.phase0:
    let res = await readChunkPayload(conn, peer, phase0.SignedBeaconBlock)
    if res.isOk:
      return ok ForkedSignedBeaconBlock.init(res.get)
    else:
      return err(res.error)
  elif contextBytes == peer.network.forkDigests.altair:
    let res = await readChunkPayload(conn, peer, altair.SignedBeaconBlock)
    if res.isOk:
      return ok ForkedSignedBeaconBlock.init(res.get)
    else:
      return err(res.error)
  elif contextBytes == peer.network.forkDigests.bellatrix:
    let res = await readChunkPayload(conn, peer, bellatrix.SignedBeaconBlock)
    if res.isOk:
      return ok ForkedSignedBeaconBlock.init(res.get)
    else:
      return err(res.error)
  else:
    return neterr InvalidContextBytes

proc sendResponseChunk*(response: UntypedResponse,
                        val: ForkedSignedBeaconBlock): Future[void] =
  inc response.writtenChunks

  case val.kind
  of BeaconBlockFork.Phase0:
    response.stream.writeChunk(some ResponseCode.Success,
                               SSZ.encode(val.phase0Data),
                               response.peer.network.forkDigests.phase0.data)
  of BeaconBlockFork.Altair:
    response.stream.writeChunk(some ResponseCode.Success,
                               SSZ.encode(val.altairData),
                               response.peer.network.forkDigests.altair.data)
  of BeaconBlockFork.Bellatrix:
    response.stream.writeChunk(some ResponseCode.Success,
                               SSZ.encode(val.mergeData),
                               response.peer.network.forkDigests.bellatrix.data)

func shortLog*(s: StatusMsg): auto =
  (
    forkDigest: s.forkDigest,
    finalizedRoot: shortLog(s.finalizedRoot),
    finalizedEpoch: shortLog(s.finalizedEpoch),
    headRoot: shortLog(s.headRoot),
    headSlot: shortLog(s.headSlot)
  )
chronicles.formatIt(StatusMsg): shortLog(it)

func disconnectReasonName(reason: uint64): string =
  # haha, nim doesn't support uint64 in `case`!
  if reason == uint64(ClientShutDown): "Client shutdown"
  elif reason == uint64(IrrelevantNetwork): "Irrelevant network"
  elif reason == uint64(FaultOrError): "Fault or error"
  else: "Disconnected (" & $reason & ")"

proc getCurrentStatus*(state: BeaconSyncNetworkState): StatusMsg {.gcsafe.} =
  let
    dag = state.dag
    headBlock = dag.head
    wallTimeSlot = state.getBeaconTime().slotOrZero

  StatusMsg(
    forkDigest: state.dag.forkDigestAtEpoch(wallTimeSlot.epoch),
    finalizedRoot:
      getStateField(dag.headState.data, finalized_checkpoint).root,
    finalizedEpoch:
      getStateField(dag.headState.data, finalized_checkpoint).epoch,
    headRoot: headBlock.root,
    headSlot: headBlock.slot)

proc handleStatus(peer: Peer,
                  state: BeaconSyncNetworkState,
                  ourStatus: StatusMsg,
                  theirStatus: StatusMsg): Future[void] {.gcsafe.}

proc setStatusMsg(peer: Peer, statusMsg: StatusMsg) {.gcsafe.}

{.pop.} # TODO fix p2p macro for raises

p2pProtocol BeaconSync(version = 1,
                       networkState = BeaconSyncNetworkState,
                       peerState = BeaconSyncPeerState):

  onPeerConnected do (peer: Peer, incoming: bool) {.async.}:
    debug "Peer connected",
      peer, peerId = shortLog(peer.peerId), incoming
    # Per the eth2 protocol, whoever dials must send a status message when
    # connected for the first time, but because of how libp2p works, there may
    # be a race between incoming and outgoing connections and disconnects that
    # makes the incoming flag unreliable / obsolete by the time we get to
    # this point - instead of making assumptions, we'll just send a status
    # message redundantly.
    # TODO(zah)
    #      the spec does not prohibit sending the extra status message on
    #      incoming connections, but it should not be necessary - this would
    #      need a dedicated flow in libp2p that resolves the race conditions -
    #      this needs more thinking around the ordering of events and the
    #      given incoming flag
    let
      ourStatus = peer.networkState.getCurrentStatus()
      theirStatus = await peer.status(ourStatus, timeout = RESP_TIMEOUT)

    if theirStatus.isOk:
      await peer.handleStatus(peer.networkState,
                              ourStatus, theirStatus.get())
    else:
      debug "Status response not received in time",
            peer, errorKind = theirStatus.error.kind
      await peer.disconnect(FaultOrError)

  proc status(peer: Peer,
              theirStatus: StatusMsg,
              response: SingleChunkResponse[StatusMsg])
    {.async, libp2pProtocol("status", 1).} =
    let ourStatus = peer.networkState.getCurrentStatus()
    trace "Sending status message", peer = peer, status = ourStatus
    await response.send(ourStatus)
    await peer.handleStatus(peer.networkState, ourStatus, theirStatus)

  proc ping(peer: Peer, value: uint64): uint64
    {.libp2pProtocol("ping", 1).} =
    return peer.network.metadata.seq_number

  proc getMetaData(peer: Peer): phase0.MetaData
    {.libp2pProtocol("metadata", 1).} =
    return peer.network.phase0metadata

  proc getMetadata_v2(peer: Peer): altair.MetaData
    {.libp2pProtocol("metadata", 2).} =
    return peer.network.metadata

  proc beaconBlocksByRange(
      peer: Peer,
      startSlot: Slot,
      reqCount: uint64,
      reqStep: uint64,
      response: MultipleChunksResponse[phase0.SignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_range", 1).} =
    trace "got range request", peer, startSlot,
                               count = reqCount, step = reqStep
    if reqCount > 0'u64 and reqStep > 0'u64:
      var blocks: array[MAX_REQUEST_BLOCKS, BlockId]
      let
        dag = peer.networkState.dag
        # Limit number of blocks in response
        count = int min(reqCount, blocks.lenu64)

      let
        endIndex = count - 1
        startIndex =
          dag.getBlockRange(startSlot, reqStep, blocks.toOpenArray(0, endIndex))
      peer.updateRequestQuota(
        blockByRangeLookupCost +
        max(0, endIndex - startIndex + 1).float * blockResponseCost)
      peer.awaitNonNegativeRequestQuota()

      for i in startIndex..endIndex:
        trace "wrote response block",
          slot = blocks[i].slot, roor = shortLog(blocks[i].root)
        let blk = dag.getForkedBlock(blocks[i])
        if blk.isSome():
          let blck = blk.get()
          case blck.kind
          of BeaconBlockFork.Phase0:
            await response.write(blck.phase0Data.asSigned)
          of BeaconBlockFork.Altair, BeaconBlockFork.Bellatrix:
            # Skipping all subsequent blocks should be OK because the spec says:
            # "Clients MAY limit the number of blocks in the response."
            # https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/p2p-interface.md#beaconblocksbyrange
            #
            # Also, our response would be indistinguishable from a node
            # that have been synced exactly to the altair transition slot.
            break

      debug "Block range request done",
        peer, startSlot, count, reqStep, found = count - startIndex
    else:
      raise newException(InvalidInputsError, "Empty range requested")

  proc beaconBlocksByRoot(
      peer: Peer,
      # Please note that the SSZ list here ensures that the
      # spec constant MAX_REQUEST_BLOCKS is enforced:
      blockRoots: BlockRootsList,
      response: MultipleChunksResponse[phase0.SignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_root", 1).} =
    if blockRoots.len == 0:
      raise newException(InvalidInputsError, "No blocks requested")

    let
      dag = peer.networkState.dag
      count = blockRoots.len

    peer.updateRequestQuota(count.float * blockByRootLookupCost)
    peer.awaitNonNegativeRequestQuota()

    var found = 0
    for i in 0..<count:
      let blockRef = dag.getRef(blockRoots[i])
      if not isNil(blockRef):
        let blk = dag.get(blockRef).data
        case blk.kind
        of BeaconBlockFork.Phase0:
          await response.write(blk.phase0Data.asSigned)
          inc found
        of BeaconBlockFork.Altair, BeaconBlockFork.Bellatrix:
          # Skipping this block should be fine because the spec says:
          # "Clients MAY limit the number of blocks in the response."
          # https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/p2p-interface.md#beaconblocksbyroot
          #
          # Also, our response would be indistinguishable from a node
          # that have been synced exactly to the altair transition slot.
          continue

    peer.updateRequestQuota(found.float * blockResponseCost)

    debug "Block root request done",
      peer, roots = blockRoots.len, count, found

  proc beaconBlocksByRange_v2(
      peer: Peer,
      startSlot: Slot,
      reqCount: uint64,
      reqStep: uint64,
      response: MultipleChunksResponse[ForkedSignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_range", 2).} =
    trace "got range request", peer, startSlot,
                               count = reqCount, step = reqStep
    if reqCount > 0'u64 and reqStep > 0'u64:
      var blocks: array[MAX_REQUEST_BLOCKS, BlockId]
      let
        dag = peer.networkState.dag
        # Limit number of blocks in response
        count = int min(reqCount, blocks.lenu64)

      let
        endIndex = count - 1
        startIndex =
          dag.getBlockRange(startSlot, reqStep,
                            blocks.toOpenArray(0, endIndex))
      peer.updateRequestQuota(
        blockByRangeLookupCost +
        max(0, endIndex - startIndex + 1).float * blockResponseCost)
      peer.awaitNonNegativeRequestQuota()

      for i in startIndex..endIndex:
        let
          blk = dag.getForkedBlock(blocks[i])

        if blk.isSome():
          let blck = blk.get()
          await response.write(blck.asSigned)

      debug "Block range request done",
        peer, startSlot, count, reqStep, found = count - startIndex
    else:
      raise newException(InvalidInputsError, "Empty range requested")

  proc beaconBlocksByRoot_v2(
      peer: Peer,
      # Please note that the SSZ list here ensures that the
      # spec constant MAX_REQUEST_BLOCKS is enforced:
      blockRoots: BlockRootsList,
      response: MultipleChunksResponse[ForkedSignedBeaconBlock])
      {.async, libp2pProtocol("beacon_blocks_by_root", 2).} =

    if blockRoots.len == 0:
      raise newException(InvalidInputsError, "No blocks requested")

    let
      dag = peer.networkState.dag
      count = blockRoots.len

    peer.updateRequestQuota(count.float * blockByRootLookupCost)
    peer.awaitNonNegativeRequestQuota()

    var found = 0
    for i in 0..<count:
      let blockRef = dag.getRef(blockRoots[i])
      if not isNil(blockRef):
        let blk = dag.getForkedBlock(blockRef)
        await response.write(blk.asSigned)
        inc found

    peer.updateRequestQuota(found.float * blockResponseCost)

    debug "Block root request done",
      peer, roots = blockRoots.len, count, found

  proc goodbye(peer: Peer,
               reason: uint64)
    {.async, libp2pProtocol("goodbye", 1).} =
    debug "Received Goodbye message", reason = disconnectReasonName(reason), peer

proc useSyncV2*(state: BeaconSyncNetworkState): bool =
  let
    wallTimeSlot = state.getBeaconTime().slotOrZero

  wallTimeSlot.epoch >= state.dag.cfg.ALTAIR_FORK_EPOCH

proc useSyncV2*(peer: Peer): bool =
  peer.networkState(BeaconSync).useSyncV2()

proc setStatusMsg(peer: Peer, statusMsg: StatusMsg) =
  debug "Peer status", peer, statusMsg
  peer.state(BeaconSync).statusMsg = statusMsg
  peer.state(BeaconSync).statusLastTime = Moment.now()

proc updateStatus*(peer: Peer): Future[bool] {.async.} =
  ## Request `status` of remote peer ``peer``.
  let
    nstate = peer.networkState(BeaconSync)
    ourStatus = getCurrentStatus(nstate)

  let theirFut = awaitne peer.status(ourStatus, timeout = RESP_TIMEOUT)
  if theirFut.failed():
    return false
  else:
    let theirStatus = theirFut.read()
    if theirStatus.isOk:
      peer.setStatusMsg(theirStatus.get)
      return true
    else:
      return false

proc getHeadSlot*(peer: Peer): Slot =
  ## Returns head slot for specific peer ``peer``.
  peer.state(BeaconSync).statusMsg.headSlot

proc handleStatus(peer: Peer,
                  state: BeaconSyncNetworkState,
                  ourStatus: StatusMsg,
                  theirStatus: StatusMsg) {.async, gcsafe.} =
  if theirStatus.forkDigest != ourStatus.forkDigest:
    debug "Irrelevant peer", peer, theirStatus, ourStatus
    await peer.disconnect(IrrelevantNetwork)
  else:
    peer.setStatusMsg(theirStatus)
    if peer.connectionState == Connecting:
      # As soon as we get here it means that we passed handshake succesfully. So
      # we can add this peer to PeerPool.
      await peer.handlePeer()

proc initBeaconSync*(network: Eth2Node, dag: ChainDAGRef,
                     getBeaconTime: GetBeaconTimeFn) =
  var networkState = network.protocolState(BeaconSync)
  networkState.dag = dag
  networkState.getBeaconTime = getBeaconTime
