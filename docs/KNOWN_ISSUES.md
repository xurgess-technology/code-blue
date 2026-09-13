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
- **The work lamp blows out close skin (sweep 2, minigames).** In `--look=or` lab shots Bob's
  forearm and the saw/tourniquet/anesthetic sites render near white with bloom
  (`tools/lab_shots/c_anes_good_0.8.png`), which washes out the in-world colour cues on skin (the
  tourniquet's green skin glow barely shows; the strap's own glow carries it). The lamp is in
  `scripts/surgery/surgery_system.gd` (energy 2.2, 0.4 m away); check a real game shot and dim it
  or its spot attenuation for close cameras.
- **Sloppy forceps varies by channel (sweep 2).** Bot 0.0 loses 10-22.5 vitals over 12 channels
  (mean 15.8) and some lab seeds only 5-8 (short, gentle channels). Wall tears are discrete
  (2.5 each, at most one per 0.9 s), so the total follows how long the sloppy hand spends on bends.
- **The anesthetic vein floats on the seal.** It is a straight bar drawn without depth test so
  gown folds and a fidgeting arm never hide it; on the seal's curved flank its ends hang in the
  air a little (`tools/lab_shots/c_seal_anes_7.png`). A decal-projected vein would hug the body.
- **Stirs cost little in most steps.** At sedation 0.4 a good surgeon loses 0 in forceps,
  tourniquet, saw and pack and 2 in the stump wrap: the jolt is forgiven by design and only
  shakes the tool. Underdosing still matters through the saw's bleeding and time lost.
- **The dev room and nettest only operate the anesthetic step** (`tools/devtest.tscn`,
  `nettest --only=surgery`). Every step's `bot_input` finishes in the lab and in all eight
  `playtest --god` runs, but a replicated forceps/saw/gauze step is only checked by the lab's
  per-frame `net_state` round trip.

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

## Networking (sweep 2, net worker)

- **The Steam backend is untested end to end.** Steam is not installed on the development
  machine, so only this was verified: GodotSteam 4.22.1 loads in Godot 4.7.2 and exposes
  `SteamMultiplayerPeer`; `steamInitEx(480)` without a Steam client fails cleanly and the game
  falls back to ENet with the Steam button hidden; a missing extension library does not stop
  the game. Not verified: lobby creation, `host_with_lobby` / `connect_to_lobby` (the code falls
  back to `create_host` / `create_client`), invites, "Join game", `+connect_lobby` launches,
  persona names, and how quickly a vanished Steam peer is noticed. Needs two Steam accounts.
- **Upstream player state is still 20 Hz full state** (a compact array, about 2.5-3.5 KB/s per
  client with operator reports). Fine for four players; delta it if the player count grows.
- **Keyframes are one unreliable message** (about 4-8 KB mid-shift), so ENet fragments them and a
  lossy link loses more of them. Deltas never depend on a keyframe arriving (clients ack what
  they decoded), so this only delays recovery from a missing base. Splitting keyframes across
  ticks would fix it.
- **Monsters are the largest part of a snapshot** (about 2 KB/s per client with two or three
  moving). Sending their position at a lower rate or as smaller deltas would halve the total.
- **A killed client takes 5 to 12 seconds to be noticed** (ENet timeout, `Net.TIMEOUT_*_MS`).
  Until then its surgeon stands frozen, and if it was operating, nobody else can start the step.
- **`menu.gd` `_save_prefs()` overwrites `user://prefs.cfg`** without loading it first, which drops
  the saved graphics quality (pre-existing; the settings worker owns preferences now).
- **Nettest bots teleport** instead of walking, so the multiplayer tests prove replication, not
  navigation or monster pressure. `tools/playtest.tscn` still covers those solo.

## Level and tools

- **The OR supply shelf is about 4 m from each patient table** (it stands against the north wall
  between them). Fine for delivery, but it makes the surgeon walk.
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

## Hospital (sweep 2 wave 1)

- **Monsters wander into the entrance building and the neutral area.** They only *spawn* on wing
  hallways, but `Monster.random_nav_point` picks any point of the one navigation region, so a
  Discharged can stroll into the lobby or the parking lot. `HospitalBuilder.zone_of(info, pos)`
  tells where a point is. Loop (wave 2): wander targets inside the entrance building or the
  neutral area are now rejected (`game.monster_may_wander_to`, one hook in `random_nav_point`), but
  noise (surgery monitors, footsteps) and chases still lead monsters into the OR and outside, and
  the Night Nurse's own movement was not checked. Nothing leashes a monster back out afterwards.
