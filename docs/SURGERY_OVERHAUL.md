# The surgery overhaul

Brief for the orchestrator. Agreed with Zach on 2026-09-18 (theory session). This is big, so it
comes in phases. This file has the overview, the decisions, and detailed briefs for **phases 0
and 1**. Phases 2 to 5 get their own detailed briefs once 0 and 1 are in and Zach has played them;
don't start them from the outlines here.

## Why

The Hive's Eyeball Extraction (`scripts/surgery/games/eye_ops.gd`) is what surgery should feel
like: you operate on the real body part, with a real tool you lower by clicking, one simple action
per step, a camera framed for that step, and very little on-screen glow. The old steps
(anesthetic, forceps, tourniquet, saw, gauze, stitches) are puzzles laid over a body: glowing
green, amber and red rings on a flat work plane, over an old-style Bob. Zach's problems with them:

- **The bright, glowing things.**
- **You can't tell when you're doing something right or wrong,** and there's little feedback in
  general.
- **The saw slides straight into the side of the limb** instead of cutting into it.

**The old steps are replaced from a clean slate, not rebuilt.** Each old step is deleted when its
replacement lands. Until then it keeps working.

## Decisions (locked by Zach)

- **Only the two existing procedures** (gunshot wound, amputation) are redone. No new ailments.
- **Steps can be added, split or rethought** if it makes the procedure more immersive.
- **No two-person steps** for now.
- **Each step is its own session:** walk up with the step's item selected, press E, the camera
  moves in, do the step, the camera pulls out, and the body visibly shows what you did.
- **Tools only appear once you press E.** Nothing floats over the patient before that.
- **The camera adapts to each step,** and follows the work where it has to (the orbit round the
  arm).
- **Onlookers see a headlamp beam in the operator's player colour,** not animation.
- **New operating tables:** big articulated steel tables that move the patient into each step's
  pose.
- **Bob becomes the players' surgeon model in a gown** (for now). **The seal is rebuilt** in the
  stylized style.
- **A syringe item.** You fill it anywhere, not at a table. A filled syringe is what sedates a
  patient and what you jab a monster with.
- **Difficulty has to rise over a run;** how is designed in phase 5.

## The feedback language (every step)

No glowing rings or targets. Everything reads in the world, at three levels:

| | Seen | Heard |
|---|---|---|
| **Right** | The tool moves freely; the body does what it should (the cut opens cleanly, the bleeding slows); the patient stays calm | Clean, satisfying sounds (a crisp slice, ratchet clicks, a metal *tink*); a steady monitor beep |
| **Going wrong** (a warning, time to correct) | The tool drags and resists; the patient twitches or groans; the skin pulls tight | The sound strains; the monitor beep quickens |
| **Wrong** (a mistake) | A clear event: blood spurts, the patient jolts, the vitals number on the OR monitor drops | A harsh sting and a monitor alarm chirp, plus one short line saying why |

- **Every finished action gets a payoff beat:** the bullet plinks into the dish, a stitch pulls the
  skin shut, the limb thunks into the bin, the tool lifts away.
- **The heart monitor is the constant meter.** Every table's monitor beeps, positional: steady is
  fine, fast means you're hurting them, an alarm means a mistake.
- **Where to work is shown the way a real surgeon marks it:** the matte violet skin marker (dashes
  and hash ticks), already used by the saw and the eye steps. Anything else you look for is
  physical, like the bullet catching the light.
- **Slips cost nothing.** Moving too fast lifts the tool off (click to lower it again, as in the eye
  steps). Only real mistakes cost vitals.
- **One short hint line** on screen per step, as today. No gauges.

## The step flow

1. Select the step's item and aim at the patient's table. E starts the step: your surgeon's
   headlamp comes on, the camera glides in to the step's shot, and the tool appears at the site.
2. Do the step.
3. Finish: the tool lifts away, the camera glides back out, the table moves the patient into the
   next step's pose, and the body shows the result (the incision, the stitches, the dressing, the
   arm gone). All of it replicated.
4. E or Esc leaves mid-step and keeps the progress, as today.

## Cameras

- **Each step has its own framed shot,** chosen for its action: straight down into a wound, low
  along the blade for the saw, close on the vein for the needle, the low side view the eye snip
  already uses.
- **The camera glides** into, out of and between shots (about 0.5 s). It never cuts.
- **Within a step it may follow the work,** but never so that the thing you're aiming at moves out
  from under you. **The ring cut round a limb:** the blade stays near the middle of the screen and
  the camera orbits the limb as the cut advances, so the uncut marking keeps rolling toward you
  like a lathe. Your movement is measured along the marking, not in screen space, so the orbit
  never throws your aim. The table's raised arm board keeps the limb clear all round so the camera
  can pass under it.
- **Only the operator's camera moves.** Onlookers are never moved.

## What onlookers see

