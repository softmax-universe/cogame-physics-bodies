## 7. The turn loop and server failure contract, against a FAKE LLM provider.
##
## Proves:
## - Both seats' calls go out in ONE PARALLEL BATCH per turn (`curly.makeRequests`).
## - Timeout, HTTP 429, invalid JSON/schema, and unavailable endpoint all fail
##   explicitly with NO substitute move installed.
## - Registration parsing is strict (`mode: "model"` or `mode: "scripted"`).
## - Lobby no-show declares `COGAME_PLAYER_FAILURE_URI` and writes NO results.json.
## - Out-of-order slot connect (slot 1 before slot 0) is held and completes cleanly.

import std/[json, locks, monotimes, options, os, strformat, strutils, times]
import curly
import mummy
from whisky import nil
import bitworld/runtime
import bitworld/spriteprotocol
import bodies/[sim, intents, control, baselines, llm, decide, replays, prompts]
import bodies/server as gameServer
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

type Window = object
  startMs, endMs: int64

const ValidReply =
  """{"note":"fake","stance":"lift","aim":"foe","bearing_deg":0,"aggression":9,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":"under it"}"""

var
  fakeLock: Lock
  windows: seq[Window]
  fakeDelayMs = 60
  fakeStatus = 200
  fakeBody = ValidReply
  epoch = getMonoTime()
  fakeEpoch = 0

initLock(fakeLock)

proc nowMs(): int64 = (getMonoTime() - epoch).inMilliseconds

proc fakeHandler(request: Request) {.gcsafe.} =
  let started = nowMs()
  var delay, status, requestEpoch: int
  var body: string
  {.gcsafe.}:
    withLock fakeLock:
      delay = fakeDelayMs
      status = fakeStatus
      body = fakeBody
      requestEpoch = fakeEpoch
  sleep(delay)
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  let payload =
    if status == 200:
      $(%*{"stop_reason": "end_turn",
           "content": [{"type": "text", "text": body}]})
    else:
      body
  {.gcsafe.}:
    withLock fakeLock:
      if requestEpoch == fakeEpoch:
        windows.add Window(startMs: started, endMs: nowMs())
  request.respond(status, headers, payload)

proc noWebsocket(ws: WebSocket, event: WebSocketEvent, message: Message)
    {.gcsafe.} =
  discard

let server = newServer(fakeHandler, noWebsocket, workerThreads = 4)
var serverThread: Thread[void]
proc serveProc() {.thread.} =
  {.gcsafe.}:
    server.serve(Port(8791), "127.0.0.1")
createThread(serverThread, serveProc)
server.waitUntilReady()

let server2 = newServer(fakeHandler, noWebsocket, workerThreads = 4)
var serverThread2: Thread[void]
proc serveProc2() {.thread.} =
  {.gcsafe.}:
    server2.serve(Port(8792), "127.0.0.1")
createThread(serverThread2, serveProc2)
server2.waitUntilReady()

putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:8791")
putEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")

proc freshEngine(sim: SimServer, prompts = true): DecisionEngine =
  result = initDecisionEngine(sim, PromptSelection())
  for seat in 0 ..< BodyCount:
    result.seats[seat].registered = true
    result.seats[seat].isLlm = prompts
    result.seats[seat].prompt = "be decisive"
    result.seats[seat].label = "fake"

type GameServerArgs = object
  cfg: GameConfig
  runtime: RuntimeConfig
  port: int

var
  gameThread: Thread[GameServerArgs]
  gameThread2: Thread[GameServerArgs]

proc gameServeProc(args: GameServerArgs) {.thread.} =
  {.gcsafe.}:
    try:
      runServerLoop("127.0.0.1", args.port, args.cfg, "", "", "",
        args.runtime)
    except CatchableError as error:
      echo "game server loop ended: ", error.msg

