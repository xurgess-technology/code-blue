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
- **The work lamp is tuned for the game, still bright in the lab (sweep 2, orscreen).** Energy 2.2
  -> 0.5 with a steeper falloff (attenuation 1.0, 40 degree cone). In the real OR
  (`tools/game_shots/10_operating_hud.png`) skin keeps its colour and the cues read. The minigame
  lab's `--look=or` room adds a 1.6-energy ceiling light 2.8 m up, so lab close-ups of Bob's
  forearm (tourniquet, anesthetic) still bleach near the centre; that is the lab's light, not the
  lamp (energy 0 looks almost the same). The lab now builds the lamp through
  `SurgerySystem.make_work_lamp()`.
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
- **Lagged nettests used to die at clock-in (fixed by netfix, sweep 2 integration).** Measured
  cause: with the hospital a full keyframe was one 22.2 KB unreliable message (3.2 KB in the
  lobby), about 17 ENet fragments. A client whose ack was unusable (level build, or 5 s of
  history gone) got that keyframe on *every* tick: 2372 keyframes, 47.9 MB to one client in a
  failed `deliver`, 1.6 MB/s of datagrams through the relay; with 3% loss, 80 ms of reordering and
  a newer keyframe every tick, one never completed, so the ack never advanced (stuck at seq 216
  for 90 s). Replication is now per field with acks and messages of at most 1000 bytes (see
  CONTRACTS, Networking).
- **Harsh links degrade through ENet's reliable channel, not snapshots.** A level build stalls a
  machine for seconds (joining, a new hospital); ENet's round-trip estimate then jumps to 1-3 s
  (variance up to 2 s) and decays slowly, so a reliable RPC lost in that window is resent 5-10 s
  later, and two losses of one reliable packet can outlast the timeout. Peers now get patient
  timeouts (`Net.PATIENT_*`: 10-20 s, limit 64) from connecting until `Game.NET_PATIENCE_MS`
  (15 s) after their first acknowledgement, and for 15 s after every level build. At 200 ms,
  80 ms jitter, 8% loss (4x speed) `deliver`, `surgery` and `full_shift_lag` pass; `two_patients`
  fails about half the time because one client's order arrives after the other's two-second
  (game time) step is over, so the operations do not overlap and that client sees none of it.
  Earlier runs also saw the odd client drop (`[net] peer ... disconnected` prints the last RTT and
  the longest frame). Snapshots keep flowing throughout. Building the level without blocking the
  network poll would fix the cause.
- **The lag relay reorders more than real links**: each datagram gets an independent uniform
  jitter, so +-40 ms at 4x game speed reorders several packets per tick. Snapshot messages are
  unordered and cope (`NET_REORDER_MS` 100 ms before a gap counts as a loss).
- **A global group or entity waits for its field names to be whole.** After a lost message that
  added fields, the client keeps the group's last whole copy (`g`) or does not apply that entity
  (players, monsters, items) until the whole entity arrives again (fast-loss detection plus one
  resend, typically 100-400 ms).
- **Monsters are the largest part of a snapshot** (about 2 KB/s per client with two or three
  moving). Sending their position at a lower rate or as smaller deltas would halve the total.
- **A killed client takes 5 to 12 seconds to be noticed** (ENet timeout, `Net.TIMEOUT_*_MS`), up
  to 20 s within 15 s of joining or of a new hospital (patient timeouts).
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
- **Six loot kinds are still primitives** (models sweep: stethoscope, pulse oximeter, blood
  pressure cuff, reflex hammer, otoscope, wedding ring): no CC0 model exists for them on the
  vetted sources (searches in `ASSETS.md`). The other 15 are real models; see "Models" below.
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
- **Money readout is a corner number** until wave 3's minimal HUD (shown near the sell bin, shop
  or pile, while aiming at them, or for 4 s after a change).

## Shift loop and patients (sweep 2 wave 2)

- **The minimal HUD has no objective line**, so "the phone is ringing", "a patient is on the way"
  and "clock out now" only reach players as short messages (and the ring itself).
  `loop.objective_text()` still produces the line if a later HUD or the OR monitor wants it.
- **The paycheck screen covers the view for 6 s** (the old win overlay, 72% black) and the game
  over screen for 8 s. Nothing can hurt you then (monsters are gone), but it is a long blackout.
