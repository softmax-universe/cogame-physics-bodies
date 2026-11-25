## The order schema: what a policy (LLM or scripted) may say, and strict
## validation of every reply.
##
## Both policy kinds emit the SAME object, so one validator covers both — that
## is what makes the bounded-orders test in tests/test_baselines.nim meaningful
## and a scripted baseline legal by construction.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary (`runeLen` / `runeSubStr`).
## Slicing a string by BYTE index anywhere on the path to the replay is
## forbidden: a byte-truncated multi-byte character renders fine in a browser
## and then fails a strict UTF-8 parser.

import std/[json, strutils, unicode]
import sim_types

type
  Stance* = enum
    stanceCharge = "charge"
    stanceBrace = "brace"
    stanceCircle = "circle"
    stanceLift = "lift"
    stanceRetreat = "retreat"
    stanceCentre = "centre"

  Aim* = enum
    aimFoe = "foe"
    aimCentre = "centre"
    aimBearing = "bearing"

  PostureBias* = enum
    biasLow = "low"
    biasEven = "even"
    biasHigh = "high"
    biasAuto = "auto"

  IntentSource* = enum
    isLlm = "llm"
    isScripted = "scripted"

  BugIntent* = object
    ## One seat's tactical order for the next K = 36 ticks. The deterministic
    ## controller compiles it into a command byte 24 times a second.
    note*: string              ## <= MaxNoteRunes
    stance*: Stance
    aim*: Aim
    bearingDeg*: int           ## 0 .. 359, read only when aim is `bearing`
    aggression*: int           ## 0 .. 10
    postureBias*: PostureBias
    leadTicks*: int            ## 0 .. 24
    circleDir*: int            ## -1 or +1
    say*: string               ## <= MaxSayRunes, sanitized; spectators only
    source*: IntentSource
    latencyMs*: int

  IntentError* = object of ValueError

proc defaultIntent*(): BugIntent =
  ## Initial zero-state holder before the first Playing turn begins.
  BugIntent(
    stance: stanceCharge, aim: aimFoe, bearingDeg: 0, aggression: 7,
    postureBias: biasAuto, leadTicks: 4, circleDir: 1, source: isScripted)

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single place
  ## any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A bug's spectator line: capped at MaxSayRunes on a rune boundary FIRST,
  ## then run through the printable-ASCII shout filter. That order matters —
  ## the rune cut never leaves half a codepoint for the ASCII filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    ## Braces are excluded deliberately: the replay chat stream tells a CONTROL
    ## record from a bug's line by a leading '{', and a line that could start
    ## with one would make that discrimination ambiguous.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The policy's own reasoning line, as it reaches the replay and the feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc extractJsonObject*(text: string): JsonNode =
  ## The first valid balanced `{...}` JSON object in a model reply, tracking
  ## strings and escapes inside each `{...}` candidate so markdown fences,
  ## stray quotes, or extra `{...}` fragments in surrounding prose cannot
  ## corrupt extraction.
  for start in 0 ..< text.len:
    if text[start] != '{':
      continue
    var
      depth = 0
      inString = false
      escaped = false
    for i in start ..< text.len:
      let ch = text[i]
      if inString:
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
        continue
      case ch
      of '"': inString = true
      of '{': inc depth
      of '}':
        dec depth
        if depth == 0:
          try:
            let node = parseJson(text[start .. i])
            if node.kind == JObject:
              return node
          except CatchableError:
            discard
          break
      else: discard
  var head = text.strip()
  if head.runeLen > 160:
    head = head.truncateRunes(160) & "..."
  raise newException(IntentError,
    "no JSON object in reply: " & head.replace("\n", " "))

proc requireField(payload: JsonNode, key: string): JsonNode =
  if not payload.hasKey(key):
    raise newException(IntentError, "missing required field: " & key)
  payload[key]

proc requireIntInRange(payload: JsonNode, key: string, lo, hi: int): int =
  let node = requireField(payload, key)
  if node.kind != JInt:
    raise newException(IntentError, key & " must be an integer")
  let v = node.getBiggestInt()
  if v < int64(lo) or v > int64(hi):
    raise newException(IntentError,
      key & " out of range (" & $lo & ".." & $hi & "): " & $v)
  int(v)

proc requireString(payload: JsonNode, key: string): string =
  let node = requireField(payload, key)
  if node.kind != JString:
    raise newException(IntentError, key & " must be a string")
  node.getStr()

proc parseStanceStrict*(text: string): Stance =
  for stance in Stance:
    if $stance == text:
      return stance
  raise newException(IntentError, "invalid stance: " & text)

proc parseAimStrict*(text: string): Aim =
  for aim in Aim:
    if $aim == text:
      return aim
  raise newException(IntentError, "invalid aim: " & text)

