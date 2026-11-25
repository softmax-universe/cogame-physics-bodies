## The game server: mummy HTTP + websockets, the 24 Hz wall-clock-paced game
## loop, the decision turn, the recorded action log, and the artifact writes.
##
## This is ctf's `src/ctf/server.nim` with the five named edits of the design
## note:
##
## 1. INPUT SOURCE. Where ctf reads `appState.inputMasks` (the socket) into
##    `inputs[playerIndex]`, physics-bodies calls `control.driveCommand` for
##    both bodies and passes the command-byte array into `sim.step`. Player
##    sockets contribute NO input: any input mask arriving on one is discarded.
## 2. REPLAY INPUT WRITE. ctf's `writeInputFrameMasks` press/release wrapper is
##    DELETED — its `repeatedPressedMask` logic is button semantics and would
##    corrupt a value byte. We call `writeInputMaskChange` directly and let the
##    codec's own change-only guard do the rest.
## 3. TURN BOUNDARY. Immediately before stepping a tick where
##    `tick mod turnTicks == 0`, the loop runs `decide.turn`, which enforces the
##    inter-batch floor, issues the ONE parallel two-request batch, applies the
##    deadlines, installs the intents and writes the `intent`/`fallback`
##    records — all inside a monotonic `turnBudgetMs` bound.
## 4. WALL-CLOCK STOP. A `wallClockBudgetSeconds` check at the top of every loop
##    iteration writes ONE load-bearing `stop` record and forces
##    `deadline/wall_clock`, applied by the same proc on record and on playback
##    (cogame-particle-worlds 13c66d7).
## 5. SHUTDOWN GRACE. `/healthz` and `/global` keep answering for a bounded
##    ~20 s after the artifacts are written, then the process exits
##    (cogame-lantern 0.1.3: the episode runner pings `/global` with a 2 s
##    deadline AFTER the player pods start, and a short episode can already be
##    gone).

import std/[algorithm, json, locks, monotimes, nativesockets, os, strutils,
            tables, times]
import bitworld/client as bitworldClient
import bitworld/runtime
import bitworld/spriteprotocol
import mummy
import sim, global, replays, broadcast, replay_runtime, events, wire_constants
import intents, control, baselines, decide, llm, prompts, training_capture

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    loadingReplayUri: string
    currentReplayUri: string
    chatMessages: Table[WebSocket, string]
    decisionResponses: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    spritesOff: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    closedSockets: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig
    replayBytes: string

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  WallTextureHorizontalPath = "/client/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/client/art/walls/wall_v.jpg"
  BroadcastFontPath = "/client/font.ttf"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (sends 1009). We
    ## chunk outbound sprite packets under a margin below that.
  ShutdownGraceSeconds = 20

  ## The designed broadcast client, embedded at compile time: a single
  ## self-contained page (shared chrome + core JS inlined). Final in-page
  ## script order is fixed by the marker positions in the HTML.
  EmbeddedBroadcastReplayHtml = staticRead(
      "../../client/replay_broadcast.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()
  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")
  BroadcastFont = staticRead("../../data/font.ttf")
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/green_1.webp",
      staticRead("../../client/art/lockerroom/green_1.webp")),
    ("/client/art/lockerroom/green_2.webp",
      staticRead("../../client/art/lockerroom/green_2.webp")),
    ("/client/art/lockerroom/green_3.webp",
      staticRead("../../client/art/lockerroom/green_3.webp")),
    ("/client/art/lockerroom/green_5.webp",
      staticRead("../../client/art/lockerroom/green_5.webp")),
    ("/client/art/lockerroom/green_6.webp",
      staticRead("../../client/art/lockerroom/green_6.webp")),
    ("/client/art/lockerroom/blue_1.webp",
      staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("/client/art/lockerroom/blue_2.webp",
      staticRead("../../client/art/lockerroom/blue_2.webp")),
    ("/client/art/lockerroom/blue_3.webp",
      staticRead("../../client/art/lockerroom/blue_3.webp")),
    ("/client/art/lockerroom/blue_5.webp",
      staticRead("../../client/art/lockerroom/blue_5.webp")),
    ("/client/art/lockerroom/blue_6.webp",
      staticRead("../../client/art/lockerroom/blue_6.webp")),
    ("/client/art/lockerroom/yellow_1.webp",
      staticRead("../../client/art/lockerroom/yellow_1.webp")),
    ("/client/art/lockerroom/yellow_2.webp",
      staticRead("../../client/art/lockerroom/yellow_2.webp")),
    ("/client/art/lockerroom/yellow_3.webp",
      staticRead("../../client/art/lockerroom/yellow_3.webp")),
    ("/client/art/lockerroom/yellow_5.webp",
      staticRead("../../client/art/lockerroom/yellow_5.webp")),
    ("/client/art/lockerroom/yellow_6.webp",
      staticRead("../../client/art/lockerroom/yellow_6.webp")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/red_2.webp",
      staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/client/art/lockerroom/red_3.webp",
      staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/client/art/lockerroom/red_5.webp",
      staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/client/art/lockerroom/red_6.webp",
      staticRead("../../client/art/lockerroom/red_6.webp"))
  ]

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.chatMessages = initTable[WebSocket, string]()
  appState.decisionResponses = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.spritesOff = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.closedSockets = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc disconnectWebSocket(websocket: WebSocket) =
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc nextAnonymousPlayerIdentity(): string =
  {.gcsafe.}:
    withLock appState.lock:
      result = "Player" & $appState.nextAnonymousPlayer
      inc appState.nextAnonymousPlayer

