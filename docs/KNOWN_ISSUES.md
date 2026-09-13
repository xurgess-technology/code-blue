# Known issues

Open problems from the content sweep of 2026-09-12 (patients, items, containers, surgery,
guide, monsters). Nothing here breaks a shift; each is a feel, look or robustness problem to fix.
Integration testing of the sweep as a whole has not been done yet.

## Surgery and patients

- **Bob's gown pokes through the gunshot wound view.** Gown folds rise up to about 2 cm above the
  `gunshot` site plane and move with breathing; the forceps channel is lifted 2 to 2.9 cm to
  compensate, but a flap still shows through (`tools/lab_shots/forceps_finished.png`). Fix options:
  put the site on top of the local geometry, or let the forceps step hide the body's own wound
  visuals and gown locally.
- **A teammate's flashlight does not light the wound.** The forceps channel darkens every light by
  depth (down to 6% at the bullet), including other players' flashlights. The design wants a
  teammate's light to help. Needs an "extra light" input to the minigame or a different darkness
  approach.
- **Sloppy sawing is very slow.** A sloppy saw job takes about 45 s on Bob and 60 to 65 s on the
  seal. Raise the 0.25 per-pass progress floor in `scripts/surgery/games/saw.gd` if that plays badly.
- **Bob's amputation line sits at the infection edge.** `limb_cut` is only about 5 cm past `limb`,
  roughly where the infection starts, so the saw cuts through infected tissue instead of past it.
  Move the site in `scripts/patients/bob_builder.gd` (and check the tourniquet placement band).
- **The seal's infection shows in two styles.** The body's pink and green flipper infection is visible
  beyond the tourniquet minigame's own projected infection decal.
- **Minigames guess limb size.** Tourniquet, gauze and saw read the limb cross-section from the
  patient body's tourniquet and stump props (`parts["stump"]/Rim`, the Band node). Add a contract
  method such as `site_section(site) -> {half_up, half_side, shape}` and an infection-start distance
  on PatientBody, then switch the minigames to it.
- **No severed-limb hook.** Only the seal exposes `parts.limb_node`; Bob's forearm is part of a
  skinned mesh. The saw drops the seal's copy away and relies on the body for Bob. Add a contract hook.
- **Stirs are inferred.** The framework jolts the operator's cursor during a stir, and the forceps
  and tourniquet detect jolts from cursor jumps. A minigame `on_jolt(offset)` callback would be cleaner.
- **Sloppy sedation and stump wrap are a bit forgiving.** Sloppy anesthetic on the seal costs 11.9
  vitals and a sloppy stump wrap 14.0, slightly under the 15 to 25 target.

## Interface

- **HUD overlap while operating.** Probably fixed 2026-09-12: the whole HUD had a zero size
  (anchored full-rect without resetting offsets) and drew everything piled at the top-left.
  Re-check while operating.
- **Small guide tab labels at 1280x720.** Some index tabs shrink to about 10 px and long names
  drop words ("Gunshot wound" shows as "Gunshot").
- **Guide draws on canvas layer 60**, above the post-processing layer (50). Any HUD drawn above
  60 would appear over the book.

## Contract gaps to formalise in docs/CONTRACTS.md

- `PatientBody.apply_flags` replaces all flags rather than merging. The game always passes the full
  flag set, but the contract should say so.
- Minigames put their props on render layer 20 (and the forceps on layer 2) so projected decals
  skip them. Reserve a layer in the contract and keep cameras on the default cull mask.
- The surgery HUD contract has no cross-section widget; the saw returns `cross_section` in
  `hud_state()` which nothing draws yet.

## Level and tools

- **The OR supply shelf is about 4.2 m from the table** (the OR template has no wall closer that
  keeps doors clear). Fine for delivery, but it makes the surgeon walk.
- **3 of 200 generated maps have no pegboard**; on those the bone saw only spawns loose.
- **The minigame lab only produces two seeds** (one per patient). Add a `--seed` flag to
  `tools/minigame_lab.gd` so varied forceps channels and infection lines get exercised.
- **Monster playtests are weak.** Shift 1 has a single Discharged and the test bot rarely meets it;
  the Night Nurse only appears from shift 2. `tools/monster_lab.tscn -- --real --shift=N` is the
  better monster check.
- **The fridge hum uses its own audio player per fridge**, because `Audio` only loops its own cues.
  With many fridges in hearing range this could add up.

## Performance (Radeon 890M, 1600x900, measured 2026-09-12)

- Medium (default): OR 71-76 fps (1% low 67), lobby 73-76 (59-67), corridor 94-103 (75-90). Low: 95-124.
  Before the perf pass medium was OR 36, lobby 42, corridor 55.
- High is for dedicated GPUs only: 16-37 fps on the 890M (SSAO, MSAA 2x, full resolution).
- SSAO alone costs about a third of the frame here (OR 71 -> 50). Keep it out of medium.
- FXAA is free (measured within noise); kept on medium.
- No hitches over 25 ms left in a cold first-launch playthrough except one behind the
  "SCRUBBING IN..." warmup cover (1.5-2.4 s, once per session). The forceps step was the last
  (55 ms): the warmup now waits for its threaded wound mesh, and channel generation rejects
  bad shapes before its rotation search (same channel per seed, 2-6x faster).
- New content must be added to `scripts/warmup.gd` (new item, patient state, monster, minigame),
  and minigames should build shaders through `Minigame.cached_shader()`, or first-use hitches come back.
- Run-to-run noise is about +/-10%; compare with `tools/perfprobe.tscn -- --tune` (includes a repeat row).