- **Two crews at once overlap at the table** (models sweep: the paramedics are rigged models
  with collision now, see "Models" below). The patient's body on the gurney does not breathe
  (vitals fixed at 70).
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
- **The player table's operation is only mirrored into `game.cases`** (`mirror: true`): the
  downed worker's `player_surgery.gd` still owns it and replicates it in `pt`, so its state crosses
  the wire twice. The integration wave can move it onto a real case and a surgery system from
  `game.surgeries`. On fallback levels clients do not append the player table to
  `level_info.tables`, so the mirror's `table` index only resolves on the host there.

## OR screen and minimal HUD (sweep 2 wave 3)

- **The monitor reads from a few metres, not from the far end of the OR.** On the hospital's
  2.2 x 1.3 m mount the vitals number and the green / red supply ticks read from about 9 m at
  1280x720 (`tools/game_shots/12_orscreen_door.png`); names, step labels and counts need about
  4-5 m. Two patients side by side halve the type (`18_orscreen_two_cases.png`). A bigger mount
  (hospital) or a "far mode" that drops to vitals + current step past ~6 m would help.
- **Several patients are only tested synthetically.** `game.cases` does not exist on this branch;
  the model's multi-case, incoming, dead and player-case paths are covered by fake game objects in
  `tools/orscreentest.gd` and the gameshot poses use `or_screen.model_override`. Re-run
  `tools/orscreentest.tscn` and `gameshot --only=orscreen` once `loop` is merged. Per-table
  operators need `game.surgery_for_table(t)` (else only the first case shows who operates).
- **The ECG sweeps at the refresh rate** (12 Hz close, 5 Hz beyond 7 m), so it moves in small
  steps up close. Raising `REFRESH_NEAR_HZ` costs a 1024x~580 2D viewport redraw each time.
- **Stamina bar and controls line kept.** The minimal HUD brief lists only slots, prompt, health,
  messages, money, the surgery hint, FPS and pause. A thin stamina bar under the hearts (only
  while stamina is not full) and the first-45-seconds controls line were kept because nothing in
  the world shows them; delete `_draw_health`'s stamina block or `_draw_hint` to drop them. The
  flashlight label and the party list are gone.
- **Lobby guidance now comes from the message line only.** With the objective banner gone, the
  "hold E at the time clock" instruction is the lobby message (6 s) plus the clock's interact
  prompt; the monitor's idle screen says "clock in to start the shift" but it is in the OR. The
  `loop` worker's phone/flow should carry any new objective in the world or in messages.

## Models (sweep 2 integration: loot and paramedic models)

- **No CC0 gurney or stretcher exists**, so the crew's gurney is still built from shapes (now one
  merged mesh with the brushed steel texture on the frame). Six loot kinds keep their primitive
  for the same reason (see Inventory above). Swap in a model by registering `item/<kind>` in
  `scripts/assets.gd`; nothing else changes.
- **Paramedic collision is on the world layer** (`crew.gd` `_make_blockers`: a box over the
  gurney, a capsule per medic, moved with the crew). Players and monsters cannot walk through
  them and the crew's path is unaffected (the navigation mesh is baked from the level's meshes
  before any crew exists), but: a crew walking into a player shoves them (a player pinned
  against a wall can jitter), anything that ray casts the world layer sees them (the aim ray,
  item drops, monster sight lines, the economy's free-floor search), and while the crew hands
  over it stands where a surgeon would stand beside the table. A dedicated physics layer that
  only players and monsters collide with would avoid the ray side effects but needs a hook in
  `player.gd` and `monster.gd`. Tested: `looptest`, both `playtest --god` ailments and `devtest`
  pass with it; nettest was not run.
- **The paramedics are Kenney's big-headed mini characters** (the players' style) in recoloured
  uniforms, not realistic figures. The front one walks with a plain walk (nothing to hold); the
  back one plays the "holding-both" arm pose filtered over the walk, so its hands are near but
  not exactly on the push handle.
- **Bright flat-coloured models look gold-washed** in lit rooms (the Kenney laptop and coffee
  maker): the loot rim's constant `base` term and the grazing-angle edge light up their big flat
  faces. The inventory worker's note about box-shaped loot applies more now; lower the gold
  `base` in `ItemModels.tint_material` if it bothers.
- **Two loot models are also level decoration**: the lab islands' Kenney laptop and the break
  room's coffee machine use the same files as the `laptop` and `coffee_maker` loot. Only the gold
  rim tells the loot apart.