proc playerSlotOf(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerTokenOf(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
  result = nextAnonymousPlayerIdentity()

proc respondForbiddenWebSocket(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc hasPlayerCredentialParams(request: Request): bool =
  request.queryParams.getOrDefault("name", "").strip().len > 0 or
    request.queryParams.getOrDefault("slot", "").strip().len > 0 or
    request.queryParams.getOrDefault("token", "").strip().len > 0

proc registerPlayerWebSocket(websocket: WebSocket, identity: string,
                             slot: int, token: string) =
  appState.globalViewers.del(websocket)
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.playerAddresses[websocket] = identity
  appState.playerSlots[websocket] = slot
  appState.playerTokens[websocket] = token
  appState.playerIndices[websocket] = 0x7fffffff
  appState.playerReady[websocket] = false

proc registerGlobalWebSocket(websocket: WebSocket) =
  appState.playerViewers.del(websocket)
  appState.playerIndices.del(websocket)
  appState.globalViewers[websocket] = initGlobalViewerState()

proc isPlayerWebSocket(websocket: WebSocket): bool =
  websocket in appState.playerViewers and
    websocket notin appState.globalViewers

proc removeWebSocketState(websocket: WebSocket): int =
  result = -1
  if websocket in appState.playerIndices:
    result = appState.playerIndices[websocket]
    appState.playerIndices.del(websocket)
  appState.globalViewers.del(websocket)
  appState.playerViewers.del(websocket)
  appState.chatMessages.del(websocket)
  appState.decisionResponses.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  appState.playerReady.del(websocket)
  appState.spritesOff.del(websocket)

proc isPlayerReadyPacket*(message: string): bool =
  ## The one-byte Sprite v1 player-ready packet.
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc isSpritesOffPacket*(message: string): bool =
  ## The one-byte Sprite v1 sprites-off packet (0x87). The pinned bitworld
  ## predates the packet, so the id is declared here rather than imported.
  message.len == 1 and message[0].uint8 == 0x87'u8

proc parseRegistration*(text: string):
    tuple[ok: bool, isLlm: bool, scripted: Baseline, policy: string] =
  ## A seat's registration message:
  ##   {"type":"register","mode":"model","policy":"…"}
  ##   {"type":"register","mode":"scripted","scripted":"pusher"|"anchor","policy":"…"}
  ## Anything else is rejected — no silent default to `pusher`.
  result = (false, false, blPusher, "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  let mode = node{"mode"}.getStr().strip().toLowerAscii()
  if mode == "model":
    result.ok = true
    result.isLlm = true
    result.policy = node{"policy"}.getStr()
  elif mode == "scripted":
    try:
      result.scripted = parseBaseline(node{"scripted"}.getStr())
      result.ok = true
      result.isLlm = false
      result.policy = node{"policy"}.getStr()
    except ValueError:
      return

proc replayServerModeEnabled(): bool =
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayServerMode

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    ## The bytes this episode recorded, for anything that wants the replay
    ## straight off the game container.
    var bytes = ""
    {.gcsafe.}:
      withLock appState.lock:
        bytes = appState.replayBytes
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    request.respond((if bytes.len > 0: 200 else: 404), headers, bytes)
  elif request.path == WebSocketPath and request.httpMethod == "GET":
    let
      slot = request.playerSlotOf()
      token = request.playerTokenOf()
      identity = request.playerIdentity(slot, token)
    ## A player websocket whose token does not match the seat is CLOSED: the
    ## certifier probes `?slot=0&token=bad` and a server that accepts it fails
    ## cert `smoke-episode` (cogame-flatland 0.1.1).
    var allowed = false
    {.gcsafe.}:
      withLock appState.lock:
        allowed = appState.config.playerJoinAllowed(identity, slot, token)
    if not allowed:
      request.respondForbiddenWebSocket(
        "Player credentials do not match configured slot " & $slot & ".")
      return
    if not request.isWebSocketUpgrade():
      ## The certifier probes this route with a plain GET too; answering the
      ## catch-all 200 there would say the credentials were fine.
      var headers: HttpHeaders
      headers["Content-Type"] = "text/plain; charset=utf-8"
      headers["Cache-Control"] = "no-cache"
      request.respond(200, headers, "physics-bodies player socket\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerPlayerWebSocket(identity, slot, token)
    echo "player connected: ", identity
  elif request.path in [GlobalWebSocketPath, ReplayWebSocketPath] and
      request.httpMethod == "GET":
    if request.hasPlayerCredentialParams():
      request.respondForbiddenWebSocket(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    if not request.isWebSocketUpgrade():
      var headers: HttpHeaders
      headers["Content-Type"] = "text/plain; charset=utf-8"
      headers["Cache-Control"] = "no-cache"
      request.respond(200, headers, "physics-bodies spectator socket\n")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path in [WallTextureHorizontalPath, WallTextureVerticalPath] and
      request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    if request.path == WallTextureHorizontalPath:
      request.respond(200, headers, WallTextureHorizontal)
    else:
      request.respond(200, headers, WallTextureVertical)
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.httpMethod == "GET" and (block:
      var hit = false
      for (path, _) in LockerRoomAssets:
        if request.path == path:
          hit = true
          break
      hit):
    var headers: HttpHeaders
    headers["Content-Type"] =
      if request.path.endsWith(".webp"): "image/webp" else: "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        request.respond(200, headers, art)
        break
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      bitworldClient.GlobalClientRoute,
      bitworldClient.CoworldGlobalClientRoute,
      bitworldClient.PlayerClientRoute,
      bitworldClient.CoworldPlayerClientRoute
    ] and request.httpMethod == "GET":
    ## BOTH `/client/` routes serve REAL pages, registered BEFORE any catch-all
    ## asset route, and neither opens the player socket (cogame-lantern 0.1.1:
    ## the certifier probes them before starting the player pods).
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, EmbeddedBroadcastReplayHtml)
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "physics-bodies server")

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    ## NOTHING ELSE IN THIS HANDLER IS GUARDED BY MESSAGE KIND. A
    ## `kind != TextMessage` guard would drop the player's binary registration
    ## frames, and losing the Ping -> Pong branch is a cert
    ## `game_contract_violation` (seen twice: lux-ai 0.1.0, snake-royale 0.1.0).
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == TextMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.playerViewers and
              message.data.len > 0 and message.data[0] == '{':
            try:
              let node = parseJson(message.data)
              if node.kind == JObject and
                  node{"type"}.getStr() == "decision_response":
                appState.decisionResponses[websocket] = message.data
            except CatchableError:
              discard
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif message.data.isSpritesOffPacket():
            appState.spritesOff[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers:
            var chatText = ""
            appState.playerViewers[websocket].applyPlayerViewerMessage(
              message.data, chatText)
            ## A seat's chat is its REGISTRATION and nothing else. Anything
            ## else is dropped HERE rather than in the loop, so a later chat
            ## line can never overwrite a registration that has not been
            ## consumed yet — cogs shout, seats do not.
            if chatText.len > 0 and parseRegistration(chatText).ok:
              appState.chatMessages[websocket] = chatText
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        let newlyClosed = markSocketClosed(websocket)
        if newlyClosed and websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

type FrameAdvance = enum
  LateFrame, SkippedFrame, WaitedFrame

proc allPlayersReady(sockets: openArray[WebSocket],
                     playerIndices: openArray[int], seats: int): bool =
  var active = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= playerIndices.len or playerIndices[i] < 0 or
            playerIndices[i] >= seats:
          continue
        inc active
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  active > 0

proc resetPlayerReady(sockets: openArray[WebSocket],
                      playerIndices: openArray[int], seats: int) =
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i < playerIndices.len and playerIndices[i] >= 0 and
            playerIndices[i] < seats and websocket in appState.playerReady:
          appState.playerReady[websocket] = false

proc runFrameLimiter(previousTick: var MonoTime, fastMode: bool,
                     sockets: openArray[WebSocket],
                     playerIndices: openArray[int],
                     seats: int): FrameAdvance =
  ## `fastMode` advances the sim as soon as every player container has
  ## acknowledged the frame, so SIM TIME is not charged against the wall
  ## clock — the decision turns are the pacing.
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  var slept = false
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      result = if slept: WaitedFrame else: LateFrame
      break
    if fastMode and sockets.allPlayersReady(playerIndices, seats):
      result = SkippedFrame
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
    slept = true
  previousTick = getMonoTime()

proc declarePlayerFailure(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for, so a lobby no-show is charged to the seat that caused it
  ## instead of poisoning the whole episode unattributed. Best-effort: outside
  ## the platform (env unset) this is a no-op.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc runServerLoop*(host: string = sim.DefaultHost,
                    port: int = sim.DefaultPort,
                    initialConfig = defaultGameConfig(),
                    saveReplayPath = "", loadReplayPath = "",
                    saveScoresPath = "",
                    runtimeConfig = RuntimeConfig()) =
  initAppState()
  let selection = promptSelection(
    if runtimeConfig.config.len > 0: parseJson(runtimeConfig.config)
    else: newJObject())
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        ## A bad or version-mismatched replay must not kill the server: the
        ## viewer would see a dead socket with no explanation.
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initializedReplay =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: move(initializedReplay.config) else: initialConfig
  var
    sim =
      if replayLoaded: move(initializedReplay.sim) else: initSimServer(config)
    replayPlayer =
      if replayLoaded: move(initializedReplay.player) else: ReplayPlayer()
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()
    replayWriter = openReplayWriter(saveReplayPath,
      config.configJson(sim.perm))
  defer: replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayLoaded
  appState.config = config

  ## Tier-2 event sink. Off unless the platform configured a destination.
  ## file:// ONLY, and it fails loudly otherwise rather than silently dropping
  ## the stream: the dispatcher writes this as a workdir path and the runner
  ## uploads the file afterwards.
  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri)
  let metricsPath = block:
    let uri = getEnv("COGAME_METRICS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_METRICS_URI must be a file:// path, got: " & uri)

  var collectedEvents: seq[SimEvent] = @[]
  sim.collectEvents = eventsPath.len > 0

  block:
    ## Bake the board plate BEFORE the listener opens: a viewer's first-message
    ## clock starts at its successful connect (the certifier allows only
    ## seconds), so nothing may be accepted until every frame the loop will
    ## ever build can be assembled instantly.
    let warmStart = getMonoTime()
    sim.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    engine = if replayLoaded: DecisionEngine() else: initDecisionEngine(sim, selection)
    lastTick = getMonoTime()
    episodeStart = getMonoTime()
    deadlineHit = false
    lastTurnKey = -1
    liveSpeedIndex = 0
    quitAfterFrame = false
    policyFailed = false
    cmds = newSeq[uint8](BodyCount)
    reportedNoShow = false
    roundsRecorded = 0

  template failPolicy(seatIdx: int, cause, detail: string) =
    if not policyFailed:
      policyFailed = true
      quitAfterFrame = true
      echo "physics-bodies: POLICY FAILURE seat=", seatIdx, " cause=", cause,
        " detail=", detail
      declarePlayerFailure(seatIdx, cause & ": " & detail)
      engine.capture.finishFailure(seatIdx, cause, detail)
      replayWriter.writeChat(tickTime(sim.tickCount), 0,
        policyFailureRecord(sim.turnIndexAt(sim.tickCount), seatIdx, cause,
          detail))

  ## Each `round` record rides the tick its round ENDED on. These records are
  ## FORENSIC — playback re-derives every round inside `bankRound` and
  ## `applyReplayEvents` refuses to re-apply a `round` record, so nothing here
  ## touches the hash chain — and a forensic record stamped with the episode's
  ## last tick cannot locate the round it describes, which is what
  ## tools/replay_summary.py reads them for (r1 review N12).
  template flushRoundRecords() =
    while roundsRecorded < sim.roundLog.len:
      let entry = sim.roundLog[roundsRecorded]
      replayWriter.writeChat(tickTime(sim.tickCount), 0,
        roundRecord(int(entry.round), int(entry.winner), $entry.reason,
          int(entry.ticks), entry.knockdowns))
      inc roundsRecorded

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]

    ## EDIT 4 — the engine's own hard stop, checked before anything else this
    ## iteration. `wallClockBudgetSeconds` is 55 % of the assumed 1200 s
    ## `episodeTimeoutSeconds`, so the episode always settles and scores itself
    ## rather than being silently discarded for overrunning.
    if not replayLoaded and not deadlineHit and sim.phase != GameOver and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      deadlineHit = true
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode from the state at this tick"
      replayWriter.writeChat(tickTime(sim.tickCount), 0,
        stopRecord(sim.tickCount, "wall_clock"))
      sim.applyWallClockStop(int32(sim.tickCount))
      ## One more (GameOver, no-op) tick so the stop lands INSIDE the hash
      ## chain and playback can render the endcard rather than stopping short.
      sim.step(cmds)
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
      flushRoundRecords()
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          let index = removeWebSocketState(websocket)
          if not replayLoaded and index >= 0 and index < sim.players.len:
            replayWriter.writeLeave(tickTime(sim.tickCount), index)
            sim.removePlayerAt(index)
            if sim.phase in {Playing, RoundReset} and not policyFailed:
              failPolicy(index, "disconnected",
                "player slot " & $index & " disconnected during match")
        appState.closedSockets.setLen(0)

        if not replayLoaded and sim.lobbyNoShowSeat >= 0 and
            not reportedNoShow:
          ## A seat that never connects terminates the episode as an explicit
          ## policy failure with NO substitute baseline and NO published scores.
          reportedNoShow = true
          let stuckSlot = int(sim.lobbyNoShowSeat)
          failPolicy(stuckSlot, "no_show",
            "player slot " & $stuckSlot & " never joined the lobby within " &
              $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
              $(config.lobbyJoinTimeoutTicks div TargetFps) & "s)")

        if not replayLoaded:
          ## Admit pending joins in slot order — ACTUALLY in slot order. This
          ## walks a Table, whose iteration order is unspecified, so when both
          ## sockets are pending on the same server iteration the loop could
          ## reach slot 1 first; `addPlayer` then refused it with "slot 1 cannot
          ## join before slot 0" and the `except` below latched -1, which is
          ## PERMANENT. The seat was thrown away and the lobby then waited out
          ## its whole budget for a socket that was still connected and still
          ## sending Ready packets. Non-deterministic by construction, so it
          ## never showed up locally (the two seats connect a beat apart and
          ## each is admitted alone) and cost 0.1.1 and 0.1.2 their hosted
          ## smoke: 1 of 5, then 3 of 5, episodes failed
          ## "player slot 1 never joined the lobby".
          var pending: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket() and
                appState.playerIndices[websocket] == 0x7fffffff:
              pending.add websocket
          pending.sort(proc (a, b: WebSocket): int =
            cmp(appState.playerSlots.getOrDefault(a, -1),
                appState.playerSlots.getOrDefault(b, -1)))
          for websocket in pending:
            let
              address = appState.playerAddresses.getOrDefault(websocket,
                "unknown")
              slot = appState.playerSlots.getOrDefault(websocket, -1)
              token = appState.playerTokens.getOrDefault(websocket, "")
            if sim.phase != Lobby or not sim.canAddPlayer():
              appState.playerIndices[websocket] = -1
              continue
            ## A slot that is not the next open one is HELD, not refused, which
            ## is what PROTOCOL.md promises: "a seat whose slot is not the next
            ## open one is not admitted until the lower slots have joined". It
            ## stays at 0x7fffffff and is retried next iteration. Only a
            ## genuinely fatal refusal (illegal slot, token mismatch, duplicate
            ## address, full match) latches -1.
            if slot >= 0 and slot != sim.nextPlayerSlot():
              continue
            try:
              let index = sim.addPlayer(address, slot, token)
              appState.playerIndices[websocket] = index
              replayWriter.writeJoin(tickTime(sim.tickCount), index, address,
                slot, token)
              echo "seat ", index, " joined: ", address
            except BodiesError as error:
              echo "join refused: ", error.msg
              appState.playerIndices[websocket] = -1

        for websocket, playerIndex in appState.playerIndices.pairs:
          if not websocket.isPlayerWebSocket():
            continue
          sockets.add websocket
          playerIndices.add playerIndex
          playerViewerStates.add appState.playerViewers[websocket]

        if not replayLoaded:
          ## Registrations that cannot be applied YET are HELD, not dropped.
          ## A seat's first registration can arrive before its player index
          ## exists (the lobby sends frames to a socket before it is admitted),
          ## and clearing the table then discarded them for good — the champion
          ## played the scripted baseline for the whole episode with no
          ## `register` record at all.
          var held: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(websocket, -1)
            let registration = parseRegistration(chatText)
            if playerIndex < 0 or playerIndex >= BodyCount:
              if websocket.isPlayerWebSocket() and registration.ok:
                held.add((websocket, chatText))
              continue
            if not registration.ok:
              ## A seat's chat is its REGISTRATION and nothing else: any other
              ## text from a player socket is dropped, never applied and never
              ## written to the replay.
              continue
            var policy = engine.seats[playerIndex]
            let firstRegistration = not policy.registered
            policy.registered = true
            policy.isLlm = registration.isLlm
            policy.baseline = registration.scripted
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: "model"
              else: $policy.baseline
            engine.seats[playerIndex] = policy
            sim.seatPolicyKind[playerIndex] = engine.policyKind(playerIndex)
            if firstRegistration:
              ## One `register` record and one log line per seat: the seat
              ## re-sends its registration for the first ~10 s of frames.
              let baselineName = if policy.isLlm: "" else: $policy.baseline
              replayWriter.writeChat(tickTime(sim.tickCount), playerIndex,
                registerRecord(playerIndex, sim.bodyOfSeat(playerIndex),
                  policy.label, engine.policyKind(playerIndex),
                  baselineName))
              echo "seat ", playerIndex, " registered: kind=",
                engine.policyKind(playerIndex),
                (if baselineName.len > 0: " baseline=" & baselineName else: "")
          appState.chatMessages.clear()
          for (websocket, chatText) in held:
            appState.chatMessages[websocket] = chatText

        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add websocket
          globalStates.add state
          if state.replaySeekTick >= 0:
            replaySeekTicks.add state.replaySeekTick
          for command in state.replayCommands:
            replayCommands.add command
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1

    var frameEvents = newJArray()
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(sim, broadcastTracker,
        replaySeekTicks, replayCommands)
    elif not quitAfterFrame:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      for _ in 0 ..< playbackSpeed(liveSpeedIndex):
        ## EDIT 3 — the decision turn, immediately before the tick that starts
        ## it. This is the determinism boundary: the controller and the LLM live
        ## on THIS side of it, and only the bytes below are recorded, so the
        ## wasm viewer re-derives the whole match without running either.
        if sim.phase == Playing:
          let
            turnTicks = max(1, config.turnTicks)
            turnIndex = sim.tickCount div turnTicks
          if sim.tickCount mod turnTicks == 0 and turnIndex != lastTurnKey:
            lastTurnKey = turnIndex
            let seatsCount = sim.seatCount()
            if engine.capture != nil:
              var observations: seq[JsonNode]
              for seat in 0 ..< engine.seats.len:
                observations.add(parseJson(seatViewJson(engine.viewFor(sim, seat))))
              engine.capture.beginTurn(observations)

            var openSockets: seq[(int, WebSocket)] = @[]
            for seat in 0 ..< seatsCount:
              if not engine.seats[seat].registered:
                engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
                failPolicy(seat, "unregistered",
                  "seat " & $seat & " did not register before turn " & $turnIndex)
                break
              if engine.seats[seat].isLlm:
                var found = false
                for idx, ws in sockets:
                  if idx < playerIndices.len and playerIndices[idx] == seat:
                    openSockets.add((seat, ws))
                    found = true
                    break
                if not found:
                  engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
                  failPolicy(seat, "disconnected",
                    "model seat " & $seat & " is not connected on turn " & $turnIndex)
                  break
              else:
                var intent = engine.scriptedFor(sim, seat, engine.seats[seat].baseline)
                intent.source = isScripted
                engine.installIntent(seat, intent)

            if policyFailed:
              break

            if openSockets.len > 0:
              if engine.batchStarted and config.turnSpacingMs > 0:
                let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
                if since < config.turnSpacingMs:
                  sleep(min(config.turnSpacingMs, config.turnSpacingMs - since))
              engine.lastBatchStart = getMonoTime()
              engine.batchStarted = true

              let sysPrompt = systemPrompt(engine.selection)
              {.gcsafe.}:
                withLock appState.lock:
                  for (_, ws) in openSockets:
                    appState.decisionResponses.del(ws)

              for (seat, ws) in openSockets:
                let req = %*{
                  "type": "decision_request",
                  "turn": turnIndex,
                  "tick": sim.tickCount,
                  "seat": seat,
                  "system": sysPrompt,
                  "observation": parseJson(seatViewJson(engine.viewFor(sim, seat))),
                  "deadline_ms": config.turnBudgetMs
                }
                try:
                  ws.send($req, TextMessage)
                except CatchableError as err:
                  engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
                  failPolicy(seat, "disconnected",
                    "failed sending decision_request to seat " & $seat & ": " & err.msg)
                  break

            if policyFailed:
              break

            if openSockets.len > 0:
              var pending = openSockets
              let turnDeadline = getMonoTime() +
                initDuration(milliseconds = max(1000, config.turnBudgetMs))
              while pending.len > 0 and not policyFailed:
                var nextPending: seq[(int, WebSocket)] = @[]
                for (seat, ws) in pending:
                  var rawResp = ""
                  var isClosed = false
                  {.gcsafe.}:
                    withLock appState.lock:
                      if ws in appState.decisionResponses:
                        rawResp = appState.decisionResponses[ws]
                        appState.decisionResponses.del(ws)
                      elif ws in appState.closedSockets or ws notin appState.playerViewers:
                        isClosed = true
                  if isClosed:
                    engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
                    failPolicy(seat, "disconnected",
                      "model seat " & $seat & " disconnected while awaiting turn " & $turnIndex)
                    break
                  if rawResp.len == 0:
                    nextPending.add((seat, ws))
                    continue
                  var node: JsonNode = nil
                  try:
                    node = parseJson(rawResp)
                  except CatchableError:
                    node = nil
                  if node.isNil or node.kind != JObject or
                      node{"turn"}.getInt(-1) != turnIndex:
                    nextPending.add((seat, ws))
                    continue
                  var hasEvidence = false
                  var evidence: DecisionAttempt
                  if node.hasKey("attempt") and node["attempt"].kind == JObject:
                    try:
                      evidence = readAttemptEvidence(node["attempt"])
                      hasEvidence = true
                    except CatchableError:
                      hasEvidence = false
                  if node.hasKey("error") and node["error"].kind == JString and
                      node["error"].getStr().len > 0:
                    let errMsg = node["error"].getStr()
                    let cause = node{"cause"}.getStr("provider_error")
                    if hasEvidence:
                      evidence.accepted = false
                      if evidence.rejectionReason.isNone:
                        evidence.rejectionReason = some(errMsg)
                      engine.capture.recordAttempt(seat, evidence)
                    engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
                    failPolicy(seat, cause, errMsg)
                    break
                  let replyText = node{"reply"}.getStr()
                  try:
                    var intent = parseIntentReply(replyText)
                    intent.source = isLlm
                    intent.latencyMs = node{"latency_ms"}.getInt(0)
                    engine.installIntent(seat, intent)
                    if hasEvidence:
                      evidence.parsedAction = intent.intentAction()
                      evidence.accepted = true
                      engine.capture.recordAttempt(seat, evidence)
                  except CatchableError as parseErr:
                    if hasEvidence:
                      evidence.accepted = false
                      evidence.rejectionReason = some(parseErr.msg)
                      engine.capture.recordAttempt(seat, evidence)
                    engine.capture.recordFailedDecision(seat, sim.tickCount, asRejected)
                    failPolicy(seat, "parse_error", parseErr.msg)
                    break
                if policyFailed:
                  break
                pending = nextPending
                if pending.len > 0:
                  if getMonoTime() >= turnDeadline:
                    let (seat, _) = pending[0]
                    engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
                    failPolicy(seat, "timeout",
                      "model seat " & $seat & " did not respond within " &
                      $config.turnBudgetMs & " ms on turn " & $turnIndex)
                    break
                  sleep(10)

            if policyFailed:
              break

            for seat in 0 ..< seatsCount:
              let intent = engine.intents[seat]
              let origin = if intent.source == isLlm: aoModel else: aoTeacher
              engine.capture.applied(seat, sim.tickCount, intent.intentAction(), origin,
                if origin == aoTeacher: "scripted-" & $engine.seats[seat].baseline
                else: engine.seats[seat].label)
              if intent.source == isLlm:
                inc sim.llmTurns[seat]
              let record = boundedIntentRecord(intent, turnIndex, seat,
                sim.bodyOfSeat(seat))
              replayWriter.writeChat(tickTime(sim.tickCount), seat, record)
              sim.pushFeedIntent(record)
              sim.emitEvent(Intent, source = sim.bodyOfSeat(seat),
                detail = $intent.source, amount = turnIndex,
                content = intent.note)

        ## EDIT 1 + 2 — compile ONE command byte per BODY, in index order, and
        ## write it straight into the action log.
        for i in 0 ..< BodyCount:
          let
            intent = engine.intentForBody(sim, i)
            cmd = driveCommand(engine.ctl, sim, i, intent, sim.tickCount)
            row = sim.inputIndexOfBody(i)
          if row >= 0 and row < cmds.len:
            cmds[row] = cmd
          replayWriter.writeInputMaskChange(tickTime(sim.tickCount), row, cmd)

        var faultRule = ""
        try:
          sim.step(cmds)
        except SimGuardError as guard:
          echo "physics-bodies: SIM GUARD tripped at tick ", sim.tickCount,
            ": ", guard.msg
          faultRule = EndRuleSimFault
        except CatchableError as error:
          echo "physics-bodies: HOST ERROR at tick ", sim.tickCount, ": ",
            error.msg
          faultRule = EndRuleHostError
        if faultRule.len > 0:
          ## A tripped invariant is NOT a silent non-zero exit: the episode
          ## ends `fault/<rule>` here and the artifact block below still writes
          ## the partial replay, the results and the events.
          sim.endReason = ReasonFault
          sim.endRule = faultRule
          sim.phase = GameOver
          quitAfterFrame = true
          break
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
        flushRoundRecords()
        if sim.collectEvents:
          for event in sim.events:
            collectedEvents.add event
          sim.events.setLen(0)
        if sim.phase == GameOver:
          quitAfterFrame = true
          break

    if not replayLoaded and config.fastMode:
      sockets.resetPlayerReady(playerIndices, sim.seatCount())

    ## Per-seat frames. Board labels carry only BUG-1 / BUG-2:
    ## `showPlayerLabels` is forced false on the player stream.
    var spritesOffFlags = newSeq[bool](sockets.len)
    {.gcsafe.}:
      withLock appState.lock:
        for i in 0 ..< sockets.len:
          spritesOffFlags[i] =
            appState.spritesOff.getOrDefault(sockets[i], false)
    for i in 0 ..< sockets.len:
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i], playerViewerStates[i], nextState,
        spritesOff = spritesOffFlags[i])
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
      let wirePacket = dedupObjectPlacements(
        (if spritesOffFlags[i]: framePacket.stripSpritePixels()
         else: framePacket),
        nextState.sentPlacements)
      try:
        if wirePacket.len == 0:
          ## One binary message per tick is the frame contract — clients count
          ## messages to advance. An all-deduped frame still ships, as an
          ## empty message.
          sockets[i].send("", BinaryMessage)
        for chunk in chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(sockets[i])

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      var packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(replayPlayer, globalStates[i], nextState,
            frameEvents)
        else:
          block:
            var board = sim.buildSpriteProtocolUpdates(globalStates[i],
              nextState)
            sim.stepEvents(broadcastTracker, frameEvents)
            board.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
              sim.buildStateJson(frameEvents, true,
                float(playbackSpeed(liveSpeedIndex)),
                sim.effectiveMaxTicks(),
                false, false, -1))
            board
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              ## The websocket thread keeps writing viewer INPUT into this
              ## entry while the frame was being built from an earlier
              ## snapshot; blindly storing nextState would erase any input that
              ## arrived in between.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if quitAfterFrame:
      if policyFailed:
        replayWriter.closeReplayWriter()
        if saveReplayPath.len > 0 and fileExists(saveReplayPath):
          let bytes = readFile(saveReplayPath)
          {.gcsafe.}:
            withLock appState.lock:
              appState.replayBytes = bytes
          runtimeConfig.writeReplay(bytes)
        echo "physics-bodies: episode terminated on policy failure at tick ",
          sim.tickCount, " (no scores published)"
        let graceUntil = getMonoTime() + initDuration(seconds = 2)
        while getMonoTime() < graceUntil:
          sleep(100)
        httpServer.close()
        joinThread(serverThread)
        break
      engine.capture.finishCapture(parseJson(sim.playerResultsJson()))
      ## The `result` control record: the full results document, written once
      ## into the replay chat stream at episode end, so the bytes are
      ## SELF-SUFFICIENT. Never applied as a shout at playback (a leading '{'
      ## marks a control record), so the hash chain is untouched.
      replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
      ## Anything the loop above could not flush — a round banked by the very
      ## step that then faulted — still gets exactly one record.
      flushRoundRecords()
      if saveReplayPath.len > 0:
        echo "Writing replay file: ", saveReplayPath
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        let bytes = readFile(saveReplayPath)
        echo "Replay written: ", saveReplayPath, " (", bytes.len, " bytes)"
        {.gcsafe.}:
          withLock appState.lock:
            appState.replayBytes = bytes
        runtimeConfig.writeReplay(bytes)
      if eventsPath.len > 0:
        ## Always written when a sink is configured, even with zero events: the
        ## summary row is how a reader tells "this match had none" from "the
        ## upload never happened".
        writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
        echo "Events written: ", eventsPath, " (", collectedEvents.len,
          " events)"
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults(sim.playerResultsJson() & "\n")
      elif saveScoresPath.len > 0:
        writeFile(saveScoresPath, sim.playerResultsJson() & "\n")
        echo "Scores written: ", saveScoresPath
      if metricsPath.len > 0:
        writeFile(metricsPath,
          $(%*{"ticks": sim.tickCount, "rounds": sim.roundLog.len}) & "\n")
      echo "physics-bodies: episode over — ", sim.endReason, "/", sim.endRule,
        " rounds ", sim.roundsWon[0], "-", sim.roundsWon[1], " at tick ",
        sim.tickCount
      ## EDIT 5 — bounded shutdown grace.
      let graceUntil =
        getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
      while getMonoTime() < graceUntil:
        sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    discard runFrameLimiter(lastTick,
      not replayLoaded and config.fastMode and sim.phase != Lobby,
      sockets, playerIndices, sim.seatCount())