proc playingSim(): SimServer =
  var cfg = defaultMatchConfig()
  cfg.attempt1Ms = 2000
  cfg.retryMs = 2000
  cfg.turnBudgetMs = 4000
  cfg.turnSpacingMs = 0
  result = initSimServer(cfg)
  result.gameEventLoggingEnabled = false
  result.phase = Playing
  for seat in 0 ..< BodyCount:
    discard result.addPlayer("seat-" & $seat, seat, "")

# --- ONE PARALLEL BATCH per turn ---------------------------------------
block:
  withLock fakeLock:
    windows.setLen(0)
    inc fakeEpoch
    fakeDelayMs = 120
    fakeStatus = 200
    fakeBody = ValidReply
  var sim = playingSim()
  var engine = freshEngine(sim)
  let outcome = engine.turn(sim, 0, 0)
  check not outcome.failure.failed,
    "valid turn unexpectedly failed: " & outcome.failure.detail
  var captured: seq[Window]
  withLock fakeLock:
    captured = windows
  check captured.len == 2,
    &"one turn issued {captured.len} provider requests, want exactly 2"
  for seat in 0 ..< BodyCount:
    check engine.haveIntent[seat], &"seat {seat} got no intent"
    check engine.intents[seat].source == isLlm,
      &"seat {seat} did not record an LLM intent"
    check engine.intents[seat].stance == stanceLift,
      "the provider's reply was not parsed into the intent"

block:
  let source = readFile(repoFile("src/bodies/decide.nim"))
  check source.contains("makeRequests("),
    "decide.nim does not call curly's batch API"
  check not source.contains(".makeRequest("),
    "decide.nim issues a per-seat request — seats must NEVER be queried sequentially"
  var batchCalls = 0
  for line in source.splitLines():
    if line.contains("makeRequests("):
      inc batchCalls
  check batchCalls == 1,
    &"decide.nim calls makeRequests {batchCalls} times; want exactly one batch"

block:
  withLock fakeLock:
    windows.setLen(0)
    inc fakeEpoch
    fakeDelayMs = 200
    fakeStatus = 200
    fakeBody = ValidReply
  var cfg = defaultMatchConfig()
  let client = newLlmClient(cfg)
  var batch: RequestBatch
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  batch.post("http://127.0.0.1:8791/v1/messages", headers, "{}", "0")
  batch.post("http://127.0.0.1:8792/v1/messages", headers, "{}", "1")
  discard client.curl.makeRequests(batch, 5)
  var captured: seq[Window]
  withLock fakeLock:
    captured = windows
  check captured.len == 2,
    &"the batch produced {captured.len} in-flight windows, want 2"
  if captured.len == 2:
    let intersects = captured[0].startMs < captured[1].endMs and
      captured[1].startMs < captured[0].endMs
    check intersects,
      &"the batch's two calls did NOT overlap in flight"