- **A headlamp beam in the operator's player colour,** from their forehead to the site, like the
  grab beam in R.E.P.O. The site is lit where it lands. It tells everyone who's operating, and in a
  dark OR it's a beacon (to friends and monsters alike).
- **The tool, floating at the site in the beam,** moving the way the operator moves it (today's
  surgery already sends the tool's position to other machines).
- **The operator's body holds one still pose:** leaning over the table, arms forward. No per-action
  animation, no IK.
- **Everything that happens to the body:** cuts, blood, gauze soaking, the bullet in the dish, the
  limb in the bin. **Sounds are positional:** the rasp, the grind, the monitor speeding up.

## The syringe

- **A new item, the syringe:** reusable, like the forceps; a surgery tool. The anesthetic vial stays
  the consumable. Its icon is drawn: `art/icons/items/syringe.svg` (and `bare/syringe.svg`).
- **Fill it anywhere:** with a syringe selected and an anesthetic vial in your slots, press E. A
  close-up camera opens **right in front of you** (no table needed), with the syringe and vial in
  your hands. You can't move while filling, and E or Esc leaves.
  - Push the needle into the vial's rubber top (click).
  - Pull the plunger back (hold and drag) to the dose you want. The barrel has printed marks.
  - Air bubbles form; tap the barrel to knock them up and push them out.
  - **Right:** the liquid sits on your line, no bubbles, and the needle comes out with a small
    click. **Wrong:** you pull past the mark (push some back) or leave air in (it counts as a worse
    dose).
  - Filling uses one anesthetic from the vial stack.
- **A filled syringe carries its dose,** and the slot shows it ("Syringe, 8 ml"). Using it empties
  it.
- **The patient's dose is on their chart:** a clipboard at the foot of each patient table ("Bob,
  90 kg: 8 ml"; the seal needs more), readable by aiming at it. The OR monitor repeats it.
- **Sedating a patient** is a table step that needs a filled syringe (phase 2).
- **Jabbing a monster needs a filled syringe** too. The dose decides how long it stays under (up to
  that monster's need, which the database lists once it's scanned).

## The operating tables

- **Big, heavy steel surgical tables** on a thick column, in sections: head, back, legs, and two
  arm boards that swing out.
- **The table moves the patient into each step's pose,** with a motor whine and a clunk: the back
  tilts up so a chest wound faces the lamp; an arm board swings out and rises for the amputation
  (the raised holder the ring cut and the saw need); the whole table rises or turns a little.
- **The table moving between steps is part of the "something happened" beat.**
- **Every patient table in the OR** gets the new table (monsters are strapped to them too), and the
  **player table** is the same style. Grafting's vat stand stays attached beside each table.
- The chart clipboard hangs at the foot.

## Phases

| Phase | What | Detailed brief |
|---|---|---|
| **0. Foundations** | The step flow, cameras, feedback kit, headlamp beam, the new tables. Proven by porting one existing step. | Below |
| **1. Bodies** | Bob on the surgeon model; the seal rebuilt. | Below |
| **2. Anesthesia** | The syringe, filling it anywhere, the chart, the sedate step; monster jabs with a filled syringe. | Later |
| **3. Gunshot wound** | Open, clear, pull, close, dress. | Later |
| **4. Amputation** | Tourniquet, the ring cut, the saw in its own kerf, taking the limb off, close. | Later |
| **5. Difficulty** | Tighter tolerances over a run, and a pool of complications written on the chart. | Later |

**The procedures as designed so far** (for phases 2 to 4; not a spec yet):

- **Gunshot wound:** sedate (a filled syringe into the raised vein; a flash of blood into the hub
  means you're in; push until breathing slows and the eyelids droop; overdose turns the lips
  blue) → open (the scalpel traces the marking and the skin parts) → clear (dab the blood with
  gauze until the bullet shows; it refills with each heartbeat) → pull (the forceps tink on metal,
  grip, draw out slowly while the flesh stretches; too fast tears; it pops free into the dish) →
  close (stitches that tug the skin shut) → dress (a gauze pad pressed on and taped).
- **Amputation:** sedate → tourniquet (place the strap above the marking; on the infection they
  scream; twist the windlass until the pulse at the wrist stops; too far and it goes purple) → cut
  the skin (a ring round the limb, the orbiting camera) → saw (long strokes in its own kerf: a
  rasp, then a grind through bone with dust; rushing judders and jumps) → take it off (lift the
  limb away and drop it in the bin) → close (stitch the stump).

**Phase 5 direction:** tolerances tighten as shifts go on (slips come sooner, blood refills
faster, patients stir more), and from shift 2 each surgery rolls 0 to 2 **complications** from a
pool, written on the chart: a bleeder to clamp, a bullet in two fragments, brittle bone, a light
sleeper, a blackout (headlamp only). The pool gets designed after phases 3 and 4 have been played.

---

## Phase 0: Foundations (detailed)

**Start after grafting part one's chunk C is merged** (it's changing `eye_ops.gd` and the tables
now).

