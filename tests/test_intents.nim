## 6. Strict order parsing and the RUNE discipline.

import std/[json, strformat, strutils, unicode]
import bodies/[sim, intents]
import helpers

var failures = 0
template check(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    inc failures

proc checkRejected(text: string, message: string) =
  var raised = false
  try:
    discard parseIntentReply(text)
  except IntentError:
    raised = true
  check raised, message

let base = defaultIntent()

# --- valid canonical 9-key JSON reply -----------------------------------
block:
  let a = parseIntentReply(
    """{"note":"closing in","stance":"lift","aim":"foe","bearing_deg":0,"aggression":9,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":"under it"}""")
  check a.stance == stanceLift, "valid reply stance was not parsed"
  check a.aim == aimFoe, "valid reply aim was not parsed"
  check a.aggression == 9, "valid reply aggression was not parsed"
  check a.say == "under it", "valid reply say was not parsed"
  check a.note == "closing in", "valid reply note was not parsed"

block:
  let simple = parseIntentReply("```json\n{\"stance\":\"brace\",\"note\":null}\n```")
  check simple.stance == stanceBrace and simple.aim == aimFoe and simple.source == isLlm,
    "stance-only model order did not apply"
  check simple.note == "" and simple.aggression == 7, "optional defaults were lost"
  let plainFence = parseIntentReply("```\n{\"stance\":\"circle\"}\n```")
  check plainFence.stance == stanceCircle, "plain fenced JSON order did not parse"
  let tightFence = parseIntentReply("```JSON{\"stance\":\"retreat\"}```")
  check tightFence.stance == stanceRetreat, "tight fenced JSON order did not parse"
  checkRejected("""{"stance":"charge","aim":"bearing"}""", "missing selected bearing")
  checkRejected("""prose {"stance":"brace"}""", "prose was scraped")
  checkRejected("prose\n```json\n{\"stance\":\"brace\"}\n```", "prose before fence was scraped")
  checkRejected("""{"stance":"brace"} {"stance":"lift"}""", "multiple orders were scraped")
  var rawErr = ""
  try:
    discard parseIntentReply("I will brace now.\n```json\n{\"stance\":\"brace\"}\n```")
  except IntentError as err:
    rawErr = err.msg
  check rawErr.contains("I will brace now."),
    "rejected reply error did not preserve bounded raw output: " & rawErr

# --- strict rejection of shims, aliases, unit conversions, and repairs --
block:
  checkRejected(
    """{"note":"","stance":"push","aim":"foe","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "synonym stance \"push\" was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"hold","aim":"foe","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "synonym stance \"hold\" was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"center","aim":"foe","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "alias stance \"center\" was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"charge","aim":"center","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "alias aim \"center\" was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"charge","aim":"foe","bearing_deg":0,"aggression":80,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "out-of-range percentage aggression 80 was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"charge","aim":"bearing","bearing_deg":2.4,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "radian float bearing_deg 2.4 was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"charge","aim":"foe","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":0.5,"circle_dir":1,"say":""}""",
    "fractional seconds lead_ticks 0.5 was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"charge","aim":"foe","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":"cw","say":""}""",
    "string circle_dir \"cw\" was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"charge","aim":"foe","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":0,"say":""}""",
    "circle_dir 0 was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"pirouette","aim":"foe","bearing_deg":0,"aggression":5,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "unknown stance \"pirouette\" was accepted instead of rejected")
  checkRejected(
    """{"note":"","stance":"charge","aim":"foe","bearing_deg":-10,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""",
    "negative bearing_deg was accepted instead of rejected")
  check parseIntentReply("""{"stance":"brace","bearing":0}""").stance == stanceBrace,
    "unrelated input obscured an actionable stance"
  checkRejected("""{"weather":"fine"}""",
    "unrelated JSON object was accepted")
  checkRejected("I am afraid I cannot do that.",
    "reply with no JSON object was accepted")

# --- a 300-character note is cut to 160 RUNES ---------------------------
block:
  let long = repeat("a", 300)
  let a = parseIntentReply(
    """{"note":"""" & long & """","stance":"charge","aim":"foe","bearing_deg":0,"aggression":7,"posture_bias":"auto","lead_ticks":4,"circle_dir":1,"say":""}""")
  check a.note.runeLen == MaxNoteRunes,
    &"a 300-character note became {a.note.runeLen} runes, want {MaxNoteRunes}"

# --- THE 4-BYTE EMOJI ON THE SAY BOUNDARY -------------------------------
block:
  let say = repeat("x", 47) & "\u{1F980}\u{1F980}" & "tail"
  check say.runeLen > MaxSayRunes, "the emoji fixture is not over the cap"
  let cut = truncateRunes(say, MaxSayRunes)
  check cut.runeLen == MaxSayRunes,
    &"the rune cut produced {cut.runeLen} runes, want {MaxSayRunes}"
  check cut.validateUtf8() == -1,
    "the rune cut produced invalid UTF-8 — it landed mid-codepoint"
  check cut.endsWith("\u{1F980}"),
    "the rune cut did not keep the whole 4-byte codepoint"
  var intent = base
  intent.note = say
  intent.say = cut
  let record = boundedIntentRecord(intent, 3, 0, 0)
  check record.runeLen <= MaxIntentRunes,
    &"the intent record is {record.runeLen} runes, cap {MaxIntentRunes}"
  let node = parseJson(record)
  check node["say"].getStr().validateUtf8() == -1,
    "the recorded say is not valid UTF-8"
  check ($node).validateUtf8() == -1,
    "the serialized record is not valid UTF-8"

# --- sanitizeSay strips control records' leading brace -----------------
block:
  check sanitizeSay("{not a record}") == "not a record",
    "sanitizeSay did not strip the braces a control record is told apart by"
  check sanitizeSay("caf\u00e9 \u2014 ok").len > 0,
    "sanitizeSay dropped everything from a non-ASCII line"

# --- the record vocabulary is bounded ----------------------------------
block:
  let detail = repeat("z", 500)
  let record = policyFailureRecord(4, 1, "timeout", detail)
  let node = parseJson(record)
  check node["detail"].getStr().runeLen <= MaxFallbackDetailRunes,
    "policy_failure.detail is over its rune cap"
  check node["cause"].getStr() == "timeout", "policy_failure.cause was lost"
  let reg = parseJson(registerRecord(0, 1, repeat("p", 200), "llm", ""))
  check reg["policy"].getStr().runeLen <= MaxPolicyLabelRunes,
    "register.policy is over its rune cap"
  check not reg.hasKey("prompt"),
    "the register record leaked the seat's PROMPT into the replay"

if failures > 0:
  quit("test_intents: " & $failures & " failure(s)", 1)
echo "test_intents: ok"