# --- consecutive batches are >= turnSpacingMs apart --------------------
block:
  withLock fakeLock:
    windows.setLen(0)
    inc fakeEpoch
    fakeDelayMs = 10
    fakeStatus = 200
    fakeBody = ValidReply
  var sim = playingSim()
  sim.config.turnSpacingMs = 400
  var engine = freshEngine(sim)
  let started = getMonoTime()
  discard engine.turn(sim, 0, 0)
  discard engine.turn(sim, 1, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  check elapsed >= 400,
    &"two consecutive batches were {elapsed} ms apart, want >= 400"

# --- hung provider fails explicitly with NO substitute move ------------
block:
  withLock fakeLock:
    windows.setLen(0)
    inc fakeEpoch
    fakeDelayMs = 6000
    fakeStatus = 200
    fakeBody = ValidReply
  var sim = playingSim()
  var engine = freshEngine(sim)
  let started = getMonoTime()
  let outcome = engine.turn(sim, 0, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  check elapsed <= int64(sim.config.turnBudgetMs) + 3000,
    &"a hung provider held the turn for {elapsed} ms against a {sim.config.turnBudgetMs} ms budget"
  check outcome.failure.failed, "a hung provider did not trigger terminal failure"
  check outcome.failure.cause in ["timeout", "transport_error"],
    "a hung provider recorded cause " & outcome.failure.cause
  for seat in 0 ..< BodyCount:
    check not engine.haveIntent[seat],
      &"seat {seat} received a fabricated substitute intent after timeout"
  withLock fakeLock:
    fakeDelayMs = 10

# --- HTTP 429 fails explicitly with NO retry and NO substitute move ----
block:
  withLock fakeLock:
    windows.setLen(0)
    inc fakeEpoch
    fakeDelayMs = 10
    fakeStatus = 429
    fakeBody = "daily token cap"
  var sim = playingSim()
  var engine = freshEngine(sim)
  let outcome = engine.turn(sim, 0, 0)
  var captured: seq[Window]
  withLock fakeLock:
    captured = windows
    fakeStatus = 200
    fakeBody = ValidReply
  check captured.len == 2,
    &"a throttled turn issued {captured.len} requests, want 2 (no retry)"
  check outcome.failure.failed and outcome.failure.cause == "throttled",
    "a 429 did not fail with cause `throttled` (got " & outcome.failure.cause & ")"
  for seat in 0 ..< BodyCount:
    check not engine.haveIntent[seat],
      &"seat {seat} received a fabricated substitute intent after 429"

# --- invalid model reply fails explicitly with NO substitute move ------
block:
  withLock fakeLock:
    windows.setLen(0)
    inc fakeEpoch
    fakeDelayMs = 10
    fakeStatus = 200
    fakeBody = """{"stance":"push"}"""
  var sim = playingSim()
  var engine = freshEngine(sim)
  let outcome = engine.turn(sim, 0, 0)
  withLock fakeLock:
    fakeBody = ValidReply
  check outcome.failure.failed and outcome.failure.cause == "parse_error",
    "invalid reply did not fail with parse_error (got " & outcome.failure.cause & ")"
  for seat in 0 ..< BodyCount:
    check not engine.haveIntent[seat],
      &"seat {seat} received a fabricated substitute intent after invalid reply"

# --- unavailable endpoint fails explicitly with NO substitute move -----
block:
  delEnv("COWORLD_LLM_ENDPOINT")
  delEnv("ANTHROPIC_API_KEY")
  var sim = playingSim()
  var engine = freshEngine(sim)
  let outcome = engine.turn(sim, 0, 0)
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:8791")
  check outcome.failure.failed and outcome.failure.cause == "unavailable_endpoint",
    "unavailable endpoint did not fail with unavailable_endpoint (got " &
    outcome.failure.cause & ")"
  for seat in 0 ..< BodyCount:
    check not engine.haveIntent[seat],
      &"seat {seat} received a fabricated substitute intent with no endpoint"

# --- the WALL-CLOCK STOP: deadline/wall_clock, and the record ----------
block:
  var cfg = certConfig()
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  sim.roundTick = 100
  let record = stopRecord(sim.tickCount, "wall_clock")
  sim.applyWallClockStop(int32(sim.tickCount))
  check sim.endReason == ReasonDeadline and sim.endRule == EndRuleWallClock,
    &"the wall-clock stop ended {sim.endReason}/{sim.endRule}"
  check sim.phase == GameOver, "the wall-clock stop did not end the episode"
  check sim.roundLog.len == 1 and sim.roundLog[^1].reason == roundDraw,
    "the round in progress was not banked as a DRAW at the stop"
  let node = parseJson(record)
  check node{"k"}.getStr() == "stop" and node{"cause"}.getStr() == "wall_clock",
    "the `stop` record is malformed"

# --- a tripped invariant is fault/sim_fault, not a silent exit ---------
block:
  var cfg = defaultMatchConfig()
  var sim = initSimServer(cfg)
  sim.gameEventLoggingEnabled = false
  sim.phase = Playing
  var raised = 0
  sim.bodies[0].px = ArenaW + 1_000_000
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].px = RingCentreX
  sim.bodies[0].vx = MaxBodySpeedHard + 50_000
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].vx = 0
  sim.bodies[0].hMilli = 40_000
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].hMilli = 0
  sim.bodies[0].tipMilli = TipDown + 1
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].tipMilli = 0
  sim.bodies[0].groundedCount = 9
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.bodies[0].groundedCount = 4
  sim.roundTick = int32(sim.config.roundTicks + 3)
  try: sim.assertInvariants() except SimGuardError: inc raised
  sim.roundTick = 0
  check raised == 6,
    &"only {raised} of 6 invariant violations tripped the step-12 guard"
  sim.endReason = ReasonFault
  sim.endRule = EndRuleSimFault
  sim.phase = GameOver
  let results = parseJson(sim.playerResultsJson())
  check results["reason"].getStr() == "fault" and
    results["endRule"].getStr() == "sim_fault",
    "a faulted episode did not report fault/sim_fault"

