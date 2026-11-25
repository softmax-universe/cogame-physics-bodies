## The decision layer: per-turn policy state and strict turn resolution.
##
## Scripted seats execute their declared baseline (`pusher` or `anchor`).
## Model seats must supply a valid JSON order matching the exact schema;
## missing credentials, transport errors, timeouts, disconnects, or invalid
## replies terminate the episode as an explicit policy failure with NO
## substitute action and NO published scores.

import std/[json, monotimes, os, strutils, times]
import curly
import sim, intents, control, baselines, llm, prompts, training_capture

type
  SeatPolicy* = object
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  TurnFailure* = object
    failed*: bool
    seat*: int
    cause*: string
    detail*: string

  DecisionEngine* = object
    capture*: RuntimeCapture
    selection*: PromptSelection
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    intents*: seq[BugIntent]
    haveIntent*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool

proc initDecisionEngine*(sim: SimServer, selection: PromptSelection): DecisionEngine =
  result.selection = selection
  result.capture = newRuntimeCapture("physics-bodies", sim.config.seed)
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState()
  result.seats = newSeq[SeatPolicy](BodyCount)
  result.intents = newSeq[BugIntent](BodyCount)
  result.haveIntent = newSeq[bool](BodyCount)
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blPusher
    result.seats[i].label = ""
    result.intents[i] = defaultIntent()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

proc viewFor*(engine: DecisionEngine, sim: SimServer, seat: int): SeatView =
  seatView(sim, seat,
    (if seat < engine.haveIntent.len: engine.haveIntent[seat] else: false),
    (if seat < engine.intents.len: engine.intents[seat] else: defaultIntent()))

proc scriptedFor*(engine: DecisionEngine, sim: SimServer, seat: int,
                  kind: Baseline): BugIntent =
  scriptedIntent(engine.ctl.params, engine.viewFor(sim, seat), kind)

proc installIntent*(engine: var DecisionEngine, seat: int,
                    intent: BugIntent) =
  if seat < 0 or seat >= engine.intents.len:
    return
  engine.intents[seat] = intent
  engine.haveIntent[seat] = true

proc intentForBody*(engine: DecisionEngine, sim: SimServer,
                    bodyIndex: int): BugIntent =
  ## The standing intent driving one bug. Only valid once every seat has an
  ## installed intent for the current Playing turn (during Lobby/RoundReset
  ## the command byte is unused).
  let seat = sim.seatOfBody(bodyIndex)
  if seat >= 0 and seat < engine.intents.len and engine.haveIntent[seat]:
    return engine.intents[seat]
  defaultIntent()

proc turn*(engine: var DecisionEngine, sim: SimServer, turnIndex: int,
           elapsedSeconds = 0): tuple[records: seq[string], failure: TurnFailure] =
  ## Runs ONE direct decision turn (used by in-process tests). Model seats
  ## are queried in one parallel batch; any unavailable endpoint, timeout,
  ## transport error, or invalid reply returns a terminal TurnFailure with NO
  ## substitute action installed.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
    seats = sim.seatCount()
  discard elapsedSeconds

  if engine.capture != nil:
    var observations: seq[JsonNode]
    for seat in 0 ..< engine.seats.len:
      observations.add(parseJson(seatViewJson(engine.viewFor(sim, seat))))
    engine.capture.beginTurn(observations)

  var open: seq[int]
  for seat in 0 ..< seats:
    if not engine.seats[seat].registered:
      let detail = "seat " & $seat & " did not register before turn " & $turnIndex
      result.records.add(policyFailureRecord(turnIndex, seat, "unregistered", detail))
      engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
      result.failure = TurnFailure(failed: true, seat: seat,
        cause: "unregistered", detail: detail)
      return
    if engine.seats[seat].isLlm:
      if engine.client.disabled or engine.client.transport == ltNone:
        let detail = "LLM endpoint unavailable for model seat " & $seat
        result.records.add(policyFailureRecord(turnIndex, seat, "unavailable_endpoint", detail))
        engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
        result.failure = TurnFailure(failed: true, seat: seat,
          cause: "unavailable_endpoint", detail: detail)
        return
      open.add(seat)
    else:
      var intent = engine.scriptedFor(sim, seat, engine.seats[seat].baseline)
      intent.source = isScripted
      engine.installIntent(seat, intent)

  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  if open.len > 0:
    let
      spentMs = (getMonoTime() - turnStart).inMilliseconds.int
      deadlineMs = max(1000, sim.config.turnBudgetMs - spentMs)
    if getMonoTime() - turnStart >= budget:
      let seat = open[0]
      let detail = "per-turn budget exhausted before request"
      result.records.add(policyFailureRecord(turnIndex, seat, "timeout", detail))
      engine.capture.recordFailedDecision(seat, sim.tickCount, asMissing)
      result.failure = TurnFailure(failed: true, seat: seat,
        cause: "timeout", detail: detail)
      return

    var batch: RequestBatch
    for seat in open:
      let user = seatViewJson(engine.viewFor(sim, seat))
      let request = engine.client.requestFor(
        systemPrompt(engine.selection), userMessage(engine.seats[seat].prompt, user), seat)
      batch.post(request.url, request.headers, request.body, $seat)

    let started = getMonoTime()
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int

    for position, seat in open:
      var cause = "parse_error"
      var evidence = modelAttempt($sim.tickCount & "-" & $seat & "-1",
        engine.seats[seat].label, engine.client.requestedModel(), batch[position].url,
        batch[position].body, responses[position].response, responses[position].error, latency)
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        evidence.response = %text
        var intent = parseIntentReply(text)
        intent.source = isLlm
        intent.latencyMs = latency
        engine.installIntent(seat, intent)
        evidence.parsedAction = intent.intentAction()
        evidence.accepted = true
        engine.capture.recordAttempt(seat, evidence)
      except CatchableError as error:
        evidence.rejectionReason = some(error.msg)
        engine.capture.recordAttempt(seat, evidence)
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        elif error.msg.startsWith("llm auth") or error.msg.startsWith("llm error") or
            error.msg.startsWith("llm refusal"):
          cause = "provider_error"
        let status = if cause in ["timeout", "transport_error", "throttled", "provider_error"]:
          asMissing else: asRejected
        engine.capture.recordFailedDecision(seat, sim.tickCount, status)
        result.records.add(policyFailureRecord(turnIndex, seat, cause, error.msg))
        if not result.failure.failed:
          result.failure = TurnFailure(failed: true, seat: seat,
            cause: cause, detail: error.msg)

  if result.failure.failed:
    return

  for seat in 0 ..< seats:
    let origin = if engine.intents[seat].source == isLlm: aoModel else: aoTeacher
    engine.capture.applied(seat, sim.tickCount, engine.intents[seat].intentAction(), origin,
      if origin == aoTeacher: "scripted-" & $engine.seats[seat].baseline else: engine.seats[seat].label)
