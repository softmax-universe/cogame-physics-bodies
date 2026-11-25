## The physics-bodies player container.
##
## Two explicit modes — never an implicit default:
##   Model mode:    COWORLD_LLM_ENABLED=true (or non-empty PLAYER_PROMPT)
##                  Calls COWORLD_LLM_ENDPOINT (hosted sidecar) or
##                  ANTHROPIC_API_KEY on each decision_request from the game
##                  server and returns the raw model reply + attempt evidence.
##   Scripted mode: PLAYER_SCRIPTED=pusher | anchor
##                  Registers the explicit scripted baseline; makes zero LLM
##                  calls and requires no model route.
##
## Optional:
##   PLAYER_PROMPT        operator strategy guidance (model mode only; never
##                        sent to the game server or written to replays)
##   PLAYER_POLICY_LABEL  free label for the replay's `register` record

import std/[json, monotimes, options, os, strutils, times]
import bitworld/spriteprotocol
import curly
import whisky
import bodies/[sim_types, intents, llm, training_capture]

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24     ## ~1 s of frames at 24 Hz.
  ReconnectAttempts = 6

proc registrationBlob(mode, scripted, policy: string): string =
  var node = %*{"type": "register", "mode": mode, "policy": policy}
  if mode == "scripted":
    node["scripted"] = %scripted
  blobFromSpriteChat($node)

proc readyBlob(): string =
  result = newString(1)
  result[0] = char(0x85)

proc handleDecisionRequest(client: LlmClient, prompt, label: string,
                           payload: JsonNode): string =
  let
    turn = payload{"turn"}.getInt(-1)
    tick = payload{"tick"}.getInt(0)
    seat = payload{"seat"}.getInt(0)
    system = payload{"system"}.getStr()
    obsJson = $payload["observation"]
    deadlineMs = max(1000, payload{"deadline_ms"}.getInt(TurnBudgetMsDefault))
    user = userMessage(prompt, obsJson)
    attemptId = $tick & "-" & $seat & "-1"

  if client.isNil or client.disabled or client.transport == ltNone:
    var evidence = newDecisionAttempt(attemptId, label, aoModel)
    evidence.model = some(if client.isNil: DefaultSidecarModel else: client.requestedModel())
    evidence.prompt = %*[
      {"role": "system", "content": system},
      {"role": "user", "content": user}
    ]
    let detail = "LLM endpoint unavailable (COWORLD_LLM_ENDPOINT / ANTHROPIC_API_KEY unset)"
    evidence.rejectionReason = some(detail)
    return $(%*{
      "type": "decision_response",
      "turn": turn,
      "cause": "unavailable_endpoint",
      "error": detail,
      "latency_ms": 0,
      "attempt": attemptEvidenceJson(evidence)
    })

  let request = client.requestFor(system, user, seat)
  var batch: RequestBatch
  batch.post(request.url, request.headers, request.body, $seat)
  let started = getMonoTime()
  let responses = client.curl.makeRequests(batch, max(1, deadlineMs div 1000))
  let latency = (getMonoTime() - started).inMilliseconds.int
  let resp = responses[0]
  var evidence = modelAttempt(attemptId, label, client.requestedModel(),
    request.url, request.body, resp.response, resp.error, latency)
  try:
    let text = client.textOf(resp.response, resp.error, request.url)
    evidence.response = %text
    return $(%*{
      "type": "decision_response",
      "turn": turn,
      "reply": text,
      "latency_ms": latency,
      "attempt": attemptEvidenceJson(evidence)
    })
  except CatchableError as error:
    evidence.rejectionReason = some(error.msg)
    var cause = "provider_error"
    if resp.error.len > 0:
      cause = (if "timeout" in resp.error.toLowerAscii():
                 "timeout" else: "transport_error")
    elif error.msg.startsWith("llm throttled"):
      cause = "throttled"
    return $(%*{
      "type": "decision_response",
      "turn": turn,
      "cause": cause,
      "error": error.msg,
      "latency_ms": latency,
      "attempt": attemptEvidenceJson(evidence)
    })

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)

  let
    llmEnabled = getEnv("COWORLD_LLM_ENABLED").strip().toLowerAscii() == "true"
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip().toLowerAscii()
    wantsModel = llmEnabled or prompt.len > 0

  if wantsModel and scripted.len > 0:
    quit("physics-bodies player: cannot set both model mode (COWORLD_LLM_ENABLED/PLAYER_PROMPT) and PLAYER_SCRIPTED", 1)
  if not wantsModel and scripted.len == 0:
    quit("physics-bodies player: set COWORLD_LLM_ENABLED=true (or PLAYER_PROMPT) for model mode, or PLAYER_SCRIPTED=pusher|anchor for scripted mode", 1)
  if not wantsModel and scripted notin ["pusher", "anchor"]:
    quit("physics-bodies player: invalid PLAYER_SCRIPTED=" & scripted & " (expected pusher or anchor)", 1)

  let
    mode = if wantsModel: "model" else: "scripted"
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif wantsModel: "model"
      else: scripted
    llmClient = if wantsModel: newLlmClient() else: nil

  echo "physics-bodies player: mode=", mode,
    (if mode == "scripted": " baseline=" & scripted else: " transport=" & $llmClient.transport & " model=" & llmClient.requestedModel()),
    " label=", label

  proc dial(attempts: int): WebSocket =
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "physics-bodies player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("physics-bodies player: game never accepted a connection", 1)
  echo "physics-bodies player: connected"

  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(mode, scripted, label), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue
        let msg = received.get()
        if msg.kind == TextMessage:
          var node: JsonNode = nil
          try:
            node = parseJson(msg.data)
          except CatchableError:
            node = nil
          if not node.isNil and node.kind == JObject and
              node{"type"}.getStr() == "decision_request" and mode == "model":
            let reply = handleDecisionRequest(llmClient, prompt, label, node)
            socket.send(reply, TextMessage)
          continue
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(mode, scripted, label), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "physics-bodies player: socket closed (", error.msg, ")"
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "physics-bodies player: re-dialling the seat (attempt ", reconnects,
      ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "physics-bodies player: game is no longer listening, exiting cleanly"
      break
    echo "physics-bodies player: reconnected, re-registering"
  quit(0)