- **Furniture in the open has no collider.** Chairs, IV stands, bins, plants, bed trays, coat
  racks and the like stand where an agent following the navigation mesh would catch on them, so
  they are visual only: players walk through them and dropped items fall through them. Blocking
  furniture (beds, counters, shelves, carts, gurneys, wheelchairs, benches, desks) keeps a
  collider, clipped to the tiles it blocks and held 0.18 m back from open tiles, so its visual
  overhangs the collider by up to about 20 cm. Wall corners have a 0.18 m chamfer in the collision
  only. This was driven by the playtest bot, which cuts path corners by up to 0.7 m; monsters
  steer the same way.
- **Supply runs are long.** The map is about 110 x 100 m and deeper wings are far: the god-mode
  bot needs 140 to 340 s of game time to stock the shelf (vitals drain over 840 s). Real teams
  split up; keep an eye on it when tuning the drain.
- **Doorways are open and one tile wide.** No door leaves (still a TODO in DESIGN.md); lintels and
  signs mark them. Every room of a kind carries the same sign ("WARD", "OFFICE").
- **Generation retries about 12% of seeds** (a wing with too few room slots for the rooms every
  wing needs); up to 8 attempts, 30 to 230 ms per map, worst case about 1 s.
- **Four-wing layouts have two small north wings** (15 and 14 tiles wide) that hold little
  besides their required rooms.
- **Outside is a black sky over a 1.9 m fence**, with nothing beyond it. Reads as night; a tree
  line or distant lights would sell it better.
- **Some registered hospital models are not placed yet** (`hosp/armchair`, `hosp/washer`,
  `hosp/bench` — benches are primitives because the model is too short).
- **Dead fixtures still get a flicker controller** (they spark now and then), and every
  controller duplicates its panel material, so each fixture panel is its own draw call. There
  are about 140 to 200 fixtures on a map now.
- **The generator ignores the size arguments** of `MapGen.generate(seed, w, h)`.

## Dev room (sweep 2 wave 1)

- **Knock-down is a stand-in.** Until the downed system (wave 3) it is damage to 1 HP plus a
  3 s stun (you see the floor, others see you lying down). `game.knock_down_player` is the one
  place to replace.
- **The HUD still shows the case panel and "operate / bring to the shelf"** in the dev room while
  a patient is on the table. Harmless; the HUD becomes minimal in wave 3.
- **Bots are simple.** They path on the navmesh without avoiding each other or monsters, never
  flee, and keep their flashlight off. Their cameras count as watchers for the Night Nurse, and
  bots and dummies count as living players for monsters and the "everyone is dead" check.
- **A bot operates with the minigame's own `bot_input`.** If a reworked minigame's bot input stops
  finishing, bots stop finishing that step. The devtest covers only the anesthetic step.
- **Noclip skips the rest of the movement step**, so F, Q and G do nothing while flying.
- **Humans who die vanish** (as in a shift) and auto-revive at the spawn after 4 s; dead bots and
  dummies lie where they fell until revived or removed.
- **Time scale is `Engine.time_scale` on every machine** (replicated), so it also slows a client's
  own walking.
- **The room is bright and a little hazy**: the global volumetric fog from `look.gd` still
  applies; the fixtures' fog energy is only turned down.
- **Monsters killed right against the barrier fall out of sight** behind it.
- **`tools/nettest.tscn` is still broken** (net worker); the dev room has its own two-process check
  in `tools/devtest.tscn`. Run the host first; the client waits on real time, not game time.

## Inventory and money (sweep 2 wave 2)

- **The neutral-area mode is untested:** the hospital branch was not merged. The sell bin and shop
  attach an aim box (2.4 x 1.7 x 1.8 m and 1.6 x 1.8 x 1.6 m) and a sign at the spots; if the
  hospital's dumpster or van is larger than that box, its own collider hides the interactable
  from the aim ray. The pile is lifted onto whatever is under `gold_pile.position` (the pallet).
- **Depth for loot rarity is guessed from rects** until real `rooms` / `wings` data lands (tile or
  world rects are told apart by size); without them it uses distance from the OR table.
- **Fallback placement near the time clock** checks colliders, floor and line of sight to the
  clock only. Props without collision can overlap the sell bin or shop, and it can stand in a
  walking line. On the fallback ward (no `rows`) the result was not checked.
- **Indoors the pile is capped at 2.6 m** and then grows side columns 1.35 m apart; those can go
  through nearby walls or furniture in the clock-in room or the dev room.
- **No new CC0 models were downloaded**; all 21 loot kinds are primitives (`loot_models.gd`) and
  `ASSETS.md` is unchanged. `Assets` keys `item/<kind>` replace any of them.
- **Rim overlays cost a draw call each**, now capped at the 5 biggest meshes per model. perfprobe
  `--ab` at 1600x900 medium: OR 72 fps (1% low 66), without rims 85 (69), loot hidden 89 (75);
  lobby and corridor within noise. Normal run: OR 63-73, lobby 72-91, corridor 94-119 across runs.