proc parsePostureBiasStrict*(text: string): PostureBias =
  for bias in PostureBias:
    if $bias == text:
      return bias
  raise newException(IntentError, "invalid posture_bias: " & text)

proc parseIntentObject*(payload: JsonNode,
                        requireTextFields = true): BugIntent =
  ## Strictly validates one JSON order object against the published schema.
  ## No field is repaired, defaulted from a previous turn, aliased, or clamped.
  ## Any missing key, unknown key, wrong type, or out-of-range value raises
  ## `IntentError`.
  if payload.isNil or payload.kind != JObject:
    raise newException(IntentError, "reply is not a JSON object")

  const AllowedKeys = [
    "note", "stance", "aim", "bearing_deg", "aggression",
    "posture_bias", "lead_ticks", "circle_dir", "say"
  ]
  for key, _ in payload:
    if key notin AllowedKeys:
      raise newException(IntentError, "unexpected field: " & key)

  result.source = isLlm
  result.latencyMs = 0
  result.stance = parseStanceStrict(requireString(payload, "stance"))
  result.aim = parseAimStrict(requireString(payload, "aim"))
  result.bearingDeg = requireIntInRange(payload, "bearing_deg", 0, 359)
  result.aggression = requireIntInRange(payload, "aggression", 0, 10)
  result.postureBias = parsePostureBiasStrict(requireString(payload, "posture_bias"))
  result.leadTicks = requireIntInRange(payload, "lead_ticks", 0, 24)
  let circleDir = requireIntInRange(payload, "circle_dir", -1, 1)
  if circleDir notin [-1, 1]:
    raise newException(IntentError, "circle_dir must be -1 or 1")
  result.circleDir = circleDir

  if requireTextFields or payload.hasKey("note"):
    result.note = sanitizeNote(requireString(payload, "note"))
  else:
    result.note = ""

  if requireTextFields or payload.hasKey("say"):
    result.say = sanitizeSay(requireString(payload, "say"))
  else:
    result.say = ""

proc parseIntentReply*(text: string): BugIntent =
  parseIntentObject(extractJsonObject(text), requireTextFields = true)

proc intentAction*(intent: BugIntent): JsonNode =
  ## The normalized policy response, excluding replay and transport metadata.
  %*{"note": intent.note, "stance": $intent.stance, "aim": $intent.aim,
    "bearing_deg": intent.bearingDeg, "aggression": intent.aggression,
    "posture_bias": $intent.postureBias, "lead_ticks": intent.leadTicks,
    "circle_dir": intent.circleDir, "say": intent.say}

proc intentJson*(intent: BugIntent, turn, seat, body: int): JsonNode =
  ## The replay chat record for one turn's intent. Re-applied at playback into
  ## NON-HASHED fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  %*{
    "k": "intent",
    "turn": turn,
    "seat": seat,
    "alias": alias(body),
    "body": body,
    "source": $intent.source,
    "latency_ms": intent.latencyMs,
    "note": intent.note,
    "stance": $intent.stance,
    "aim": $intent.aim,
    "bearing_deg": intent.bearingDeg,
    "aggression": intent.aggression,
    "posture_bias": $intent.postureBias,
    "lead_ticks": intent.leadTicks,
    "circle_dir": intent.circleDir,
    "say": intent.say
  }

proc boundedIntentRecord*(intent: BugIntent, turn, seat, body: int): string =
  ## The serialized intent record, guaranteed <= MaxIntentRunes. The note is
  ## the only unbounded-in-practice field, so it is the one that shrinks; the
  ## cut still lands on a rune boundary. NEVER cut the serialized string —
  ## that would emit broken JSON, which is the exact failure the rune rule
  ## exists to prevent.
  var trimmed = intent
  result = $trimmed.intentJson(turn, seat, body)
  var guard = 0
  while result.runeLen > MaxIntentRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $trimmed.intentJson(turn, seat, body)

proc registerRecord*(seat, body: int, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's PROMPT is never written:
  ## only the policy label, the kind, and which baseline a scripted seat chose.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias(body),
    "body": body,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc policyFailureRecord*(turn, seat: int, cause, detail: string): string =
  $(%*{
    "k": "policy_failure",
    "turn": turn,
    "seat": seat,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc roundRecord*(round, winner: int, reason: string, ticks: int,
                  knockdowns: array[BodyCount, int32]): string =
  ## LOAD-BEARING: `bankRound` applies this identically on record and on
  ## playback, so it is written for every completed round.
  $(%*{
    "k": "round",
    "round": round,
    "winner": winner,
    "reason": reason,
    "ticks": ticks,
    "knockdowns": [int(knockdowns[0]), int(knockdowns[1])]
  })

proc stopRecord*(tick: int, cause: string): string =
  ## LOAD-BEARING (the particle-worlds 13c66d7 fix).
  $(%*{"k": "stop", "tick": tick, "cause": cause})
