# Handoff: `sono-model` (the Sonographer's model, chunk A)

Branch `sono-model`, built in slot `wt-3`. Chunk A of [docs/SONOGRAPHER.md](../SONOGRAPHER.md): the
model, the stretching neck, the probe hand, the clips and the look interface chunk B drives it
through. Nothing about hunting, the echo's wedge, the rename, sounds or networking is here.

The branch history has two dead ends in it (a cart version, then a one-model-with-cart version)
because the brief was rewritten twice. **The tip is the only thing that matters**: the diff against
`main` has no cart code in it at all.

## What is done and working

- **The model.** `assets/models/monsters/sonographer/sonographer_st.glb`, 25.5k triangles, built
  from `art/stylized/` (variant `sonographer`, clips `st_sono_clips.py`). A blind doctor in old
  tattered whites: a long yellowed coat torn at one shoulder with a chunky tattered hem, a stained
  shirt with the collar open and the tie pulled loose, frayed trousers, scuffed shoes. Grey-pink
  skin under a wet gel sheen, gel drips at the fingers and chin.
- **The face** is smooth blank skin where the eyes were: no sockets, no pads, no seam, no brow
  ridge, nothing eye-shaped in the geometry or the paint. Ears, nose and a wide mouth only.
- **The neck is the suspicion meter.** The shared skeleton's neck bone is cut into a chain of four
  (`st_build.add_neck_bones`) and `sonographer_rig.gd` stretches it by up to 0.6 m as `suspicion`
  rises, unfolding it out of its hunch. The windpipe and the see-through skin over it ride the same
  chain, so the violet rings pull apart as it cranes. **The bottom bone never moves**, so the
  collar, the shoulders and the torso stay put and only the head rises.
- **`crane_limit`** below 1 trades height for reach: the neck bends forward instead of standing up,
  so the head never goes through a ceiling. The brain does the raycast; the model obeys the number.
- **The probe** is grown into the right palm with the grip through the middle of the hand and the
  fingers closed round it; three runs of cable go up the arm into the side of the neck, and the
  charge lights the throat, then each run in turn, then the probe, so it reads as running out to
  the wand. `echo_origin()` is at the tip, `-Z` the way it points.
- **The echo burst**: the jaw is thrown wide and rings of violet light fly out of the mouth and off
  the probe with a flash behind them (`SonoRig.fire_echo()`, fired automatically the first frame
  `mode` becomes `"echo"`).
- **Ten clips**: idle, wander (0.8 m/s), listen, charge, echo, rush (3.1 m/s), wail (with its
  listening pauses), search, stagger, lying. The crane is never a clip.
- **The review stage**, `tools/sono_lab.tscn`: see below.

## The look interface

The whole surface between the model and chunk B. Written up in
[docs/CONTRACTS.md](../CONTRACTS.md) under "The Sonographer's model"; in short:

```gdscript
model.set_sono_look(suspicion, charge, mode, aim, crane_limit)
model.echo_origin()          # Transform3D at the probe's tip, -Z the way it points
model.sono.crane()           # 0..1, what the neck is actually doing this frame
model.sono.fire_echo()       # the burst, if B wants it on an exact frame
model.set_ears(listen, yaw, delta)
model.play("idle"/"walk"/"listen"/"charge"/"echo"/"run"/"attack"/"search"/"stagger"/"lying", rate, blend)
```

`set_sono_look` is safe on any model: every other look ignores it, so B can call it while it is
still driving the old Discharged. Whichever chunk merges second hooks them together; nothing in
chunk A knows the monster's kind beyond `MonsterModel.setup("sonographer")`.

## How to look at it

```
tools\review.bat 3 "SONOGRAPHER: the model, the neck crane, and the charge" -Scene res://tools/sono_lab.tscn
```

from the **main checkout's** `tools\` (the slot's own copy resolves its paths wrong). It opens
straight into a plain lit box with the Sonographer in front of a fixed camera, head to toe with
headroom for the craned neck, looping every clip with a caption naming it and the interface's
values, and walking a little to each side between rounds. No menu, no waiting, nothing that depends
on the hospital, a player, a navmesh or warmup. If the model ever fails to build, the room says so
in red instead of looking empty.

`-- --capture` writes what the window is actually showing to `tools/monster_shots/cap_*.png` at 5,
15, 30, 45 and 60 s.

`tools/monster_lab.tscn -- --sono` still walks it through the clips in the corridor, and
`-- --shots --only=sono_*` renders the fourteen `sono_*` stills.