### 0A. `surgery-core`: the step flow, cameras, feedback kit, headlamp (Opus, high)

- **The step flow** above, in `scripts/surgery/`: E to start with the step's item selected, the
  tool spawned only in-step, the camera glide in and out, a result that the body shows, leaving
  mid-step keeps progress. Keep the host-authoritative shape the surgery system has now (the
  operator's machine runs the step and reports to the host).
- **The camera rig:** per-step shots defined by the step (a site-relative position and target),
  glides between them, and an **orbit mode** a step can drive (around an axis, by progress along a
  path), per the rules above. Operator only.
- **The feedback kit,** a shared toolbox every new step uses: the three-level cues (the patient's
  flinch, twitch, groan and jolt; the tool dragging; strain sounds; mistakes with a sting, a
  monitor chirp and a reason line), the payoff beat, the violet marker as a reusable piece, and
  **the heart monitor** as a per-table, positional sound whose rate follows the patient's state.
  Sounds generated with `tools/gen_audio.mjs`.
- **The headlamp beam:** while a player operates, a beam in their player colour from their head to
  the site, the site lit, the tool shown floating at the site on every machine, the operator's
  body in one still leaning pose.
- **Prove it by porting the eye steps** (`eye_ops.gd`: cut, scoop, snip) onto the new framework,
  so there's a real step to judge it by and no new content is needed. The old steps keep working
  on the old path until their phases replace them.
- **Zach sees:** `SURGERY: take a Hive's eye with the new flow, and watch someone else do it`
  (`-Count 2`).

### 0B. `or-tables`: the new operating tables (orchestrator's call on the model; code Sonnet, high)

- The articulated steel table (model: Godot primitives in the style of the current props, or
  Blender-from-Python in the stylized style; the orchestrator decides), with its sections and arm
  boards, the chart clipboard at the foot, and grafting's vat stand beside it.
- **Poses:** named table poses (flat, back up, left or right arm board out and raised, raised, and
  so on) that a step can ask for, animated with a motor whine and a clunk, replicated. The patient
  body follows the pose (the torso on the back section, an arm on the arm board).
- Replaces every patient table and the player table in the OR. The old steps must still work on it
  until they're replaced. Monsters strap to it as today.
- **Zach sees:** `TABLES: the new OR tables, cycling through their poses`.

0A and 0B can run at the same time. 0A's eye-step port uses the new table once 0B is merged (the
eye steps need no special pose).

### Done when (phase 0)
- The eye steps run on the new framework, on the new table, with glides, the feedback kit and the
  headlamp; another player sees the beam, the tool and the results.
- Every other old step still works.
- A nettest scenario covers a step on the new framework seen from a second machine.

---

## Phase 1: Bodies (detailed)

Art in the stylized kit (`art/stylized/README.md`, DESIGN.md › Art style). Can start any time.

### 1A. `patient-bob`: Bob on the surgeon model (orchestrator's call; Blender-from-Python work)

- **Bob is the players' surgeon body in a hospital gown:** stiff, chunky, tied at the back, with
  panels that open over the procedure sites. Bald like the surgeons; a patient's wristband.
- **Sites for close-up surgery:** `injection` (a raised vein on the forearm, readable up close),
  `gunshot` (a wound on the chest or shoulder, deep enough to open), `limb` (upper arm, for the
  tourniquet) and `limb_cut` (the amputation line).
- **The arm splits at the cut line:** the arm below `limb_cut` is its own piece, so it can come off
  whole, and there's a stump cap for after. The infection shows on it (the look the body has now).
- **What the feedback needs from him:** eyelids that droop and close (sedation), a chest that rises
  and falls (breathing that slows), lips that can go blue (overdose), flinch and jolt poses, and
  his arm lying correctly on a raised arm board.
- **Zach sees:** `BOB: the new Bob, gowned, sites open, arm on and off`.

### 1B. `patient-seal`: the seal rebuilt (orchestrator's call; Blender-from-Python work)

- The harbor seal in the stylized style: chunky, simple, figurine-like, heavier than Bob.
- The same sites (the flipper for `limb` and `limb_cut`), **the flipper splitting off** at the cut
  line with a stump cap, the infection, and the same feedback needs (eyelids, breathing, a colour
  change for overdose, flinches).
- Replaces the seal model everywhere it shows (the gurney, the table, being carried).
- **Zach sees:** `SEAL: the new seal, sites open, flipper on and off`.

### Done when (phase 1)
- Both patients arrive, lie on the tables and go through today's (old) steps without breaking.
- The paramedics' gurney, the carry and the furnace all still work with the new bodies.
- Front, side, face and in-game shots reviewed, as the art style rules require.

Update DESIGN.md (Surgery minigames, Patients, the OR) and docs/CONTRACTS.md (Surgery, Patient
body) as each phase lands.