- **A 500-bar pile in view:** 74 fps (1% low 63) against 81 (67) for the same view with no bars
  (one run, near the noise). The pile casts shadows; turn `cast_shadow` off on its MultiMesh if the
  neutral area's lights make that expensive.
- **Fragile loot only cracks on violent drops** (hit, shove, knock-down), not when set down with
  G or when it tumbles.
- **Held bulky loot is scaled down** to 0.24 m in first person (0.55 m for others) so it does not
  fill the screen; big normal loot to 0.13 m. It reads as a toy-sized defibrillator.
- **The rim can look flat on big box-shaped loot** (heart monitor, defibrillator) at glancing
  angles in the dark; tune `TINT_SHADER` exponent or the gold `rim` in `item_models.gd`.
- **Dev room bots cannot sell**: a carry order with loot delivers to a player, not the sell bin.
- **`full_shift_lag` failed once** (both lagged clients dropped about 10 s into the shift, the host
  then passed alone) while two headless playtests ran on the same machine; it passed in the
  full run before and alone after (20 s). Looks like the lag relay starving under CPU load, not
  inventory, but worth watching.
- **Money readout is a corner number** until wave 3's minimal HUD (shown near the sell bin, shop
  or pile, while aiming at them, or for 4 s after a change).

## Shift loop and patients (sweep 2 wave 2)

- **The case panel on the HUD stacks one panel per patient** on the right edge; with two full
  panels it reaches about 330 px down at 720p. `orscreen` replaces it with the OR wall monitor.
- **The paycheck screen covers the view for 6 s** (the old win overlay, 72% black) and the game
  over screen for 8 s. Nothing can hurt you then (monsters are gone), but it is a long blackout.
- **Paramedics are primitives** (capsule medics with hi-vis bands, a box gurney), have no
  collision and walk through players, furniture and each other; two crews at once overlap at the
  table. The patient's body on the gurney does not breathe (vitals fixed at 70).
- **The extra call rings once per shift**, 45 to 150 s after the first patient is on the table,
  even if the team is about to clock out; if the team clocks out first there is no extra call.
  The shift has no other pacing: a team that never answers still gets the first patient (the
  answering machine), and clocking out is the only way to end a shift besides game over.
- **A dead patient's penalty clamps money at $0** (`add_money` without the `debt:` prefix), so a
  broke team loses nothing for a death.
- **The next shift keeps the hospital and its layout** but not what was dropped there: untouched
  spawner items are removed at clock-in, and every container closes. Items players dropped stay.
  The guide stays wherever it was left.
- **The fallback second table** (levels without `level_info.tables`, e.g. the dev room) is placed
  by a fixed list of offsets and a tile or distance check; in the dev room it stands 0.35 m from
  the pen barrier. The navigation mesh does not know about it.
- **Answering needs the phone in reach within 8 s** or the answering machine takes the first call;
  the extra call needs someone within 20 s. Big maps may make the extra call hard to catch.
- **Subtitles show to everyone regardless of distance**, bottom centre (top while operating).
- **Nettest bots still teleport**, so `full_shift_lag` checks replication of the loop (clock,
  phone, crew, clock-out, pay), not walking; `tools/looptest.tscn` and the playtest walk it.
- **The dev room's Clear tables** also sends any crew on its way back; a crew mid-walk with no case
  turns around.

## Testing tips

- Add `--fixed-fps 60` to headless runs: the game then steps as fast as the CPU allows (a 250 s
  shift takes about 20 s) with identical results.
- `tools/playtest.tscn` prints a heartbeat every 30 game seconds (target, position, hands).
- `tools/gameshot.tscn` includes `10_operating_hud`, a real operation in progress.
- `tools/minigame_lab.tscn` takes `--seed=N` for varied forceps channels and infection lines,
  and `--wide` for a camera that shows the body around the site.

## Performance (Radeon 890M, 1600x900, measured 2026-09-12)

- Sweep 2 hospital (2026-09-13, medium, seed 4242, two runs each, nothing else running): OR
  114-116 fps (1% low 105-110, was 75/67 on the old map), break room 135 (120-129, was 88-93),
  corridor 104-105 (94-96, **was 123-124 / 115-120**: the new hallways are 80 m sightlines),
  pharmacy 211-212 (162-165, was 259-277), operating 278-293, neutral area outside 169-170
  (110-120, 557-568 draw calls). No frame over 25 ms outside the warmup cover (`--hitch`).
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

- **Minigames needed reading and slider matching (sweep 2).** All five steps have empty gauges
  and read in the world; the forceps' hidden speed limit, "hold still" grip and damage gauge are
  gone. Sloppy sedation (15.5 both patients), stump wrap (14-18) and saw (13.5 s Bob, 19 s seal)
  are now inside their targets.

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