## What Zach reported, and where it stands

He could not see it in the review window twice. Both causes were in the review path, not the model:

1. The walkthrough used the corridor, and the wander and rush clips actually translate while the
   watcher stands still, so within seconds it had walked past the camera. A capture caught it at
   x=27.4 with the camera at x=24.6 facing away.
2. `--sono` never made the watcher's camera current (the shots path did), so the window drew through
   whatever camera happened to be current.

Both are fixed, and the corridor is no longer the review scene: `tools/sono_lab.tscn` exists so
this cannot happen again.

Then he asked for seven changes. All seven are in:

| # | What | Confidence |
|---|---|---|
| 1 | The shirt tucks into the trousers | Good: it stops at the waist and the band sits outside it |
| 2 | No eyes, smooth blank face | Good: nothing eye-shaped left in geometry or paint |
| 3 | Only the neck extends, not the torso | Good: the bottom neck bone is pinned |
| 4 | The torso stays under the shirt's collar | Good, but the collar is a tight fit; worth a look up close |
| 5 | The shoulder joins | **Least sure.** The first attempt made a flat coat-hanger shelf; the second (a fat blend, cloth stopping lower, a shallower collar V) reads better in the stills but has not been looked at in every clip |
| 6 | It looks like it is holding the wand | **Least sure.** The grip now runs through the palm and the fingers curl 1.15 round it, but it still reads small at arm's length; check it in the charge and the wail |
| 7 | The echo opens the mouth and throws visible effects | **Unverified live** (see below) |

## Unverified

- **The echo burst has not been seen live.** The code path runs without error and the model loops
  through the echo step in the stage, but every capture I took from the *minimized* review window
  froze on one frame, so I never got a still of the rings actually flying. First thing to check on
  the next machine: open the window and watch the echo step.
- The fourteen `sono_*` stills in `monster_lab -- --shots` were last rendered against the version
  before the seven fixes; they will need re-rendering.
- Nothing has been through `tools/style_lab` (it only handles `art/stylized/out`'s surgeon
  variants); the in-game look was reviewed through the stage and `monster_lab` shots instead.

## Tests

- `godot --headless --path . --fixed-fps 60 tools/monster_lab.tscn` — **109 checks, 0 failed**, run
  after the seven fixes.
- No other suite was touched. The three failures in [docs/FAILING_TESTS.md](../FAILING_TESTS.md) are
  unrelated and were not revisited.
- The full sweep (playtest shifts, `nettest_run.gd`) has **not** been run on this branch.

## Risks and things I am unsure of

- **The skin reads paler than the grey-pink in the brief** under the stage's lights; it may want
  taking down a shade.
- **The gel** reads as gloss rather than as drips at any distance; the drip pieces are small.
- **The wail's listening pauses** may be too short to be a way out; they are two gaps in a 3.2 s
  clip and want playing against a real player.
- **Every number is a first guess**: 0.6 m of crane, the hunch, the head's cock, the ears' rest, the
  charge glow's ramp, the burst's 0.75 s. All of them are tuning, not contract.
- **The neck chain is the one place this model leaves the shared skeleton.** Anything that assumes
  one `neck` bone will need to know: `neck`, `neck2`, `neck3`, `neck4`, then `head`.
- `MonsterModel.make_lying("sonographer")` resets the chain to rest length, so the table and
  dragging get a normal-necked body. That path is exercised by the `sono_lying` shot but not by any
  headless check.

## Files

| Where | What |
|---|---|
| `art/stylized/st_char.py` | the `sonographer` variant, its head, throat, hands, probe, cable, gel and clothes |
| `art/stylized/st_build.py` | `add_neck_bones`, the neck-chain weights, the review shots and `set_crane` |
| `art/stylized/st_export.py` | the loose pieces, the budgets and the sites |
| `art/stylized/st_sono_clips.py` | the ten clips |
| `scripts/monsters/sonographer_rig.gd` | the crane, the glow, the ears, the wet skin, the echo burst |
| `scripts/monsters/monster_model.gd` | `set_sono_look`, `echo_origin`, the lying path |
| `shaders/sono_glow.gdshader` | the throat, cable and probe glow |
| `tools/sono_lab.tscn` / `.gd` | the review stage |
| `tools/monster_lab.gd` | the `--sono` walkthrough and the `sono_*` shots |

Rebuild the model with:

```
blender --background --factory-startup --python art/stylized/st_build.py -- --only=sonographer --export
godot --headless --path . --import
```

about 9 minutes on this machine.