- **Stand-ins**: the ultrasound is a beige 90s laptop with a trackball, the IV pump a retro
  multimeter, the heart monitor a small CRT with a drawn trace, the gold watch a pocket watch,
  the ear thermometer a food thermometer, the desk phone a red rotary phone. They read in play,
  but a close look tells.
- **First use of each loot model costs 10-300 ms** (loading the file and building the merged
  mesh). `Assets` starts loading the `item/*` and `crew/*` files on threads at start-up and the
  warmup builds every kind behind its cover: the warmup took 1.6-2.9 s in tool runs that start
  a session straight away (1.3-1.5 s before; the tools skip the menu time the threads would use).
- **Held small loot sits at the bottom-left edge** in first person (the desk phone is partly off
  screen); the placement is `player.gd`'s, unchanged.
- **The inventory screenshots' close-ups are still from standing eye height**, so small loot is
  small in them; the item contact sheet the worker used for detail was a throwaway probe.

## Downed players (sweep 2 wave 3)

- **The stitches operation is self-contained.** `game.add_case` / `game.cases` do not exist on this
  branch, so the player table runs its own copy of the surgery system through
  `scripts/downed/player_surgery.gd` (an adapter standing in for the game). The integration wave
  should rewire `game.start_player_surgery(p)` onto `add_case({patient_id: "player", player_id,
  ailment_id: "stitches", table: <player table index>})` and delete the adapter; until then the OR
  monitor does not list the player case, and `game.surgery_camera()` / `surgery_wants_mouse()` /
  `surgery_local_exit()` stand in for per-table surgery lookups in `main.gd` and `hud.gd`.
- **Solo means game over on the first down.** Nobody can carry you, so `all_players_out()` fails
  the shift at once (the mortal playtest now reports "went down" instead of "died"). The dev room
  never ends the shift for it.
- **The carry pose is a stiff plank.** The carried body lies straight over the right shoulder (no
  bend, no animation), sticking out behind the carrier; with the big-headed surgeon model it is
  mostly hidden from straight in front. The carried player's camera sits a metre behind the
  shoulder point along their own look direction, so looking around orbits a little.
- **A dropped client can land at shoulder height for a moment** if a stale snapshot (still saying
  "carried") arrives after the reliable `placed` event: it then falls from the carrier's shoulder
  next to where it was put down.
- **Downed players do not watch for the Night Nurse** (`alive_players()` excludes them, and
  perception uses it) and make no footstep noise while crawling. Calling for help is heard by
  teammates only; monsters ignore downed players entirely.
- **Bleeding keeps running while being stitched** (at half speed on the table); a botch costs
  4 s of bleed per vitals point. A patient who bleeds out mid-stitch dies on the table.
- **The player table is placed by ray casts** when `level_info.tables` has no "player" entry (the
  fallback ward): the first clear 2.3 x 1.1 m spot 2.7-3.4 m from the OR table. On the hospital
  and the dev room the level's own entry is used; a level table is detected by a downward ray
  (a top between 0.5 and 1.4 m) and no model is added.
- **Suture kits skip `ItemSpawner.plan`**: `game.spawn_suture_kits()` places three stacks of 1-2 in
  random legal containers (trauma bags, nurse station drawers, drawer units), not spread by wing
  depth, and not topped up by the softlock guard.
- **`tools/mapcheck.gd` reports seed 112** (a morgue tray anchor 3.3 m off the navmesh); the same
  on `main` before the pod removal.

## Dissection (sweep 3)

- **`make_lying` is untested.** The monsters worker's still lying copy did not exist on this branch,
  so every screenshot is the primitive fallback body. With `make_lying` present the builder hides the
  copy's meshes that lie entirely past the head (by X extent, a heuristic) and puts its own, openable
  head in their place: expect a size or style mismatch against the Kenney-rig bodies (the own head is
  a smooth ellipsoid, 0.14 m half length) and possibly a missed or wrongly hidden part. Check it on
  the merged build (`tools/dissectiontest.tscn -- --shots`).
- **The primitive bodies are plainer than Bob and the seal**: smooth lofts, a painted face with
  sphere eyes, no hands to speak of. They read as a patient in a gown / a grey eyeless patient with
  big ears at table distance (`tools/dissection_shots/01*`, `02*`), less so up close.
- **The saw's calm guide glow shows on the forehead before anyone saws** (the same idle glow limbs
  have); the saw model itself is hidden until someone saws the skull.
