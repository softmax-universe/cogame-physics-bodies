# Writing a bug order

A policy is just a prompt. Every **1.5 seconds** (36 ticks) your seat is asked
what its bug does next, and a deterministic autopilot runs that order 24 times a
second: it steers, it leads a moving target, and it keeps you off the rim unless
you tell it not to. You choose **what** to do and **how hard**.

## The reply

One JSON object and nothing else. Your reply MUST begin with `{`.

```json
{"note": "it is low and braced; circle to put the rim behind it before I commit",
 "stance": "circle", "aim": "foe", "bearing_deg": 0,
 "aggression": 5, "posture_bias": "even", "lead_ticks": 4, "circle_dir": 1,
 "say": "walking it to the edge"}
```

## Stances

| stance | what the autopilot does |
|---|---|
| `charge` | drive into the other bug where it WILL be in `lead_ticks`, and shove. The bread and butter. |
| `brace` | plant LOW facing the other bug and absorb. You barely move, you take less tilt, and a bug that charges a brace bounces. |
| `circle` | orbit the other bug at about 1.40 m in `circle_dir`, trying to end up with the rim behind IT and the centre behind YOU. |
| `lift` | close and get under it — the knockdown attempt. Slow, and it loads tilt onto you too. |
| `retreat` | back toward the ring centre, away from the other bug. |
| `centre` | walk to the ring centre and hold it. Wins a decision. |

## Fields and strict validation

| Field | Type | Legal values |
|---|---|---|
| `note` | string | required, **≤ 160 runes** (truncated on rune boundary) |
| `stance` | string | required, exact canonical enum `charge, brace, circle, lift, retreat, centre` |
| `aim` | string | required, exact canonical enum `foe, centre, bearing` |
| `bearing_deg` | integer | required, `0..359` |
| `aggression` | integer | required, `0..10` |
| `posture_bias` | string | required, exact canonical enum `low, even, high, auto` |
| `lead_ticks` | integer | required, `0..24` |
| `circle_dir` | integer | required, `-1` or `1` |
| `say` | string | required, **≤ 48 runes** (truncated on rune boundary, printable ASCII, braces stripped) |

Three further caps on strings that reach the replay: `register.policy` ≤ 48
runes, any recorded failure text ≤ 200 runes, and the whole serialized `intent`
record ≤ 480 runes. `PLAYER_PROMPT` is capped at 4000 runes inside the player
container and is never sent to the game server or written to the replay or
results.

**Truncation is on rune (Unicode codepoint) boundaries, never bytes.** Slicing a
string by byte index anywhere on the path to the replay is forbidden: a
byte-truncated multi-byte character renders in a browser and then fails a strict
UTF-8 parser.

## Strict parsing and terminal policy failure

No field is repaired, aliased, clamped, or borrowed from a previous turn. Any
missing key, unexpected key, wrong type, out-of-range number, synonym, unit
conversion, unavailable endpoint, timeout, disconnect, or provider error
terminates the episode as an explicit policy failure via
`COGAME_PLAYER_FAILURE_URI` with **no substitute move** and **no published
scores**. Failed attempts are preserved in private trajectory evidence
(`COGAME_SAVE_TRAJECTORY_URI`).

## What the autopilot does with your order

1. **Aim point.** `aim: "foe"` → the other bug's position plus its velocity
   times `lead_ticks`; `"centre"` → the ring centre; `"bearing"` → 4 m along
   `bearing_deg` from where you stand.
2. **Goal bearing** from the stance (see the table above).
3. **The rim guard, always, every stance.** The closer you are to the rim, the
   more the goal bearing is blended toward the ring centre. The distance it
   measures is where you will be, not where you are: your outward speed adds a
   stopping distance (`v² / 8 000`, the ~4 000 µm/tick² a braking bug gets), so
   a bug sprinting at the rim is turned before it arrives rather than after.
   **At `aggression: 10` the guard is HALVED** — you may push yourself out.
   That is the trade, and it is the only way to order an all-in push.
4. **Posture.** `low`/`even`/`high` are taken literally. `auto` resolves as:
   `lift` stance and in contact → `lift`; `brace` stance → `low`; more than
   1.20 m apart → `high`; in contact → `low`; else `even`. The rim guard
   overrides to `low` when it is dominating.
5. **Effort**, continuous then duty-cycled: `3 × aggression / 10`, times 0.35
   for a `brace` that is not in contact, zero for a `brace` at a standstill, and
   tapered to zero inside 0.30 m of the goal for `centre` / `retreat`. **Inside
   the guard band the guard is a brake, not just a steer**: effort is floored at
   `3 × guard weight`, however low your `aggression` is, because pointing a
   coasting bug inward with no thrust to arrest it does not keep it in the ring.
   At `aggression: 10` that floor is halved with the guard, so the trade in
   step 3 still holds.
6. **Quantise** to the nearest of the 16 drive bearings and pack the byte.

## Two worked prompts

Both champions in this coworld are prompt policies. Their whole strategy is the
text below.

### `physics-bodies-ringcraft` — win on position, not on violence

```
Win on position, not on violence. Read dist_to_rim for BOTH bugs every turn and
treat the difference as the score of the fight: whoever is closer to the rim is
losing, whatever the round tally says.
Rules, in order. If YOUR dist_to_rim is under 0.60 m, stance "retreat" with aim
"centre" and aggression 8 for one turn - nothing else matters, you are one shove
from losing the round. Otherwise, if the other bug's dist_to_rim is under 0.90 m
AND you are in contact, stance "charge" with aim "foe", aggression 10,
lead_ticks 2, posture_bias "auto": this is the ring out and it is worth the
halved rim guard.
```

### `physics-bodies-toppler` — win by putting it on its back

```
Win by putting it on its back. Three knockdowns takes the round outright and a
downed bug cannot push, so every fall is also a free shove toward the rim.
Rules, in order. If YOUR tilt_pct is above 55, stance "brace", posture_bias
"low", aggression 3 for one turn and let your legs recover it. Otherwise, if the
other bug is DOWN (its down_ticks above 0), stance "charge", aim "foe",
aggression 10, lead_ticks 0: you have about a second of free pushing, spend all
of it driving it at the nearest rim.
```

## Field your own

```bash
coworld upload-policy coworld-physics-bodies:latest --name my-bug \
  --run /bin/physics-bodies-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Or run one of the published scripted baselines instead:
`PLAYER_SCRIPTED=pusher` (charge, shove whoever is nearer the rim, lift on
contact, back off the edge) or `PLAYER_SCRIPTED=anchor` (hold the middle, brace,
never initiate).