# --- registrations are parsed strictly ---------------------------------
block:
  let modelReg = gameServer.parseRegistration(
    """{"type":"register","mode":"model","policy":"champ"}""")
  check modelReg.ok and modelReg.isLlm and modelReg.policy == "champ",
    "a valid model registration did not parse"
  let scriptedReg = gameServer.parseRegistration(
    """{"type":"register","mode":"scripted","scripted":"anchor","policy":"anch"}""")
  check scriptedReg.ok and not scriptedReg.isLlm and
    scriptedReg.scripted == blAnchor and scriptedReg.policy == "anch",
    "a valid scripted registration did not parse"
  check not gameServer.parseRegistration(
    """{"type":"register","prompt":"go","scripted":null,"policy":"legacy"}""").ok,
    "legacy prompt-only registration without mode was accepted"
  check not gameServer.parseRegistration(
    """{"type":"register","mode":"scripted","scripted":"unknown","policy":"x"}""").ok,
    "unknown scripted baseline was accepted"
  check not gameServer.parseRegistration("hello").ok,
    "a plain chat line was accepted as a registration"
  check not gameServer.parseRegistration("""{"type":"shout","text":"hi"}""").ok,
    "a non-register JSON object was accepted as a registration"

# --- a NEVER-CONNECTING seat: declared failure, NO results published ---
block:
  let
    workDir = tempPath("engine-noshow")
    failurePath = workDir / "player-failure.json"
    resultsPath = workDir / "noshow-results.json"
  createDir(workDir)
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & failurePath)
  var cfg = defaultGameConfig()
  cfg.seed = 5104773
  cfg.players = @[PlayerConfig(name: "BUG-1"), PlayerConfig(name: "BUG-2")]
  cfg.maxGames = 1
  cfg.maxRounds = 1
  cfg.roundsToClinch = 1
  cfg.roundTicks = 48
  cfg.resetTicks = 12
  cfg.maxTicks = 120
  cfg.turnTicks = 24
  cfg.turnSpacingMs = 0
  cfg.wallClockBudgetSeconds = 120
  cfg.lobbyJoinTimeoutTicks = 48
  cfg.startWaitTicks = 12
  cfg.gameOverTicks = 12
  cfg.fastMode = true
  createThread(gameThread, gameServeProc, GameServerArgs(cfg: cfg, port: 8794,
    runtime: RuntimeConfig(host: "127.0.0.1", port: 8794,
      resultsUri: "file://" & resultsPath)))

  var socket: whisky.WebSocket = nil
  for _ in 0 ..< 60:
    try:
      socket = whisky.newWebSocket("ws://127.0.0.1:8794/player?slot=0")
      break
    except CatchableError:
      sleep(100)
  check socket != nil, "seat 0 could not connect to the in-process server"
  if socket != nil:
    whisky.send(socket, blobFromSpriteChat($(%*{
      "type": "register", "mode": "scripted", "scripted": "pusher",
      "policy": "test-noshow-0"})), whisky.BinaryMessage)
    let deadline = epochTime() + 60.0
    while epochTime() < deadline and not fileExists(failurePath):
      try:
        if whisky.receiveMessage(socket, timeout = 250).isSome:
          whisky.send(socket, blobFromSpriteReady(), whisky.BinaryMessage)
      except CatchableError:
        break
    try: whisky.close(socket) except CatchableError: discard
  joinThread(gameThread)

  check fileExists(failurePath),
    "a never-connecting seat wrote no COGAME_PLAYER_FAILURE_URI artifact"
  if fileExists(failurePath):
    let declared = parseJson(readFile(failurePath))
    check declared{"failed_policy_index"}.getInt(-1) == 1,
      &"the no-show was charged to policy index " &
      $declared{"failed_policy_index"}.getInt(-1) & ", want 1"
  check not fileExists(resultsPath),
    "a no-show episode published results.json instead of terminating without scores"
  removeDir(workDir)

