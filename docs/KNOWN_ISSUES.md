# Known issues

Open problems from the content sweep of 2026-09-12 (patients, items, containers, surgery,
guide, monsters). Nothing here breaks a shift; each is a feel, look or robustness problem to fix.

The first whole-game integration pass ran on 2026-09-13: 16 headless shifts per run across both
patients, both ailments, good and sloppy surgeons, multi-shift and mortal runs, plus the monster
lab, the minigame self-tests and windowed screenshots. It found no break in the game itself; the
problems it did find were in the test bot, and are fixed. Resolved items are listed at the end.

## Surgery and patients

- **Bob's gown pokes through the gunshot wound view.** Gown folds rise up to about 2 cm above the
  `gunshot` site plane and move with breathing; the forceps channel is lifted 2 to 2.9 cm to
  compensate, but a flap still shows through (`tools/lab_shots/forceps_finished.png`). Fix options:
  put the site on top of the local geometry, or let the forceps step hide the body's own wound
  visuals and gown locally.
- **A teammate's flashlight does not light the wound.** The forceps channel darkens every light by
  depth (down to 6% at the bullet), including other players' flashlights. The design wants a
  teammate's light to help. Needs an "extra light" input to the minigame or a different darkness
  approach. Best done once multiplayer can be tested for real.
- **The infection still shows in two styles at the edges.** The tourniquet step now puts its
  infection front exactly where the body paints its own, and its decal is wider and deeper, so the
  seal's paddle and Bob's forearm are covered from above. At a glancing angle a little of the
  body's green still shows low on the sides of the limb (`tools/lab_shots/fix_tq_bob_wide.png`).
  A real fix is one infection look: the body's shader drawing the minigame's margin, or the body
  hiding its own infection while the decal is up.
- **Sloppy sedation and stump wrap are a bit forgiving.** Sloppy anesthetic on the seal costs 11.9
  vitals and a sloppy stump wrap 14.0, slightly under the 15 to 25 target. The stump wrap now
  reacts to stirs through `on_jolt`, which slips the bandage more reliably than the old
  cursor-jump guess; re-measure before tuning.
- **A sloppy saw on the seal still takes about 40 s** (Bob 30 s, good surgeons 15 and 21 s). It was
  45 and 64 s; see the resolved list. Raise `FLOOR` in `scripts/surgery/games/saw.gd` further if
  it still drags.

## Interface

- **Small guide tab labels at 1280x720.** Some index tabs shrink to about 10 px and long names
  drop words ("Gunshot wound" shows as "Gunshot").
- **Guide draws on canvas layer 60**, above the post-processing layer (50). Any HUD drawn above
  60 would appear over the book.

## Settings (sweep 2, wave 1)

- **Night Nurse perception uses 78 degrees for remote players.** `fov` applies only to the local
  player's camera, and the host does not know a client's field of view, so on the host a
  client with a wider view counts as "looking" over a slightly narrower cone than they see.
  Replicate the fov in the player report if it matters.
- **High brightness washes out lit areas.** At 100% dark rooms become readable (the point) but
  corridors under working fixtures and the near-wall glow go milky; 0% is close to black in
  unlit rooms. The curve is in `Look.apply_brightness`; re-tune after the hospital rework lands
  (new darker wings). Default (50%) is exactly the shipped look.
- **Held items change size with fov.** Their screen position is kept, but at 60 degrees the bone
  saw is large and at 100 small, as with any fixed viewmodel distance. No separate viewmodel fov.
- **Window mode is not applied to tool runs.** Settings skips window changes when the command
  line has a `.tscn` path or window flags, so tools keep their `--resolution` window; F11 in a
  tool only changes the saved setting. "Windowed" restores a 1600x900 centred window.
- **The old `user://prefs.cfg` still exists.** Only its `video/quality` is migrated (once, when
  `settings.cfg` is missing); the menu keeps name and address there. Note `Menu._save_prefs`
  rewrites that file from scratch, which is why the quality preset used to get lost.
- **Tools inherit the player's saved settings** (brightness, fov, volumes) from
  `user://settings.cfg`, which every worktree shares. `settingstest` and `settingsshot` use
  scratch files; `gameshot` and `perfprobe` do not, so reset settings before comparing looks.

## Level and tools

- **The OR supply shelf is about 4.2 m from the table** (the OR template has no wall closer that
  keeps doors clear). Fine for delivery, but it makes the surgeon walk.
- **3 of 200 generated maps have no pegboard**; on those the bone saw only spawns loose.
- **The navmesh keeps a player-sized agent about 1.9 m from some containers against walls**
  (seed 4245, `ct_44_22_0`). The game's reach rule still allows the interaction from there, so
  it is fine for players; the test bot now falls back to that rule when it stops getting closer.
- **The fridge hum uses its own audio player per fridge**, because `Audio` only loops its own cues.
  With many fridges in hearing range this could add up.
- **Mortal bot runs die in shift 2.** The bot now faces the Night Nurse with its light on and backs
  away, and logs what hit it, but it still gets caught while it walks to items with the nurse
  behind it. `tools/monster_lab.tscn` (all scenarios pass) remains the real monster check.
- **Headless runs log "Parameter m is null" from the gauze warmup.** It comes from the dummy
  renderer used by `--headless` and does not happen in a window.

## Testing tips

- Add `--fixed-fps 60` to headless runs: the game then steps as fast as the CPU allows (a 250 s
  shift takes about 20 s) with identical results.
- `tools/playtest.tscn` prints a heartbeat every 30 game seconds (target, position, hands).
- `tools/gameshot.tscn` includes `10_operating_hud`, a real operation in progress.
- `tools/minigame_lab.tscn` takes `--seed=N` for varied forceps channels and infection lines,
  and `--wide` for a camera that shows the body around the site.

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

## Resolved 2026-09-13

- **Sloppy sawing was very slow** (45 s Bob, 64 s seal). `FLOOR` 0.25 -> 0.45 with the tearing
  botch rate scaled to match: now 30 s and 40 s at 16 to 19 vitals of botches, good surgeons
  unchanged.
- **The amputation line sat in the infection** on both patients. The infection now starts past
  `limb_cut`: Bob's is drawn per pixel from a baked distance along the arm (his forearm has no
  vertices between the sleeve and the hand, so vertex colours could not place the edge), the
  seal's starts on the paddle. The tourniquet step reads the front from the body.
- **Minigames guessed limb size** from the tourniquet and stump props. `PatientBody.site_section`
  and `infection_start` replace that in the tourniquet, saw and gauze.
- **No severed-limb hook.** `PatientBody.make_severed_limb(parent)`; Bob's forearm is now cut out
  of his skinned mesh, capped and dropped away like the seal's flipper.
- **Stirs were inferred** from cursor jumps. `Minigame.on_jolt(offset, strength, duration)`; the
  gauze, forceps and tourniquet use it.
- **HUD overlap while operating**: checked in a real operation, no overlap. The objective banner
  no longer tells the operator to "aim at the table" while they are operating.
- **Contract gaps**: `apply_flags` replacing flags, the reserved render layer
  (`Minigame.OWN_LAYER`) and the saw's cross-section (now drawn by the surgery HUD) are in
  `docs/CONTRACTS.md`.
- **The minigame lab only produced two seeds**: `--seed=N`.
- **The forceps self-test stopped after its first run** ("free a locked object"); it now
  completes all 60 runs.
- **Test bot**: it dithered forever between two equally near items, and stalled at containers the
  navmesh kept it 1.9 m from. Both fixed in `tools/playtest.gd`.