- **The brain step's camera looks from past the end of the table**, so the body appears upside down
  above the opening (`05_brain_nerves.png`). Readable, but a surgeon standing at the head end would
  be the natural view.
- **The nerves are short**: the gap between the brain and the bone is 1-1.5 cm, so the cords are
  small; the rings carry the read. A larger cavity (smaller brain) would show them better.
- **Awake thrashing only adds botches, shrieks and body motion.** The operator's hand shake stays
  the surgery system's stir (strongest at sedation 0, roughly every 2.5 s); there is no separate,
  stronger jolt for an awake monster. The head barely moves so the work planes stay on it.
- **An awake monster shrieks forever** (noise 0.7 every 3.5-6.5 s) until re-dosed, dissected or the
  shift ends: a forgotten one keeps calling the Discharged to the OR. No strap breaks (by design).
- **Monster cases never block clocking out** (`ShiftLoop._clock_out_blocker` skips them); the next
  shift's `_clear_case` removes a strapped monster left behind. The softlock guard
  (`_live_requirements`) still counts a monster case's bone saw and forceps.
- **Holding anesthetic at a monster's table always re-doses** instead of offering to operate, from
  either hand. Set the vials down (or on the shelf) to operate.
- **`game.case` can be a monster case** (the alias is the first non-player case) when a monster is
  strapped before the phone patient arrives. Old single-case code paths and tests that read
  `game.case` would then look at the monster.
- **Brain quality is the brain's condition only**; the saw's `cut_quality` is recorded in the flags
  but not used.
- **The minigame lab needs `--ailment=dissection`** for monster patients (it infers amputation for
  the saw and gunshot for the forceps), and `--flags=skull_open:1` to show the opened skull.
- **Shutdown noise in the nettest logs**: `Condition "!peers.has(p_id)" is true` repeats on clients as
  the scenario ends; the dissection scenario passes regardless (not checked whether other scenarios
  print it too).
- **Warmup builds four more bodies and four more minigames** (both monsters, closed and opened, the
  skull saw and the brain forceps). `tools/perfprobe.tscn` was not run for this change.

## Testing tips

- Add `--fixed-fps 60` to headless runs: the game then steps as fast as the CPU allows (a 250 s
  shift takes about 20 s) with identical results.
- `tools/playtest.tscn` prints a heartbeat every 30 game seconds (target, position, hands).
- `tools/gameshot.tscn` includes `10_operating_hud`, a real operation in progress.
- `tools/minigame_lab.tscn` takes `--seed=N` for varied forceps channels and infection lines,
  and `--wide` for a camera that shows the body around the site.

## Performance (Radeon 890M, 1600x900, measured 2026-09-12)

- Models sweep (2026-09-13, medium, `perfprobe --models`, real models and the old primitives
  alternated in the same run, two passes each, with four other Godot processes from another
  worker running): a room floor with all 21 loot kinds three times over, rims on, 88-91 fps
  (1% low 79-82, 609-622 draws) with models against 72-76 (61-67, 1194-1197 draws) with
  primitives; the OR 87-91 against 92-96 (same scene: its shelf holds surgical supplies, so this
  is noise); paramedics and gurney in view 78-81 (66-75, 271-312 draws) against 78-79 (70, 312-333).
  Before any change, without the other processes: loot room 107-121, OR 93-108, crew view 84-94.
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

## Found in the sweep 2 integration check (2026-09-13)

- **`leave_items` is flaky under simulated lag.** With `--lag=120 --jitter=40 --loss=0.03` it
  failed 2 of 3 runs: the second client lost its connection while waiting to see the leaver's
  dropped items. Unlagged it passes, as do the other 11 lagged scenarios.
- **The playtest bot can fail to reach both bone saws on some maps** (seed 802, Bob amputation:
  it skipped `it_77` and `it_81` as unreachable and the patient died waiting). `mapcheck` reports
  every container and resting spot in reach, so this looks like bot navigation, but check the
  spots in the dev room or a windowed run before trusting that.
- **No threaded model preload.** `Assets._ready` used to request the loot and crew models on
  loader threads; meshes built there raced the main thread's mesh building and crashed Godot
  (signal 11) in about half of the headless runs. Removed; models load on first use.
- **Running several Godot processes on one project directory at the same moment** (not separate
  worktrees) has also produced start-up segfaults; run headless tests one at a time per checkout.
