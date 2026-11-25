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

proc previewReply(text: string): string =
  let cleaned = text.replace("\r", " ").replace("\n", " ").strip()
  if cleaned.len == 0:
    return "<empty>"
  if cleaned.runeLen > 120:
    return cleaned.truncateRunes(120) & "..."
  cleaned

proc extractJsonObject*(text: string): JsonNode =
  var value = text.strip()
  if value.len >= 6 and value.startsWith("```") and value.endsWith("```"):
    value = value[3 ..< value.len - 3].strip()
    if value.len > 4 and value[0 ..< 4].toLowerAscii() == "json" and
        (value[4].isSpaceAscii() or value[4] == '{'):
      value = value[4 .. ^1].strip()
  try:
    result = parseJson(value)
  except JsonParsingError:
    raise newException(IntentError,
      "expected one JSON order object; got: " & previewReply(text))
  if result.kind != JObject:
    raise newException(IntentError,
      "expected one JSON order object; got: " & previewReply(text))

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

proc parseIntentObject*(payload: JsonNode): BugIntent =
  template supplied(key: string): bool =
    payload.hasKey(key) and payload[key].kind != JNull

  result = defaultIntent()
  result.source = isLlm
  result.stance = parseStanceStrict(requireString(payload, "stance"))
  if supplied("aim"):
    result.aim = parseAimStrict(requireString(payload, "aim"))
  if result.aim == aimBearing or supplied("bearing_deg"):
    result.bearingDeg = requireIntInRange(payload, "bearing_deg", 0, 359)
  if supplied("aggression"):
    result.aggression = requireIntInRange(payload, "aggression", 0, 10)
  if supplied("posture_bias"):
    result.postureBias = parsePostureBiasStrict(requireString(payload, "posture_bias"))
  if supplied("lead_ticks"):
    result.leadTicks = requireIntInRange(payload, "lead_ticks", 0, 24)
  if supplied("circle_dir"):
    result.circleDir = requireIntInRange(payload, "circle_dir", -1, 1)
    if result.circleDir == 0:
      raise newException(IntentError, "circle_dir must be -1 or 1")
  if supplied("note"):
    result.note = sanitizeNote(requireString(payload, "note"))
  if supplied("say"):
    result.say = sanitizeSay(requireString(payload, "say"))

proc parseIntentReply*(text: string): BugIntent =
  parseIntentObject(extractJsonObject(text))

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