# --- SLOT 1 CONNECTS FIRST: held, not thrown away ----------------------
block:
  let
    workDir = tempPath("engine-slotorder")
    failurePath = workDir / "player-failure.json"
    resultsPath = workDir / "slotorder-results.json"
  createDir(workDir)
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & failurePath)
  var cfg = defaultGameConfig()
  cfg.seed = 5104773
  cfg.players = @[PlayerConfig(name: "BUG-1"), PlayerConfig(name: "BUG-2")]
  cfg.maxGames = 1
  cfg.maxRounds = 1
  cfg.roundsToClinch = 1
  cfg.roundTicks = 48
  cfg.resetTicks = 12
  cfg.maxTicks = 240
  cfg.turnTicks = 24
  cfg.turnSpacingMs = 0
  cfg.wallClockBudgetSeconds = 120
  cfg.lobbyJoinTimeoutTicks = 168
  cfg.startWaitTicks = 12
  cfg.gameOverTicks = 12
  cfg.fastMode = true
  createThread(gameThread2, gameServeProc, GameServerArgs(cfg: cfg, port: 8795,
    runtime: RuntimeConfig(host: "127.0.0.1", port: 8795,
      resultsUri: "file://" & resultsPath)))

  proc connectSeat(slot: int, label: string): whisky.WebSocket =
    result = nil
    for _ in 0 ..< 60:
      try:
        result = whisky.newWebSocket(
          "ws://127.0.0.1:8795/player?slot=" & $slot)
        break
      except CatchableError:
        sleep(100)
    if result != nil:
      whisky.send(result, blobFromSpriteChat($(%*{
        "type": "register", "mode": "scripted", "scripted": "pusher",
        "policy": label})), whisky.BinaryMessage)

  let high = connectSeat(1, "test-slotorder-1")
  check high != nil, "seat 1 could not connect to the in-process server"
  sleep(700)
  let low = connectSeat(0, "test-slotorder-0")
  check low != nil, "seat 0 could not connect to the in-process server"
  let deadline = epochTime() + 120.0
  while epochTime() < deadline and not fileExists(resultsPath):
    for socket in [low, high]:
      if socket == nil: continue
      try:
        if whisky.receiveMessage(socket, timeout = 120).isSome:
          whisky.send(socket, blobFromSpriteReady(), whisky.BinaryMessage)
      except CatchableError:
        discard
  for socket in [low, high]:
    if socket != nil:
      try: whisky.close(socket) except CatchableError: discard
  joinThread(gameThread2)

  check not fileExists(failurePath),
    "slot 1 connecting BEFORE slot 0 was declared a no-show"
  check fileExists(resultsPath),
    "an out-of-order two-seat lobby wrote no results"
  if fileExists(resultsPath):
    let results = parseJson(readFile(resultsPath))
    check results["reason"].getStr() == ReasonComplete,
      &"""an out-of-order lobby ended {results["reason"].getStr()}, want complete"""
    check results["rounds"].getInt() >= 1,
      "an out-of-order lobby banked no rounds"
  removeDir(workDir)

server.close()
joinThread(serverThread)
server2.close()
joinThread(serverThread2)

if failures > 0:
  quit("test_engine: " & $failures & " failure(s)", 1)
echo "test_engine: ok"
quit(0)
