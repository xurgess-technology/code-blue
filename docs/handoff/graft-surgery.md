# Handoff: `graft-surgery` (grafting chunk C)

Slot wt-2. Written 2026-09-18 at the wrap-up. Two commits on top of `main`:

- `b209a6a` Eyeball Grafting: vat stands on every OR table, the graft, the eye and its glow
- `d4badd2` Review setups: drop straight into the graft (`--setup=graft`, `graft_back`)

The brief is [docs/GRAFTING.md](../GRAFTING.md), chunk C, plus Zach's decision that there is **no
dedicated player table**: you strap yourself to any free OR table, and every OR table has a **vat
stand** beside it. The contract note is in docs/CONTRACTS.md, "Grafting part one: the vat stands and
Eyeball Grafting".

## What is done and working

Everything in the chunk C brief, verified headless and in a smoke look:

- **The vat stand.** One beside every patient table (`Vats.stands`, built with the level on every
  machine, on the first of `STAND_OFFSETS` clear of the geometry). E with a carried vat sets it down
  (aim id `vatstand_<i>`, armed only while you carry one); picking it back up is the ordinary
  world-item pickup, so the stand holds a vat only for as long as someone leaves it there.
- **Eyeball Grafting** (`Procedures.AILMENTS.eye_graft`, four steps: scalpel `cut`, eye spoon
  `scoop`, eye spoon `seat`, suture kit `stitch`). It runs through `scripts/downed/player_surgery.gd`
  (which already stood in as a game for the player table's surgery system); `scripts/grafting/
  grafts.gd` owns the rules and the result. **No botching** (the case sets `no_fail`).
- **The refusals**, all on the table's own prompt: no vat on the stand, the vat is empty, the eye is
  spoiled, "X already has one", "X has two normal eyes", operating on yourself, not holding the
  scalpel, and "Nobody is strapped to this table" to someone holding a graft tool at a free table
  with a loaded vat on its stand.
- **The swap.** The `scoop` step is the moment it happens: the eye in the socket is packed into the
  vat on the stand and the vat's eye becomes the one going in. Never an empty socket.
- **Committed after the scoop.** `game.get_up_block` asks `player_surgery.graft_commit_block`, which
  refuses from step 2 on. Before that, holding E gets you up and clears the case.
- **Two new eye-minigame variants** in `eye_ops.gd`: `seat` (the scoop's rules run the other way --
  the new eye sinks into the socket) and `stitch` (the cut's rules over an already-open wound: it
  closes behind the needle and stitch marks appear). New ctx knobs `no_fail`, `eye_kind`,
  `eye_kind_in`, `eye_radius`, passed through by `surgery_system._spawn_mg` from the case's flags.
- **The eye on the body.** `scripts/grafting/graft_eye.gd` builds the `surgeon_graft` look at
  runtime (there is no such GLB in the game): `Human_Eye_L` is hidden and a Hive eyeball with the
  item's own shader is hung on the head's BoneAttachment3D with a ring of stitches. It follows every
  clip and shows in third person, on other players' screens, in the carry camera and in the mirrors.
- **The glow** is a new `instance uniform float lock` on the eye shader (0 a low pinpoint, 1 the
  whole ball lit). `Grafts` eases it to 1 while that player's `hive_view` is on, which is already
  replicated, so every machine agrees.
- **The ability.** Finishing the graft calls `brains.set_level(peer, "hive_in", 1)` (next free slot,
  new-ability card); swapping back calls the new `brains.clear_ability`, which empties the slot,
  zeroes the points and ends any Hive Eyes view. The graft lasts the run through death and
  `grafts.on_reset()` clears it on a game over.
- **Hive brains teach nothing now.** `Brains.blendable` is false for `brain_hive`; the blender
  refuses it and `drink` ignores it. Echo, the Discharged brains and the blender are untouched.
- **The first-person tell**: `scripts/grafting/graft_view.gd` (`main.graft_view`), an orange wash
  down the LEFT edge, stronger while Hive Eyes runs. **It is its own CanvasLayer at 52, above the
  look pass's grade (layer 50)** -- under it (where the HUD lives) a faint orange on a teal picture
  disappears completely, which cost an hour to find.
- **The awake patient's camera.** `Player._strapped_look` clamps a strapped surgeon's head to a cone
  about the rest pose (about +/-66 degrees of yaw, 26-86 degrees of pitch): enough to follow the
  surgeon round the table, not enough to spin the camera through your own chest.
- **Body parts are named "X's Y" everywhere** (the coordinator's mid-task rename): "Hive's eyeball",
  "Zach's eyeball", across `Eyes.label`, the loot table, the wall entries, the prompts, grafttest and
  the contracts note. `Eyes.NOUN` and `Grafts.PART_ABILITY` are the seams a trachea slots into later
  (docs/GRAFTING_TRACHEA.md) without a rewrite.
- **Co-op**: nettest scenario `graft` (host grafts a Hive eyeball into a client's surgeon; the other
  client checks the graft, the swapped eye on the body with `Human_Eye_L` hidden, and the glow while
  Hive Eyes runs). **Written but never run** -- see below.
- **DESIGN.md**: the Hive row now says what you harvest, the lab-wall paragraph mentions the vat
  benches and the stands, the blender bullet says Hive brains teach nothing, and there is a new
  "Grafting" section. **docs/CONTRACTS.md**: the chunk C section above.
- **Warmup**: the vat stand, a lying body wearing the grafted eyeball and the `eye_graft` steps'
  minigames all build in `scripts/warmup.gd`.

## Half-done or unverified

- **The nettest `graft` scenario has never been run.** `tools/nettest_run.gd` has its row
  (2 clients, 400 s). It compiles, but nothing has exercised it; expect to have to nudge timings.
- **`orscreentest` was never finished.** It is a full playtest shift and it wedged twice; the first
  time was my own fault (a stale grafttest process in the same checkout -- the CLAUDE.md parallel-run
  gotcha), the second time it just ran long and I killed it at the wrap-up. **I did not touch the OR
  screen**; `eye_graft` is `player_only`, so it never reaches `patient_ailments()` or a patient
  table's panel. Worth one clean run before merging, but I do not expect it to fail.
- The `graft_back` setup applies the graft with `grafts.apply` before any body exists to show it; the
  eye does appear (the setup shot's prompt offers your own eyeball back), but I never looked at that
  body up close.

## Zach's feedback so far, and what is still open

Zach has not seen the graft yet -- he closed the windows before reviewing and asked for review setups
instead. What came through the coordinator and is **done**: the "X's Y" rename, the vat stand on every
OR table (there is no player table), keeping the graft generic for a second part kind, removing only
the Hive-brain route to Hive Eyes, and the `--setup=` skeleton with a `graft` and a `graft_back` setup.

**Still open, to put in front of him:** the whole feel of it -- the four steps' pacing, the stand's
model (it reads a bit like an IV pole), how strong the left-edge tint should be
(`graft_view.gd` `ALPHA`/`WIDTH`), how far the strapped head should be allowed to turn
(`Player.LYING_LOOK_YAW` / `LYING_LOOK_PITCH`), and whether the grafted face reads in the mirror
(your own torch never lights your own body, so the eye reads mostly as its glow).

## What I was about to do next

Open the review window with the new setup and stop. Then: run the nettest `graft` scenario, and one
clean `orscreentest`.

## How to test it

```
tools\review.bat 2 "GRAFT: as Botsworth, give yourself a Hive eye, then check the mirror" --setup=graft --dev
tools\review.bat 2 "GRAFT: swap your own eyeball back in" --setup=graft_back --dev
```

Both drop straight into a solo shift (no menu, no lobby): the phone is quiet, no monsters, no game
over. You are strapped to a free OR table with a vat on its stand, already driving Dr. Botsworth
beside your own head with the scalpel, the eye spoon and the suture kit. Aim at the table and press E
for each of the four steps (hold the right tool: 1/2/2/3). F1 -> "Back to my own body", hold E to get
up, then walk to Personnel and look in the big mirror. Alt shows the ability bar with Hive Eyes 1.

Smoke-look shots: `tools\review.bat 2 "SMOKE" -Scene res://tools/graftsurgeryshot.tscn` writes the
whole loop into `tools/graft_shots/`, and `-Scene res://tools/setupshot.tscn --setup=graft` writes
`tools/game_shots/setup_graft.png`.

## Tests

Run one at a time in this checkout (`--fixed-fps 60`), newest results:

| Test | Result |
|---|---|
| `tools/grafttest.tscn` | **PASS** (0 failures) -- chunk A plus the whole chunk C graft section: the stands, every refusal, all four steps with Dr. Botsworth operating, Hive Eyes 1 in and out, and not getting up after the scoop |
| `tools/downedtest.tscn` | **PASS** (0 failures) |
| `tools/straptest.tscn` | **PASS** (0 failures) |
| `tools/orscreentest.tscn` | **SKIPPED** (see above; unrelated to this branch as far as I can tell) |
| nettest `graft` | **NOT RUN** |

Nothing in docs/FAILING_TESTS.md was touched or fixed.

## Known risks

- **The stand's placement is geometry-dependent.** It takes the first of five offsets around the
  table that a box query finds clear, so on a cramped table it can land on the far side. It is
  deterministic (every machine runs the same query on identical geometry), but it is not *designed*
  placement.
- **`Player.stand_in`** is new and is what stops a strapped surgeon's own body drawing on top of the
  lying stand-in (without it you get two overlapping faces, which the smoke look caught). It is set
  from the case on every machine by `player_surgery._refresh_stand_in` and read by both
  `refresh_downed_visuals` and `_refresh_self_body`. Anything else that shows a local body has to
  respect it.
- **The graft rides `game.player_table`**, which on the hub follows `strap_table`. A level with a
  player table of its own has no table index, so `Grafts.vat_for` falls back to the stand nearest the
  table top (`Vats.nearest_stand`, 4 m). Only the hub is exercised.
- **`grafts.apply` is host-only** and the state rides the snapshot as `"gf"`; clients never write it.
- **Renderer errors in the `--setup=` boot path**: that path logs about 8
  `BUG, indexing did not unpair geometries from light` errors. A normal windowed boot that builds the
  same hospital and renders it (`tools/gameshot.tscn`, same seed) logs **zero**, so it is the setup
  boot (`prebuild_level` + `begin_shift` + settling frames), not normal play. Harmless as far as the
  picture goes, but it is the shared skeleton's, not this branch's.
