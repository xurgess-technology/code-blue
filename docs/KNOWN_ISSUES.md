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
- **Every room of a kind carries the same sign** ("WARD", "OFFICE"). Doors: see "Doors and the
  per-shift wings" below.
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
- **The next shift rebuilds the wings** (doors sweep): anything dropped in a wing is gone with it,
  including items players left there on purpose; only the entrance building and the neutral area
  keep what lies in them. The guide goes back to its lectern if it was left in a wing.
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

## Brains (sweep 3, brains worker)

- **Hive Eyes was built against a stand-in Walk-In.** On the brains branch `Monster.WALK_IN` does
  not exist, so `brains.spawn_walk_in` makes a Discharged body with `kind = "walk_in"` (it still
  hunts by sound). The camera sits at `m.height * 0.93` and 0.34 m in front of the monster's origin
  along its facing; the real Walk-In model may need a different eye point (its head can block the
  view, or the camera can poke through a wall the Walk-In faces). The sedation end is only reached
  through `has_method("is_sedated")` and was not exercised (no `sedate` on this branch).
- **The HUD stays up during Hive Eyes** (crosshair, slots, messages): the view is the Walk-In's
  but the HUD is yours. No HUD hook was added.
- **Echo's veil does not fully hide a lit flashlight cone** (volumetric fog and the post layer draw
  after it), so the spot on the nearest wall stays faintly visible under the outlines. Outlines of
  skinned meshes follow their skeleton; only the dev dummy surgeon was checked in a screenshot.
- **Brains keep spoiling through the paycheck screen and the next lobby** (world_time keeps
  running), so a brain carried over a shift change is rotten by the next shift. Intended as "brains
  spoil fast", but worth a look once the loop is tuned.
- **Absorbed brains are keyed by peer id.** A player who leaves and joins again (a new ENet peer id)
  starts from nothing; the old entry stays until game over.
- **A client's shown value can be $1-2 off the host's** while the spoil clock runs: `bt` is snapped
  to 0.5 s in the item report and a client's world_time is only corrected when more than 1 s off.
  The host's `current_value` is what the dumpster pays.
- **Blender placement is a heuristic:** the counter-height cell nearest the time clock with a
  0.2 m margin, backed toward the nearest wall. On the hospital's entrance building (the same break
  room every seed) it lands on the free end of the sink counter by the fridge; nothing checks for the
  models that stand on counters without colliders (the coffee machine, the microwave), so a changed
  break-room layout could put it inside one. Levels without a break room get a steel stand.
- **The brain is procedural** (merged ellipsoids, folds in the shader). It reads as a brain from
  above and behind at hand and table distance (`tools/brain_shots/01..04`); from low side angles the
  hemispheres still look like two smooth eggs, and the rot mostly changes colour (no geometry
  change, so the gold rim overlay keeps fitting).
- **Perf** (`perfprobe -- --brains`, 1600x900 medium, two passes): pharmacy baseline 188-201 fps
  (1% low 134-150), Echo at level 3 with 66 outlines 180-192 (132-150); corridor baseline 88-94
  (75-82), Echo 93-96 (81-86); Hive Eyes depends on what the Walk-In looks at (131-236); five brains
  in view 102-108 (89-96). Starting Echo takes 1.8-2.8 ms (it walks every container once).
- **One lagged `nettest --only=brains` run never connected** (port 7941; the client timed out
  before joining); the same run passed on another port, lagged and unlagged. Probably a port clash
  with another worktree's nettest.

## Monsters (sweep 3, monsters worker)

- **Spawning a Walk-In costs about 6-8 ms** on the machine that builds it (the rig, its animation
  library copy, a few dozen primitives and materials; the baked part meshes are cached after the
  first one, which the warmup builds), about what a Discharged (9 ms) or Night Nurse (8 ms) costs.
  Clock-in now spawns 4-8 of them in the same frame on the host, and a client builds them as the
  snapshot arrives: 25-60 ms more in an already heavy frame. Spreading the spawns over frames, or
  pooling models, would remove it; not yet seen as a stall in play.
- **Baking changed the monsters' surface noise a little.** `Shapes.bake` merges each part's
  primitives into one mesh per material, and the shared shader reads object-space positions, so
  small primitives (fingers, knuckles, ears, the Night Nurse's buttons) now take their mottle and
  stains from the part's metres instead of their own unit sphere: flatter on tiny pieces. All three
  monsters are affected; the screenshots looked the same at play distance.
- **A sedated monster's capsule lies down at once** (every machine, when mode becomes SEDATED),
  while the model takes about 0.6 s to fall, and stands up at once on waking. Only queries on
  `C.L_MONSTER` see it (the dev gun, combat's aim if it uses the body); players never collide.
- **Lying down picks a clear facing with 12 rays**, but only against walls: furniture without a
  collider, other lying monsters and the patient tables are not checked. The fall also slides the
  model back half its height while it tips, which reads a little like being pulled.
- **Walk-Ins do not avoid each other** (navigation avoidance is off for every monster), so a group
  chasing the same player bunches into one silhouette at the end of a corridor.
- **The danger heartbeat and music count sedated monsters** by distance (`game._update_danger`).
- **Walk-In placement is deterministic per shift but not tuned**: every group sits within 12 m of
  its wing's first hallway tile, so on small wings the Walk-Ins can be visible from the entrance
  doorway. `MIN_ENTRANCE_DIST` (5 m) and `SHALLOW_BAND` (12 m) in `monster.gd` are the knobs.
- **wake() while dragged hits the dragger itself** (the contract says combat drops the monster and
  it hits the dragger); combat must not add its own hit, or the dragger takes two.
- **The Discharged's ears only read up close.** At 4 m or more in flashlight they are a small
  bump on each side of the head; the listening flare is visible in the lab's
  `discharged_ears_listen` close-up. The face is primitives (brow, sealed sockets with a stitched
  seam, a slit mouth) and still looks a bit mask-like in profile.
- **The nettest `monsters` scenario uses the combat stub** (no `monster_pin`), so a dragged monster
  on the client is only checked for `dragged_by`, not for following the pin; the lab checks the pin
  with a stand-in combat.

## The Night Nurse's Blender model (2026-09-14)

- **Walk at hunting speed plays 3.4x.** The clip is matched to her ground speed (`WALK_SPEED` 1 m/s,
  measured from the stance foot), so at 3.4 m/s a stride cycle lasts 0.47 s: no skating, but a fast,
  skittering gait. Only the stance half of the clip is planted; in the other half a toe drags forward
  along the floor (authored that way). A faster, longer-striding clip would read better at 3.4 m/s.
- **The toes dip into the floor in Walk**, about 4 cm through the stance; the model is lifted
  `WALK_LIFT` (3.5 cm) while walking, blending over 0.25 s, so for a moment after she stops or
  starts the feet sit a little high or low.
- **Procedural poses are turned from the bones, not authored:** the lunge (both arms swing forward),
  the knock-down recoil (head and torso thrown back, arms out) and the dead slump. They read at play
  distance (`tools/monster_shots/nurse_lunge.png`, `nurse_knocked.png`, `nurse_corpse.png`); only
  checked in stills, and nothing stops an arm passing through the dress while the pose blends in.
- **A saw hit on her shows nothing** (she is immune: combat plays the clang, no hit counter, so no
  flinch reaches clients). Only the dev gun's knock-down (calm) has a pose.
- **Perception still samples fixed heights** (0.15, 1.3, 2.1 m over her origin). Her head is 15-28 cm
  in front of the origin in Idle and Walk, so the top sample sits just behind her head.
- **Textures are 2048 px** (VRAM compressed, about 21 MB of video memory for the six maps). The low
  quality preset does not shrink them; mesh LODs (5-7 levels, generated on import) cover distance.
- **Perf** (`monster_lab -- --perf --nurses`, 1600x900 medium, Radeon 890M, seed 4242 corridor, two
  passes, nurses 3-6 m away walking in place): the old reshaped rig 107-110 fps with 1 nurse (206-208
  draws) and 114-116 with 4 (313-314 draws); the Blender model 110-112 with 1 (144-146 draws) and
  114-115 with 4 (156 draws); no nurses 110-113. Every row sits at about 110-116 fps, so this view is
  limited by something other than the nurses and the numbers only show she costs no more than before.
- **The dev panel's Night Nurse settings only exist in the dev room** (the panel does too). "Walks a
  loop here" snaps the corners to the navigation mesh but does not check that they connect; in the
  pen or a corner she can walk to the nearest reachable point and turn back.
- **`devtest -- --net=client --shots` (windowed) fails "a client takes from a dispenser"** (a 5 s wait,
  seen twice); the headless two-process run passes. Probably the windowed client's slower start; not
  looked into.
- **Two `Parameter "material" is null` errors in `playtest --god --shifts=2`**, at each case's end
  (`material_get_instance_shader_parameters`, dummy renderer). The run passes; not traced, and not
  checked against main.

## The seal's Blender model (2026-09-14)

- **The stump floats.** After the cut the stub ends in the air: the paddle, not the arm, rests on
  the table. The stump cap and its dressing hang a few centimetres over the sheet
  (`tools/patient_shots/seal_dressed_amputation.png`).
- **The fore flipper root is a tube pushed into the body**, with a crease where it meets the flank,
  and the flipper is splayed further from the body than a resting seal would hold it (that keeps the
  tourniquet and the cut clear of the flank).
- **The infection has less relief in the engine than in Blender.** It bumps through a screen-space
  derivative of its height map, which is soft at grazing light.
- **The tourniquet step's own infection tint overlaps the model's** at the front edge (see "The
  infection still shows in two styles" above): its red-purple decal sits over the baked ulcers for a
  few centimetres.
- **The gunshot dressing band is an elliptical cylinder** sized to the flank (half width 0.30 m); it
  sinks into the belly under the table and stands a few millimetres off the back in places.
- **Stir while low on vitals** blends Stir over Twitch, so a twitching seal that is jolted loses its
  tremor for about half a second.
- **Site frames are the rest pose.** Stirs and the idle look move the neck and flippers under a
  minigame's plane by up to a few centimetres (the surgery system re-places minigames at
  `site_transform` every tick, so the sites must not follow the bones); the overlays on the anchors
  do follow.
- **Perf** (`perfprobe -- --quality=1,0` and `-- --seal-procedural`, 1280x720, seed 4242, other
  workers idle): "OR, the seal close up" 120 fps at q1 and 144 at q0 with the model (129 draws), 104
  and 137 with the procedural seal (159-162 draws); "operating: bone saw" 144 / 163 with the model,
  156 / 160 procedural. Runs while another worker baked in Blender swung by 2x, so compare numbers
  only from quiet runs.

## The Blender humans in the game (2026-09-14)

Players, Bob, the paramedics and the downed player on the table use the Blender humans
(`art/human/`, `scripts/human/human_model.gd`); every Kenney path is still the fallback.

- **Bare faces are the weak point** (known from the art pass, not fixed by design): masks cover the
  players, Bob mostly lies on the table, but the paramedics' faces are stiff up close in a torch.
- **Cost: four walking teammates plus the paramedic crew in view run at about 65-77 fps against
  97-120 fps with the Kenney characters** (Radeon 890M, 1600x900, medium, `perfprobe -- --humans`);
  about 1.5 ms per character on the GPU (18-20k skinned triangles each against about 1k). Shadows are
  not it (`--noshadow`: 73-75 fps). Bob on the table costs nothing measurable (99-111 fps both).
  Mesh LODs for the skinned bodies or a cheaper distant body are the next step if it matters.
- **The first-person arms stay the hands worker's `fp_arms`** (a different look from the third-person
  surgeon: tinted sleeve and mitten hand).
- **The carry reads, but loosely**: the carried body hangs on the carrier's right shoulder from a
  fixed offset (`Player.HUMAN_CARRIED_SHOULDER`, sized for a 1.78 m carrier), so on the 1.68 m
  surgeon B it sits a few centimetres high; the carrier's arm across the legs does not grip them.
- **Arms are posed by direction, not IK**: held items sit in the hand bone's palm socket, but the
  forearm points along the pose direction with a fixed elbow rule, so the saw wind-up and the shove
  look stiffer than the clips.
- **Interact / PickUp one-shots only play standing still** (an interact while walking keeps the gait).
- **Downed players crawl with the Crawl clip frozen when not moving**; a dead bot lies in the same
  prone pose rather than on its back.
- **Bob's gown keeps its standing shape on the table** (a few centimetres above the belly and boxy at
  the shoulders) and its hem stands off the legs; the gunshot's gown window shows a flat rectangle of
  skin. The entry wound is moved from the model's flank site to 0.25 rad round the belly so the
  forceps' skin patch is level; the painted mask-B wound is not used (the game's wound overlay is).
- **The stump cap reads dark** in the OR light (the flesh texture on the model's cap), and the
  infection tint stops short of the cap. The severed forearm is CPU-skinned once when the saw finishes
  (`BobModelBuilder._bake_skinned`), because `bake_mesh_from_current_skeleton_pose` refuses a skin that
  has not been registered (hidden or not yet drawn).
- **The paramedics push by clip**: `Push` runs at the crew's speed and freezes when the crew stops,
  so a medic stops mid-stride; the front medic walks beside the gurney's head rather than pulling it.

## Dissection (sweep 3)

- **The strapped rig bodies are fitted by measured constants** (`monster_rig_look.gd` `RIG`: scale,
  offset, head bone, strap positions and heights, injection point, limb pivots). If the monsters
  worker changes a look's proportions or `make_lying`, the head can drift off the neck and the straps
  off the body: `tools/dissectiontest` fails its head-bone check (2 cm) and the table-fit check, but
  the straps have no check, so look at `tools/dissection_shots/01*`, `02*` after such a change.
- **The openable head is one ellipsoid**, not the walking look's two skull pieces, so the skull is a
  little rounder, and the face pieces are copied from `discharged_look.gd` / `walk_in_look.gd` (edits
  there do not reach the table). The Discharged's brow sits 6 mm further out so it does not sink into
  the ellipsoid; it keeps the walking head's bright, fine-noise band look, which under the OR lamp
  (plus the saw's guide glow on the forehead) reads a bit like a bandage. From beside the table the
  Discharged's ear bowl (pink with a dark canal dot) can read as an eye at a glance, exactly as it
  does on the walking monster in profile.
- **The rig body's back sinks about 4 cm into the table top** (the lying copy's gown back is lower
  than its legs; raised so the legs rest on the table). Hidden by the table from most angles.
- **Thrashing on the rig body moves whole limbs** from shoulder and hip (single-bone arms and legs, no
  elbows or knees); the straps over them stretch upward with the lift instead of holding them down,
  and the fingers do not curl. The chest does not breathe (the primitive body's torso breathing has
  no rig equivalent). The head only rocks a little (the operator works on it).
- **The primitive bodies (no rig) are plainer than Bob and the seal**: smooth lofts, a painted face
  with sphere eyes, no hands to speak of. Only used when the Kenney rig asset is missing.
- **The saw's calm guide glow shows on the forehead before anyone saws** (the same idle glow limbs
  have); the saw model itself is hidden until someone saws the skull.
- **The brain step's camera looks from past the end of the table**, so the body appears upside down
  above the opening (`05_brain_nerves.png`). Readable, but a surgeon standing at the head end would
  be the natural view.
- **The nerves are short**: the gap between the brain and the bone is 1-1.5 cm, so the cords are
  small; the rings carry the read. The rig heads are smaller than the old primitive heads (about
  0.11 m half length), so their brains are scaled to 0.92 of what the opening would fit to keep the gap.
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

## Pocket spaces (2026-09-14, pockets worker)

- **The pocket is rebuilt with every shift's wings, a little after them**: the wing loader finishes the
  wings, then the pocket takes another 100-200 ms of wall time (data on a worker thread, then 35-55 node
  steps within 5 ms a frame). Clock-in and the gates wait for it. A rebuild started from the dev panel
  during a shift spawns the new wings' loot and monsters as soon as the wings are done, before the pocket
  exists, so that pocket has no loot and no monsters until the next shift.
- **The first build of a session is slow**: a whole level build (`game._build_level`) finishes its pocket
  at once (`finish_now`), 60-220 ms on top of the hospital, with single steps up to about 90 ms the first
  time the pocket's meshes and materials are made (warmup makes most of them; the second build's slowest
  step is 3-8 ms).
- **Navigation regions update asynchronously**: right after a build the pocket's and the hospital's
  regions join the map a few frames apart. `tools/mapcheck.gd` waits for both; code that paths the frame
  after a build may get a hospital-only path.
- **Things the mirrors do not carry across a seam**: a player's head glow, held-item models' own lights,
  monster sounds (a Discharged's rattle is heard where it really is), the Echo outlines and Hive Eyes. A
  Walk-In does not see a player on the other side of a seam (its sight rays go to the real position), and
  the danger heartbeat counts only monsters in the same space. Hearing does cross: a noise within 26 m of
  a seam is mirrored into the other copy, pulled into the stub (the Discharged comes through and then
  hears the real noise).
- **Mirrors copy meshes, not animation state**: a mirror shares the body's skeleton, so it animates, but
  anything drawn without a MeshInstance3D (particles, decals, Label3D name tags) does not show, and blend
  shape weights (the human model's GashOpen) are not copied. The skinned human bodies mirror correctly
  (`tools/game_shots/p_*_ghost.png`).
- **Only moving items cross**: an item that settles (freezes) inside a stub's unwalked half stays there.
  A dropped item never settles before the host moves it, so this only happens to items placed there by code.
- **Pocket doors are only checked by mapcheck's grid test** (a doorway one tile deep, both sides walkable,
  no container in front); `DoorPlan.check`'s swing sweep runs on the hospital's plan, not on the
  pockets'. Their `max_out` is a fixed 90 degrees.
- **Eviction covers the pocket and the hospital-side stubs**, which the wing loader's own eviction does
  not see (stub tiles are zone 10). Someone standing in the pocket when the shift ends is put in front of
  the gate of the pocket's deepest connected wing, not the wing whose entrance they used.
- **The Restaurant's fourth entrance wall is the kitchen's back wall**, so an entrance can open into the
  kitchen between the stove and the sink (only when the dining room's walls are taken).
- **The pockets add loot, containers and monster spawn points** to the map's lists, so a map with a pocket
  has more loot, and a Discharged or a Night Nurse may spawn inside the pocket. `Monster.random_nav_point`
  can pick a pocket point, so hospital monsters sometimes wander into a pocket through a seam.
- **The Factory reads dim**: pools of high-bay light 12-20 m apart and the flashlight; the far walls are
  lost in the (per-pocket) fog on purpose. Its machines are primitive silhouettes.
- **The two copies of a stub are not pixel-identical**: the gameshot comparison (same pose in both copies,
  post effects off, flicker clock frozen) differs by a mean of 0.1-0.3% with a 99th percentile of 0.8-2.1%
  and single pixels up to about 29% (volumetric fog noise, the chamfered wall corners HospitalBuilder gives
  collision only, filtering). Stub geometry copies `HospitalBuilder._build_surfaces`' corridor rules by hand
  (`stub.gd` `build_copy`); a change to how hallways are drawn (doors' wall parts) must be mirrored there,
  and `tools/gameshot.tscn -- --pocket=...` prints the difference.
- **The playtest bot and pockets**: before the doors merge, seed 1 (with its Restaurant) failed with the bot
  wedged on a hallway trauma bag (`ct_20_24_0`); with the doors worker's bot it passes (`playtest --god`
  seeds 12345, 4244 (Factory), 3 and 1 (Restaurant) all clock out).
- **Perf** (`perfprobe -- --pockets --quality=1`, 1600x900, Radeon 890M, after the doors and human models
  merges): hospital corridor 126 fps (1% low 110) with no pocket, 118 (103) and 122 (107) on the two
  pocket maps; Factory hall corner to corner 127 (106), down a production line 127 (86), from the catwalk
  117 (91), an entrance from inside 193 (120), the seam from the hospital side 112 (90), from the pocket
  side 118 (88) and 97 (85) with two teammates standing in the hospital's copy (skinned human bodies drawn
  as mirrors, 4 mirror instances including their flashlights); Restaurant dining room 166 (119), bar 166
  (108), kitchen 81 (75), an entrance 102 (92), seam 110 (86), pocket side 121 (110) and 106 (97) with the
  two teammates. Earlier runs with Blender bakes on the machine read about half these numbers.
- **Rebuild frame times** (`pockettest -- --frames`, windowed 1280x720): from the next lobby's first frame
  until the wings and the pocket are rebuilt, the frames while the pocket builds are at most 18 ms (its own
  work at most 6.9 ms (Factory) / 8.1 ms (Restaurant) a frame, slowest step 3.3 ms, 54 / 21 ms on the
  thread, teardown 1.3 ms). One frame during the wings' part reaches 40-44 ms; `doortest -- --frames` on a
  map without a pocket shows the same (38 ms rebuilding, 36.5 ms with nothing rebuilding).
- **mapcheck's morgue tray anchors**: builds of seeds 112 (with or without a pocket) and 149 (with its
  forced Factory, which changes the wings' rooms) report one morgue tray anchor 2.6-3.4 m from the
  navigation mesh. Not pocket geometry; a hospital furnishing issue that the pocket plan can expose.
- **`mapcheck` takes about twice as long** (every seed is generated again with a pocket forced).
- **The Restaurant is very warm-orange** under the game's teal/amber grade; the tables' tops and the booth
  wood read dark from a distance.
## Doors and the per-shift wings (doors worker, 2026-09-14)

- **Ceiling fixtures still light through closed doors** (they cast no shadows, as they already lit
  through walls). The flashlight (a shadow caster) and every sight ray stop at a door.
- **The main entrance's glass blocks sight rays** like a solid door (its panels are on
  `C.L_WORLD`): nothing sees through it. Monsters never wander into the entrance building anyway.
- **A leaf folded open past 90% stops colliding** so bodies cutting a doorway corner do not catch on
  its end; a player hugging the jamb can clip a few centimetres into the open leaf.
- **About 3% of room doors have under 80 degrees of room on the hallway side** (furniture or a
  container near the doorway): they always fold into their tunnel, even toward someone coming out
  of the room, who has to step back while it swings (a bot gets shoved back a little). `DoorPlan.check` guarantees every door still opens wide enough to pass.
- **Doors respond on the host**: a client sees an automatic door start to open 100-200 ms after it
  walks into the sensor (3.4 m, which covers a sprint) and a hinged door after its E reaches the
  host. Nothing is predicted locally.
- **Agents open hinged doors by facing them within about 3 m** (bots and carriers within 1.3 m at a
  slant). A monster sliding along a closed door at a steep angle bumps it before it opens; the
  Night Nurse's door check samples three points at the doorway, not the whole leaf.
- **Players and bots inside a wing when it is rebuilt are teleported** to the entrance hall in front
  of that wing's gate. The normal rebuild starts when the paycheck screen ends, so a player who
  stayed in a wing sees the jump. Items left in a wing (on purpose or not) are gone with it.
- **The wing count (three or four) is fixed per run**: the entrance building's north doorways
  depend on it.
- **The dev panel's door tools in a hospital run** need a visit to the dev room first in that process
  (`DevRoom.tools_unlocked`); a friend's client that never entered the dev room has no panel.
- **A rebuild still shows as one or two 30-35 ms frames in a window** (1280x720, 890M,
  `doortest -- --frames`: 124 frames at 16.5 ms average, worst 33.8 ms, one over 33 ms; a quiet
  shift's worst was 20-31 ms). The first build of a run makes every container variant from
  scratch (a fridge 118 ms, the others 15-33 ms each) behind the loading screen; later rebuilds
  reuse the cached meshes. A container variant a run has not built yet (a new size or a new
  container type) costs its full 15-33 ms in the rebuild. Headless timings are noisy on a busy
  machine (8 ms against 59 ms for the same rebuild).
- **`ContainerBase.bake` is a doors hook in the containers worker's file** (the mesh cache above).
  A container whose parts change after `bake` would share its changes with every twin: none do today.
- **The playtest bot got pinned by a Night Nurse at seed 4242, shift 2** (3 of 6 runs, at
  (40.8, 70.3), no door within 4 m): the bot kept looking at her while she stood 0.2 m away, and
  in god mode she never lands a hit, so neither moved for the rest of the shift. The bot now backs
  off and sidesteps when it is stuck with a monster within 1.2 m; 4 runs since then all passed.
- **nettest `full_shift_lag` once hit the runner's 900 s timeout** (after the merge with main,
  with four other Godot processes running); the rerun passed in 87 s. Not investigated further.
- **`tools/monster_lab.tscn` prints `Nonexistent function 'action_of' in base 'Node (LabCombat)'`**
  since main's hands merge (the lab's combat stand-in lacks it); its 102 checks still pass.
- **`DoorPlan.check` re-samples with the plan's own geometry** (10 degree steps, 0.12 tile points
  along each leaf, obstacles grown by half the leaf's thickness): it proves the plan kept its rules,
  not that a finer sweep would never graze something.
- **Perf with doors (2026-09-14, medium, 1600x900, seed 4242, merge base and doors branch
  alternated twice, other workers' Godot runs going, so +/-25% noise)**: before / after average fps
  (1% low): lobby 128, 101 / 136, 93 (120, 80 / 110, 35); corridor 79, 60 / 103, 88 (62, 49 / 60, 72);
  OR 85, 72 / 97, 72 (60, 60 / 89, 45); pharmacy 149, 96 / 169, 120; neutral area 107, 77 / 124, 84.
  Draw calls: lobby 434 -> 402, pharmacy 142 -> 126, neutral 666-687 -> 550 (closed doors occlude),
  corridor 325-335 -> 333; nodes +730 (the door nodes). No scene got slower beyond the noise; the
  lone 35 fps 1% lows were single-run spikes. `perfprobe -- --doors` in one process: hallway draws
  254 without doors, 262 shut, 291 shut without their occluders, 284 open.
- **Quitting while the wings rebuild** waits for the thread and frees the detached old wings
  (`WingLoader._exit_tree`); before that a host quitting right after a clock-out crashed on exit.

## Testing tips

- Add `--fixed-fps 60` to headless runs: the game then steps as fast as the CPU allows (a 250 s
  shift takes about 20 s) with identical results.
- `tools/playtest.tscn` prints a heartbeat every 30 game seconds (target, position, hands).
- `tools/gameshot.tscn` includes `10_operating_hud`, a real operation in progress.
- `tools/minigame_lab.tscn` takes `--seed=N` for varied forceps channels and infection lines,
  and `--wide` for a camera that shows the body around the site.
- **`tools/devtest.tscn`'s "the dev room's furnace burns the defibrillator for $N" check is
  flaky** (gameplay-tuning worker, 2026-09-15): re-running the identical code back to back flips
  it between PASS and FAIL with the same expected `$N`, so `game.money` sometimes doesn't get
  credited before the check runs a fixed number of frames after the drop. Looks like a real-time
  race in the furnace's fire-zone detection versus the thrown item's physics settling, not
  anything sweep-specific; confirmed unrelated to this worker's shift-loop/patient-body/surgery-
  supply changes by bisecting against plain `main`, which shows the same flakiness. Needs the
  furnace check either to poll for the money change instead of a fixed frame count, or the burn
  itself to trigger off the drop event rather than a physics-zone check.

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

## Combat (sweep 3, combat worker)

- **Built against stand-ins for the monsters API.** On the combat branch `monster.gd` has no
  `take_hit`, `can_sedate`, `sedate`, `is_sedated`, `wake`, `dragged_by` or `sedation_left`, so
  `scripts/combat/combat.gd` uses guarded fallbacks: a monster dies after 2 saw hits (or its
  `max_hp`), a stagger is `game.knock_down_monster(m, dir, 1.0)`, "sedated" is a 76 s knock-down
  tracked in combat (replicated as `cb.s`), the lying look tips the monster's model onto its back,
  and combat pins a dragged monster itself (in `physics_tick` and `_process`). Each fallback turns
  itself off once the real method or field exists; re-run `tools/combattest.tscn` and the nettest
  `combat` scenario after the merge. The fallback lying Discharged keeps its IV pole standing
  upright beside it (`tools/combat_shots/05_sedated_prompt.png`).
- **Fallback only: shoving a sedated monster half wakes it.** `game.player_shoved` calls
  `m.shoved()`, which replaces the long knock-down with a 2 s stun; the monster then wanders while
  combat still counts it as sedated. Gone once `sedate()` / `is_sedated()` come from monster.gd.
- **The dragged monster can clip into walls.** It is pinned `DRAG_BEHIND` (1.15 m) straight behind
  the dragger with no collision; backing into a corner pushes it through the wall until you turn.
  Putting it down there lands it on the dragger's spot instead (`_point_is_clear`).
- **Resolved (hands, 2026-09-14): no arms on the swing, the jab or the drag.** First-person forearms
  and hands hold every item on its grip, the swing and the jab move the hand, other players hold
  the stack in the rig's right hand and reach back to drag (see "Hands, wind-ups and the carry
  camera" below).
- **The HUD hold bar says "LIFTING..." while you start dragging a monster** (combat reuses
  `Player.carry_hold` so the HUD needed no change). One word in `hud.gd` if it matters.
- **Prompts over a bright surface are hard to read.** The cream prompt text under the crosshair
  (`hud.gd _draw_prompt`, no outline) all but vanishes over the white patient table, so "Strap the
  Discharged to the table" is barely visible (`tools/combat_shots/06_drag_fp.png`). Not combat's
  code; an outline or a dark backing would fix every prompt.
- **Friendly fire respects invulnerability.** A teammate hit in the last 3 s (the normal
  post-hit invulnerability) takes no saw damage, but the swing still counts as a hit (noise, break
  roll). Deliberate, so a saw cannot chain-down a teammate.
- **nettest `combat` under `--lag=120 --jitter=40 --loss=0.03`** passed on the second run; the
  first failed before any combat, in the shared `_wait_shift_as_client` check ("saw crew=false
  subtitles=false" on client 2), the same kind of lag flake as `leave_items` above.

## Hands, wind-ups and the carry camera (hands worker, 2026-09-14)

- **Kenney proportions limit the third-person poses.** The surgeon rig has one bone per arm and no
  hands, shoulders at 0.77 m and a 0.9 m head, so a held item sits near knee-to-hip height in front
  and the jab's pull-back (the arm straight back, the torso twisted) is hard to read from the front
  (`tools/game_shots/26_hands_jab_windup_teammate.png`); the saw's raised arm and the shove's lean
  read well. The shared Blender human replaces the rig through `scripts/hands/rig_map.gd`.
- **The carry camera over a Kenney carrier shows a lot of head.** Over the left shoulder the
  carrier's big dark hair fills the lower right third of the view; the carried body shows at the
  right edge and the crosshair stays clear (`29_hands_carry_cam_player.png`). Pressed against a
  corridor wall the camera slides in over the head and the wall fills the left of the view
  (`29_hands_carry_cam_player_corridor.png`). Worth another look with the human model.
- **The carry camera's crosshair is beside the head.** The aim ray follows the camera's line, so
  things are aimed at the way they look, but at 1 m to the side a table right in front of the head
  needs the crosshair on it, not the head pointed at it (bots that aim by yaw from the head, like
  `tools/downedtest.gd`, use `bot_aim_id` and are unaffected; `tools/carrycamtest.gd` aims the camera).
- **nettest `combat` under `--lag=120 --jitter=40 --loss=0.03` is flaky here.** Of seven lagged runs,
  three on `--port=9970` lost every connection because another session was running
  `full_shift_lag` on the same port at the same time (use a free `--port`); on `--port=9990` three of
  four passed the combat checks, the other lost client 2's connection near the end (the known lag
  flake, with Blender builds holding the CPU at 70-100%). An early run showed the watcher a strike
  with no wind-up before it (a resent packet delivered both together); `MIN_SHOWN_WINDUP` covers that
  now. A resend can also stretch the host's measured gap between the wind-up and the release, so an
  over-long claim is capped to that gap + 0.3 s, not to the real hold (seen: 1.22 s held for a 0.25 s
  hold). Unlagged, `combat`, `monsters`, `downed` and `dissection` all pass.
- **Wind-ups make every use feel 0.2-0.35 s slower** by design; the cooldown values are unchanged
  and start at the strike, so the saw's full cycle is 1.1 s (was 0.8) and the jab's 1.35 s (was 1.0).
  Tune `WINDUP_TIME` / cooldowns after playtests.
- **Predicted strikes on a client** play `WINDUP_TIME` after the click; the host's strike lands a lag
  later (the hit sound and damage follow), which reads as a slightly late impact at 120 ms.
- **The first-person hands are not lit by the flashlight** (`HANDS_LAYER` is off its cull mask, as
  the dev gun's first-person layer already was), only by fixtures and the head glow, so in a dark
  hallway they are dim silhouettes. Deliberate: in the beam they bleached white.
- **Hands can still clip a wall at extreme angles.** The pull-in uses three rays every 0.05 s; a thin
  pillar beside the view can slip between them.
- **A charged shove on a non-capturable monster** (the Night Nurse) behaves like a tap: she retreats.
- **perfprobe was run before and after on a busy machine** (see the final report); both sets are
  noisy (other workers' Blender builds). The probe's local player shows the new first-person hands in
  every scene (about 14 draw calls: palm, sleeve, finger and thumb pieces, the torch); remote bodies
  add an AnimationPlayer and a SkeletonModifier3D each (no teammates in the probe).

## Controls, ability slots and HUD, scanner (sweep 4a chunk 1, docs/SWEEP4A.md)

- **The rebind screen has no conflict detection.** Settings > CONTROLS > KEYS (crouch, jump, ability
  modifier, scan) writes straight to `Settings.set_value("key_*", ...)`, which rebinds the matching
  InputMap action immediately, but nothing stops binding two of these (or one of these and an
  existing fixed action like `interact`) to the same physical key, and there is no "already in use"
  warning or reset-to-default-only-this-key control (only "Reset to defaults" for everything).
- **The scanner's range/LOS check is a single centre raycast**, not a cone: `game._scan_aim` requires
  the crosshair to be essentially on the monster (mask `L_WORLD | L_MONSTER`), same as the aim ray
  used for interactables. It works, but is stricter than "aiming at it" might suggest for a moving
  target at range.
- **Crouch's third-person pose is a single fixed-weight torso lean** (`body_poser.gd`'s new `crouch`
  field, ~0.3 rad), independent of whatever `body_hands.gd` sets `torso`/`torso_w` to for a held
  item, carry or wind-up pose, rather than a rig-aware crouched stance blended with those poses.
  Reads correctly (a stooped lean) in the common cases; not verified against every hold pose.
- **`game.database` (the scanner's sighted/scanned records) has no reset hook.** It is host-only,
  in-memory, and intentionally not cleared on `reset_money()` / game over the way `brains.on_reset()`
  clears absorbed brains — species knowledge is meant to persist across a wipe with money — but
  nothing has exercised that assumption yet (chunk 4 is expected to formalize it when the database
  is saved to disk).
- **Screenshots were not taken.** `tools/gameshot.tscn` needs a windowed run; this chunk was built
  and tested entirely headless, and grabbing 1-3 screenshots was judged not worth the added run in
  this pass (the spec allows skipping them when they prove awkward in a headless environment).

## The fog lot, the ambulance, and the safe zone (sweep 4a chunk 2, docs/SWEEP4A.md)

- **The pharmacy and crematorium reservation overlaps existing lobby furniture.** `entrance.gd`'s
  `spots["reserve"]` picks the lobby's two corners (near the west chairs/tv and the east reception
  desk/plant) rather than genuinely free floor -- there was none without widening the entrance
  building's fixed footprint, which felt like more risk than this chunk's "just reserve the space"
  ask justified. Chunk 3 will need to clear or work around a plant, a wall clock, a chair row or
  two, and the TV when it builds there; nothing is load-bearing.
- **The relocated shop placeholder is just an aim box.** `economy.gd`'s "attached" mode (used
  because `level_info.neutral` still has a `shop` key) builds only the interactable/aim-box/sign,
  expecting the level's own van mesh nearby -- there is none any more, so today it is an invisible
  hit box floating in the reserved pharmacy space. Functions correctly (buys a gold bar, same as
  before); chunk 3 replaces it with the real pharmacy window regardless.
- **The fog's depth/steering falloff is a simple square (max of the x and y overshoot past the
  clear rect), not a rounded one**, so the very corners of the belt are very slightly "deeper" for
  the same straight-line distance than the middle of a side. Cheap and unnoticeable in practice
  (`fog_ring.gd`); a distance-to-rect field would be marginally more correct.
- **The screen-space fog look and the audio low-pass are tuned by eye** (`FogRing.MARGIN_M` /
  `BLIND_M` / the density and cutoff-Hz curves in `fog_ring.gd` and `audio_manager.gd`), not
  validated against a target "can't see your hand" distance in an actual playtest -- only checked
  programmatically (depth goes to 0 outside the belt, visibility01 saturates at `BLIND_M`).
  **Follow-up (still chunk 2):** the first playtest of this build showed the actual gap the note
  above was flagging -- the per-camera tint only engages once the *local player's own* position is
  deep in the belt, so standing at the doors (or anywhere in the clear area) the lot's real border
  wall was plainly visible with nothing atmospheric between you and it, and several street lights
  from the old parking-lot layout sat right at or past the outer edge, directly lighting that wall.
  Fixed both: `hospital_builder.gd`'s `_build_fog_belt()` drops a real local `FogVolume` (world-
  space, sized off the same `neutral_rect` / `MARGIN_M` math as `fog_ring.gd`, `FOG_BELT_DENSITY`
  = 3.0, `edge_fade` = 5.0 -- picked by eye against `tools/fogshot.tscn` screenshots, not measured)
  so the fog reads as atmosphere from any vantage point, and `neutral.gd`'s street lights were
  pulled back inside `FogRing.inner_rect`'s clear area. Two things this did *not* fully fix, both
  minor: one of the repositioned lamps still throws a faint beam far enough down its facing axis to
  catch the wall at a distance (a light-range/aim tweak, not a placement bug), and the ambulance's
  own headlights light up the wall behind the bay while it's parked there -- expected, since the
  brief calls for the headlights to "glow through" the fog. `FogVolume` only renders when
  `Environment.volumetric_fog_enabled` is on, which the LOW quality preset turns off (see
  `look.gd`); on LOW the lot's fog is whatever the base depth `Environment.fog` gives it, same as
  everywhere else in the level -- not specifically re-tuned for the lot as part of this pass.
- **A pre-existing nav-coverage flake, unrelated to this chunk:** `mapcheck.gd`'s build pass
  occasionally reports one container/anchor "out of reach" by 2.5-3.5 m (seen on seeds 13 and 49 of
  120 in this pass, always a morgue tray). Reproduced on both this branch and (by inspection) code
  paths this chunk never touches (`room_furnish.gd` / container placement); left alone as out of
  scope for the fog lot work, worth a look from whoever owns the morgue/container layout.

## Pharmacy, crematorium, charged throw, placebo pills, no gold (sweep 4a chunk 3, docs/SWEEP4A.md)

- **The pharmacy and crematorium footprints still overlap the lobby furniture chunk 2 flagged.**
  Neither `economy_props.gd` (the pharmacy window) nor `furnace.gd` (the crematorium) touch
  `entrance.gd`'s furniture placement (it is not in this chunk's file list), so the reserved
  rects can still land partly on the chair rows/TV/plant/wall clock near the lobby's west and east
  ends depending on the seed. Nothing is load-bearing and the pieces are all static meshes, but a
  furniture piece can visually poke through a wall or the grate. Whoever owns `entrance.gd`'s lobby
  layout should either clear those rects when placing furniture or nudge the reserve away from it.
- **The furnace's "grate blocks bodies, gaps let items through" safety rule is geometry, not a
  simulated rule.** The steel bars are spaced to block a standing/crouching player capsule while
  leaving room for a thrown pill or small loot stack; it has not been verified with an actual
  player colliding at speed (sprinting into it, being shoved into it) or with every loot kind's
  collision box, only by eye against the model. If a bulky item (a defibrillator, an ultrasound)
  turns out to fit through a gap it would sell same as anything else; if a small monster or a
  carried body's collision shape turns out thinner than a bar gap it could in principle slip
  through. Worth a pass with `tools/perfprobe.tscn`'s scenario plus a live playtest shove-into-the-
  furnace check.
- **The pill mid-air hit check is a per-frame distance poll (`Game.pill_check_hit`, radius
  `PILL_HIT_RADIUS`), not a swept collision.** At the charged throw's top speed (`THROW_MAX_SPEED`
  11 m/s) and 60 Hz this covers less than the hit radius per tick so it should not tunnel through a
  target, but it has not been stress-tested under lag/jitter (nettest's `economy` scenario throws
  at a stationary furnace, not at a moving player or monster).
- **The pharmacist's silhouette (`economy_props.gd`'s `_shape_body`) is a capsule that drifts and
  blinks out of view on a fixed sine schedule**, not tied to any real presence or footstep audio;
  it is pure set dressing, the same on every machine (deterministic by `_shape_t`, which is not
  synced across clients -- each machine's pharmacist drifts on its own clock, imperceptible at this
  scale but worth noting if it is ever made game-relevant).
- **Chunk 4 owns the placebo pill database entry.** `Items.ITEMS.placebo_pills` exists and the item
  works end to end (buy, throw, hit, eat), but there is no guide/terminal entry for it yet; the
  text chunk 4 should use is in `docs/SWEEP4A.md` section 3e (*Placebo (sugar pill). Efficacy:
  disputed. Side effects: optimism.*).
- **The tube delivery capsule always thunks out at the same wall slot regardless of who bought it
  or how many players are around**, and if two purchases queue back to back the second capsule
  waits invisibly (no visible queue) until the first clears. Fine for one bottle at a time; would
  need a visible queue or multiple delivery slots if the pharmacy ever sells more than one item.
- **`tools/inventoryshot.gd`, `tools/braintest.gd`, `tools/brainshot.gd`, `tools/looptest.gd`,
  `tools/nettest.gd`, `tools/mapcheck.gd` and `tools/perfprobe.gd` were updated to compile and stay
  gold-free** (the old sell bin/shop/gold pile flows they drove no longer exist), but only
  `inventorytest.gd`, `mapcheck.gd`, `devtest.gd`, `looptest.gd` and one `playtest --god` were
  actually run this pass per the sweep's token budget; `nettest`'s `economy` scenario, `braintest`,
  `brainshot` and `inventoryshot` were updated by inspection only and not executed.
- **Follow-up (still chunk 3): the crematorium was unreachable on some seeds.**
  `economy.gd`'s `_rect_spot()` finds the furnace/pharmacy's floor height by casting a ray down
  from `probe.y + 1.5`; with `probe.y = 2.0` that ray started at world y=3.5, which is *above* a
  normal lobby ceiling (`C.WALL_H` = 3.0) wherever the reserved rect's centre has full ceiling
  coverage. The ray hit the ceiling's underside first and reported that as "the floor," so the
  furnace was actually built a full storey up, floating on top of the lobby ceiling with nothing
  able to reach it -- `looptest.gd`'s bot-driven furnace throw timed out every run (0/90s) even
  though `inventorytest.gd`'s manual furnace check passed, because that test's own `teleport()`
  put the player directly at the (wrong, elevated) furnace position rather than walking there from
  the real floor. Fixed by lowering the probe to y=0.3 (`probe.y + 1.5` stays under any normal
  ceiling). Also widened the grate from 6 bars/~0.13 m gaps to 3 bars/~0.37 m gaps
  (`furnace.gd`) -- the narrow gaps meant a few centimetres of aim/position drift, well within
  normal player variance, was enough to clip a bar instead of scoring; this was a real usability
  gap independent of the placement bug. The lobby-furniture overlap noted above is unrelated and
  still open.

## Database terminal, guide removal, Hive Eyes and Echo polish (sweep 4a chunk 4, docs/SWEEP4A.md)

- **Hive Eyes cycling and the hold-to-exit key (level 2+) were not built.** `docs/SWEEP4A.md`
  asks for: at level 1 tapping the slot ends it (built, unchanged from sweep 3); at level 2+
  tapping cycles to another Walk-In in range and holding the slot ~0.4 s ends it. Cycling needs
  `brains.ability_slot()` to pick a different Walk-In and retarget the same hive session instead
  of ending it, and holding-vs-tapping needs real key-hold timing, not just the existing discrete
  press counter (`Player.ability_slot_press`, incremented once per press with no duration). Both
  would mean widening the replicated ability-press protocol; judged out of proportion to this
  chunk's budget. What *is* built: `hive_view.gd`'s state machine already has a `_begin_cycle()`
  path (a short fly-through between two Walk-Ins) ready for whoever wires the trigger up, and
  ending Hive Eyes still works today exactly as it did in sweep 3 (the slot again, or Esc, both via
  `ability_slot_press`). At any level, only the nearest Walk-In in range is ever picked.
- **The fly-through's "no path" straight-line glide was exercised, but only informally**: the test
  hospital's break room to a nearby Walk-In always has a navmesh path in practice, so
  `databasetest`/`braintest` never hit the `NavigationServer3D.map_get_path` returning empty case
  in a real level. `hive_view._path_from` falls back to a straight line correctly by inspection
  (and the fallback branch is exercised by construction whenever the map iteration id is 0, e.g.
  the very first physics frame after a level loads), but nobody has watched it happen on a level
  where the Walk-In truly has no path to the player (e.g. across a locked door).
- **The database terminal's Monsters section is a fixed, hand-written list**
  (`scripts/database/monster_pages.gd`), not derived from any shared "monster kind" registry --
  there isn't one yet. Adding a new monster kind means adding an entry there by hand; nothing
  checks that the list matches whatever `Monster.kind` values actually exist at runtime.
- **The X-ray is a simple 2D silhouette-plus-marker drawn in the terminal UI**
  (`TerminalUI.TerminalSilhouette`), not a real render of the creature's actual 3D model with its
  brain highlighted inside it. Reads clearly as "here is roughly where the brain sits" but is not
  a literal X-ray of the in-game model.
- **The database terminal's own UI is plain Controls and Labels**, not a bespoke "computer
  terminal" look (no CRT curvature, no scanlines, no monospace terminal font) -- functional and
  readable, but visually plainer than the old guide binder's hand-crafted paper aesthetic it
  replaces. No custom shader was added for it either way, so this did not need a
  `Minigame.cached_shader()` registration or a `warmup.gd` entry.
- **The terminal and Hive Eyes' glazed-eyes glow use plain `StandardMaterial3D`s**, not registered
  in `scripts/warmup.gd`: neither is a custom shader, and both are visually similar to dozens of
  other emissive materials already exercised well before a player can reach the break room or
  trigger Hive Eyes, so a compile-time hitch was judged very unlikely. Not measured with
  `perfprobe` specifically for this chunk (chunk 4 was not asked to run it).
- **A guest's own scan/harvest is recorded on the host correctly (tested with a second bot `Player`
  at a different peer id in the same process, `databasetest._guest_scan_lands_in_host_db`), but the
  client-side "your terminal sees the host's data" path (`db_update` / `db_full` /
  `request_database_sync`) was only exercised by direct function calls, not over real ENet/Steam
  with lag** -- this chunk was told not to run `nettest_run.gd`; that is the final integration
  step's job.

## Sweep 4A final integration (docs/SWEEP4A.md, 2026-09-15)

- **`tools/nettest.gd` had three real breaks against the merged sweep**, none caught by any
  individual chunk (each was told not to run `nettest_run.gd` to keep its own token budget down):
  the `brains` scenario called the removed `best_path()` API and asserted on the Hive Eyes camera
  before its new fly-through (chunk 4) had time to land; the `economy` scenario asserted on money
  before a furnace sale could register, aimed throws with a fixed world-space offset instead of
  the furnace's actual (rotated) facing, and had no recovery from a throw physically missing the
  grate. All three fixed; `brains` and `economy` now pass under `--lag=120 --jitter=40 --loss=0.03`
  (economy correctly reaches $505 after selling a laptop and a gold watch and buying 3 pill
  bottles).
- **`combat`'s nettest scenario fails under injected lag** (`--lag=120 --jitter=40 --loss=0.03`):
  the host times out waiting to see a client's over-long melee-charge claim get capped. Confirmed
  pre-existing and unrelated to any of the four chunks -- passes cleanly with no lag, and nothing
  in `docs/SWEEP4A.md`'s scope touches `combat.gd`/`windup.gd`. Nobody had run this scenario with
  lag before (only `full_shift_lag` gets lag by default); left as a known issue for whoever owns
  the melee/windup system rather than expanded sweep 4A scope.
- **The `economy` scenario also lost its connection once, separately from the throw-handling
  fixes above**, during the shift-1-to-shift-2 transition under the same lag settings (client rtt
  spiked to ~1.8s before disconnecting). Only seen once, not reproduced on a second run in this
  pass; flagged in case it recurs for whoever next runs nettest under heavy lag around a wing
  rebuild.

## Toggleable OR doors (polish-or-doors, 2026-09-15)

- **The OR's doors changed visual style, not just behavior.** They were the only "auto" kind
  (heavy steel, automatic, like a wing gate without the lock); reassigning them to "double"
  (the quick win the code review flagged, and it held up) means they now render as the lighter
  double-swing model used by the cafeteria/radiology/morgue, since that is the model the manual
  E-to-interact "double" kind actually draws. Nobody asked for a new "manual but still heavy
  steel" look, and building one would have been exactly the "new engineering" the review said to
  avoid, so this was left as-is. Worth a look if the OR is ever meant to read as heavier/more
  clinical than an ordinary double door.
- **The `auto` door kind is now unused** (kept in `door.gd`/`door_models.gd`/`door_plan.gd` and
  `scripts/warmup.gd` rather than deleted, in case a future room wants a genuinely automatic pair
  again). If nothing ever reclaims it, it is a candidate for removal.
- **The paramedic crew's push-open margin against the OR doors is tight by design geometry, not
  by choice.** The crew only lines up squarely with the doorway (the same facing check a bot uses)
  a fraction of a second before actually crossing the door plane, because its nav path only turns
  to face the doorway right at the corner into it. In the seed exercised by `tools/doortest.gd`
  the doors are still ~85-100% open by the time the gurney reaches the plane, which reads fine,
  but this hasn't been checked across other seeds/layouts. If a future hospital layout puts a
  longer straight run in front of the OR (or a sharper last-second turn), it is worth re-checking
  that the doors still finish opening before the gurney model visually reaches them.
- **Crew door-pushing was deliberately scoped to just the OR's own doors** (`doors.gd`:
  `kind == "double" and data.base`), not every hinged/double door in the hospital. The naive first
  pass (removing the old blanket "crews never push doors" exclusion for every door) worked for the
  OR but let a real, independently-spawned Walk-In monster wandering the live shift push open an
  unrelated room door mid-test, corrupting later doortest checks that assumed it was untouched.
  Scoping crew pushes to the OR's doors specifically fixed it and matches the fact that crews never
  walk anywhere else in the hospital. If crews ever gain other destinations (e.g. a second delivery
  point), this scoping will need revisiting.
- **Follow-up (found during independent verification): the crematorium grate was still borderline
  for the widest loot.** `devtest.gd`'s furnace check (throwing a defibrillator, 0.36 m at its
  widest) failed intermittently at the earlier 0.4 m bar spacing (~0.36-0.37 m gaps, from the
  pharmacy chunk's own follow-up fix) -- close enough to clip depending on tumble. Widened grate
  spacing from 0.4 m to 0.45 m (`furnace.gd`, both the visual bars and their matching collision),
  giving ~0.40-0.42 m gaps: comfortable margin above the defibrillator's width, still well short
  of `C.PLAYER_RADIUS * 2` (0.8 m) so the "no body fits through" rule holds. Unrelated to the OR
  doors change itself; caught only because it happened to fail on this run's dev-room pass.

## Fog lot rework (2026-09-15, user follow-up)

- **The fog belt was rebuilt for a hard, opaque transition instead of a gradual haze.** Prior
  tuning still left the border wall faintly visible and let the flashlight visibly punch through
  the fog. Changed: `fog_ring.gd`'s `BLIND_M`/`STEER_START_M`/`SNAP_M` are all much smaller now
  (full blindness lands within ~2m of the clear area's edge, not ~5m), the screen-space fog's max
  density and depth range were raised for genuine near-camera opacity (with `fog_light_energy`
  cut low to avoid a bright nearby light blooming into a white haze -- caught by an actual
  screenshot showing the ambulance's headlights washing the whole frame white before this fix),
  and `hospital_builder.gd`'s real `FogVolume` was rebuilt as 3 strips (west/east/south; the
  entrance/north side needs none) that start exactly at `FogRing.inner_rect()`'s own edge instead
  of the old single box centred on the whole lot with a soft `edge_fade` -- the visible atmosphere
  and the "you are now blind" screen-space math begin at the same line. The player's own flashlight
  is now also explicitly dampened (range/energy/volumetric-fog-energy) as fog depth rises, fully
  off by 60% of the way to blind, local-only (`Player._set_flashlight_fog_dampen`) -- otherwise a
  bright close-range spotlight kept partially cutting through even very dense ambient fog.
- Verified with fresh `tools/fogshot.tscn` screenshots (the wall is not visible in any of the
  three shots; the flashlight produces no visible beam once fully in the fog), `fogtest.tscn`
  (0 failures), `mapcheck.gd` (20 seeds, determinism holds), `perfprobe.tscn`'s "lot, facing the
  fog" scenario (60fps all tiers), and `playtest --god --seed=1` (PASS).
- Not independently verified: the ambulance's headlights are still meant to "glow through" the fog
  by design (`docs/SWEEP4A.md`), and the tuning above was chosen to keep that visible without
  reintroducing the earlier white-blowout bug, but only checked at the one seed/pose the
  screenshot tool uses -- worth another look on a live playtest with a human watching the
  ambulance sequence end to end.

## Pause menu exit buttons (exit-menu-buttons, 2026-09-15)

- **No confirmation dialog on either exit button.** Both "Exit to Main Menu" and "Exit to
  Desktop" fire immediately on click, same as the existing Q-to-walk-out shove action and F11/F2
  shortcuts elsewhere in the game. Consistent with the game's existing minimal-friction pause
  controls, but a misclick mid-shift now has no undo (Exit to Main Menu at least keeps you in the
  app; Exit to Desktop does not). Worth a confirm-are-you-sure step if playtesting shows misclicks.
- **The two new buttons are plain `Button` nodes stacked under the pause-only "Settings" button
  in `scripts/settings_screen.gd`, not part of the HUD's immediate-mode pause overlay text** (the
  "PAUSED / Esc to resume, Q to walk out" lines drawn by `hud.gd`). This matches how the existing
  Settings button was already built (real controls can't live in an immediate-mode `_draw()`), but
  means the HUD's own hint text still doesn't mention the new buttons, and a future redesign of
  the pause overlay should keep this split in mind rather than expecting one place owns "everything
  drawn while paused."
- **Not verified**: an actual mouse click on the buttons in a real (non-headless) session — the
  automated tests exercise them via `pressed.emit()`/`_toggle_pause()`, and the nettest host_quit /
  host_kill scenarios (which cover the same `Net.leave()` teardown path "Exit to Main Menu"
  reuses) both still pass. Layout/positioning has not been screenshot-checked at other
  resolutions.

## Interactable affordance: aim highlight replacing floating labels (2026-09-15)

- **Only two always-on `Label3D` props were actually found and replaced**: the OR supply shelf's
  "SUPPLY - SURGICAL" tag (`scripts/supply_shelf.gd`) and the break-room blender's "BLENDER" tag
  (`scripts/brains/blender.gd`). Both are gone outright; `AimHighlight` (`scripts/aim_highlight.gd`)
  plus the existing crosshair prompt now carry the "you can interact with this" signal instead.
  `scripts/economy/economy_props.gd` and `scripts/economy/furnace.gd` (the pharmacy window and the
  furnace, which also carry price/amount `Label3D`s) were deliberately left untouched -- a sibling
  worker owns those files for the entrance/lobby rebuild, and this sweep was scoped to the generic
  system, not a specific room's props. Whatever they build there picks up `AimHighlight` for free
  once merged (it works on anything in group `"interactable"`), but their own labels (price tags,
  not "this is interactable" labels) are that worker's call to keep or change.
- **`scripts/downed/player_table.gd`'s "STAFF" tag was left as-is.** It reads more like an identity
  label (which table is which, similar in spirit to the hospital's own room-name signs) than a
  "you can interact with this" cue, and the table's own aim highlight now covers the latter. Worth
  a second look if it turns out players read "STAFF" as redundant once they get used to the rim.
- **The blender's highlight is hard to see in a screenshot taken close up and level with its own
  overhead lamp** (`tools/affordanceshot.tscn` shot `d_blender_aimed_highlight_on.png`): the lamp's
  own bright bloom washes out the thin rim on the jar and motor housing at that framing. Confirmed
  by instrumentation that the rim shells are actually created (6, `AimHighlight.MAX_MESHES`), so
  this is a lighting/screenshot-framing issue, not a mechanism bug -- the same rim reads clearly on
  the supply shelf's steel frame in the same run. Worth a look with a wider shot or the lamp dimmed
  if the blender specifically still feels unclear in a real playtest.
- **No other floating always-on interactable labels were found** in a full `Label3D` grep of
  `scripts/`: the rest are either transient (the pharmacy's `_spawn_pill_line` flavor quotes in
  `game.gd`, which rise and fade on their own), dev-only (`scripts/dev/dev_level.gd`,
  `scripts/dev/dev_dispenser.gd`), debug gizmos (`scripts/patients/patient_kit.gd`'s axis labels),
  or player name tags (`scripts/player.gd`), none of which are the "bright out of place room/prop
  label" the affordance sweep was about.

## Gameplay tuning (2026-09-15/16, user follow-up): a furnace-throw test flake, again

- **`tools/devtest.gd`'s furnace check (throwing a defibrillator for $408) was flaky** even after
  the pharmacy chunk's grate-widening fix (0.45m spacing) and the money-timing fix already applied
  elsewhere -- a charged throw can still, occasionally, physically miss the grate by design ("missed
  throws bounce off the frame"). This is the same underlying behavior already worked around in
  `inventorytest.gd`, `looptest.gd` and `nettest.gd`'s furnace checks, just not yet in `devtest.gd`.
  Added the same retry: if a throw misses and the item bounces back nearby, pick it up and throw
  again (up to 8 attempts, then one more `_until` wait) instead of treating one miss as fatal.
  Reproduced the original flake locally, then ran the fixed check clean twice in a row.
- With five now-independent places carrying a near-identical "wait for money, retry on a miss"
  workaround (`inventorytest.gd`, `looptest.gd`, `nettest.gd`, `devtest.gd`, and the furnace's own
  grate width in `furnace.gd`), the actual mechanic might be worth a second look for tightening the
  throw's success rate directly (a slightly wider grate again, or less random tumble on a thrown
  item) rather than continuing to paper over misses in every test that throws something.

## Hub redesign: pharmacy/crematorium rooms, kiosk, terminal desk (hub-redesign, 2026-09-15)

- **`tools/looptest.gd` (seed 4242) can fail with both patients dying**, not required by this
  sweep's test list but run as extra diligence. Isolated (by swapping just `entrance.gd` between
  the old and new hospital layout, everything else held constant) to the entrance restructuring
  specifically, not the pharmacy/furnace/terminal scripts themselves: `tools/inventorytest.tscn`
  and `tools/devtest.tscn`, which exercise the same kiosk/furnace/terminal through direct
  teleport-based interaction, are unaffected and pass reliably. The failure is a real bot
  (`NavigationServer3D`-driven, not a teleport) getting permanently stuck -- `_stuck` climbs
  without bound and it never recovers -- partway to the OR shelf, at a position inside a north
  wing (tile roughly (2.75, -4) relative to the entrance origin, well outside the new rooms'
  footprint) that the ORIGINAL entrance layout's bot walks through in under two seconds for the
  identical seed. Wing content itself is unaffected (`Entrance.build()` takes no RNG, so the
  hub redesign cannot have shifted wing generation), so this reads as a pre-existing pathing or
  door-state edge case in that wing, newly exposed because the hub redesign's furniture moves
  shifted the bot's upstream timing (which loot it grabs and when) enough to route it into a
  different container choice than before. `tools/nettest_run.gd -- --only=economy` timed out the
  same way (a real bot failing to reach the kiosk/furnace under real movement, not the direct
  interaction both `inventorytest` and `devtest` cover) and is suspected to be the same root
  cause. Not root-caused further within this sweep's budget -- worth a look from whoever owns
  wing navigation/doors, starting from that specific stuck position and seed.
- **The database terminal's live screen only renders a real picture with a hardware GPU
  renderer.** `tools/perfprobe.tscn` ran headless (`--rendering-driver` unset defaults to a dummy
  renderer in this environment) and reported "draws 0" for every scenario, so its numbers don't
  reflect the SubViewport's actual GPU cost -- only that the CPU-side script work
  (`terminal_screen_live.gd`'s per-frame camera copy, gated to 4.5 m / 8 Hz) stayed cheap. Worth a
  real windowed perfprobe pass near the terminal on real hardware before trusting the 192x120/8 Hz
  numbers as final.
- **Crematorium and pharmacy screenshots were taken from the existing close-up poses**
  (`tools/inventoryshot.gd`'s `05`-`08` shots stand 2.0-2.4 m back, which mostly fills the frame
  with the flashlight cone in this game's dark lighting) rather than a new wide establishing shot
  of each room. They confirm the mechanics (kiosk prompt, delivery, throw-to-sell) and the Night
  Nurse's model rendering correctly, but not a clean wide view of the walls/archway/fire-through-
  a-hole read from a few metres back. Worth a dedicated wide shot next time inventoryshot.gd is
  touched.

**Follow-up (2026-09-16, independent verification before merge):** reproduced the `looptest.gd`
(seed 4242) death independently -- 2 of 3 unmodified runs failed the same way. Instrumented
`_go_use()` and confirmed the bot wedges at world position (52.128, -0.00003, 44.967), tile
(2.75, -4) relative to the entrance origin exactly as reported above -- position frozen to the
float, zero drift, for the entire stall (`alive=true downed=false stun=0.00`, `bot_move` held
forward the whole time), so this is a physical wedge against static geometry in that wing, not a
gate/flag blocking input. Ran the same seed 26/40-seed `mapcheck.gd` sweep on `main` before this
branch existed and got the identical "1 containers/anchors out of reach" failure at the same
morgue tray anchor -- confirms the wing-side issue is pre-existing and unrelated to the hub
redesign's footprint, not a regression it introduced. Root cause of the *wedge itself* is still
unfixed (needs the wing nav/collision owner, starting from that exact tile). What IS fixed here:
`_go_use()`'s stuck-recovery only ever applied to item pickups (`id.begins_with("it_")`) -- a
stall on a non-item target (`"shelf"`, a patient table, a container) had no recovery at all and
would hang the bot, and the whole shift, forever. Added a generic recovery: after 15s stuck on
any target, warp the bot to it and force a repath, same as a player would eventually route around
after strafing off a wedge. Re-verified: 7 of 8 runs clean after the fix; the one remaining
failure was the already-documented furnace-throw flake below, not this death cascade.

## Circular ability hotbar (2026-09-16)

Rebuilt the Alt+1..4 ability bar (`scripts/hud.gd` `_draw_ability_bar`) from flat rectangles to
circular icon slots, matching the vector/procedural style the rest of the HUD already uses
(`_draw_scan_ring`'s `draw_arc`, the hearts' `draw_circle`/`draw_colored_polygon`, etc. -- there
are still no raster HUD icons anywhere). Each slot is a filled circle with a per-ability glyph
drawn in a new `_draw_ability_icon()`: Echo is three concentric partial arcs plus a centre dot (a
sound pulse), Hive Eyes is an almond eye outline with a pupil. The old bottom cooldown bar is now
a radial arc that drains clockwise from the top; level pips sit in a row just under the circle;
the Hive Eyes "Walk-In in range" border pulse is now a ring drawn with `draw_arc` instead of
`draw_rect`; empty/unusable slots dim the same way as before, just on a circle. `_draw_ability_card`
(the unlock popup) doesn't reference the bar's shape and was left alone.

While rebuilding this I found and fixed a real, pre-existing bug in the big/small Alt-hold blend
(`_alt_t`): the ability bar was lerping its rect with the *same* `t` direction as the hands bar
(`_draw_hands`), so at `t=0` (Alt not held) it rendered at full/"big" size directly on top of the
hand-slot boxes instead of shrinking into its own small idle corner -- the two bars were meant to
swap spots, not overlap, per the hands bar's own comment ("cross-fade into each other's spot...
rather than overlapping"), but the ability bar's lerp was never actually inverted to do that. Fixed
by swapping which rect is the `t=0` vs `t=1` end for the ability bar only; the hands bar itself was
untouched. Also nudged the big-mode vertical anchor and the ability name label's offset, since the
new circles combined with the name/reason text were bumping into the bottom control-hint line at
1600x900 in the first pass.

Verified:
- `godot --headless --path . --import` re-imported clean after the script changes.
- No existing HUD-specific headless test tool exists (grepped `tools/*.gd` for `hud`/`ability_bar`/
  `_draw_ability_bar`; the closest is `tools/orscreentest.gd`, which covers the OR wall monitor, a
  different HUD layer, not this one).
- Added two poses to `tools/gameshot.gd` (`_pose_ability_bar_idle`, `_pose_ability_bar_alt`,
  shots `40_ability_bar_idle` / `41_ability_bar_alt`) that give the bot Echo/Hive Eyes via
  `game.brains.set_level()`, force one ability onto a cooldown, and toggle the `ability_alt`
  input action to capture both the idle-small and Alt-held-big states. Ran windowed (not
  `--headless`, which returns a null viewport texture) with `-- --only=ability_bar --tag=t3` and
  actually looked at the resulting screenshots
  (`tools/game_shots/40_ability_bar_idle_t3.png`, `tools/game_shots/41_ability_bar_alt_t3.png`,
  gitignored, not committed): circular slots, the Echo/Hive Eyes glyphs, the radial cooldown
  sweep, level pips, the dimmed empty slots, and the Alt-held big/small swap all render correctly
  with no overlap or off-screen elements after the `_alt_t` direction fix above.
- `tools/devtest.tscn` and `tools/inventorytest.tscn` headless: both still `result=PASS
  failures=0` (devtest) and `result=PASS checks=92 failures=0` (inventorytest), unchanged from
  before this change, confirming the HUD rework didn't touch anything those exercise.

Known gaps: the per-slot "why can't I use this" reason text (`_slot_reason`) is still drawn
centred on the *full* screen width per slot (`HORIZONTAL_ALIGNMENT_CENTER, w`), unchanged from the
original rectangle code -- if two slots ever have a reason at once (e.g. Echo cooling down and
Hive Eyes out of range simultaneously) their texts stack on top of each other at the same spot
instead of appearing over their own slot. Not introduced by this rework (the original rectangle
version had the exact same call shape) and not hit in the two abilities that exist today since
they're rarely both blocked at once, but worth widening to per-slot placement if a third ability
ever ships. The new icon shapes (concentric arcs / almond eye) are a first pass at "read clearly
at 26-52px" -- fine at both the idle and Alt-held sizes in the screenshots above, but not tested
against colourblind palettes or at ultra-low resolutions.

## Default over-the-shoulder camera (2026-09-16)

- **Made the default walking-around camera over-the-shoulder, generalizing the existing
  `scripts/camera/carry_camera.gd`** (previously only active while carrying a downed teammate or
  dragging a monster). `CarryCameraScript.wants()` now returns true by default too (a new
  `DEFAULT_OFFSET := Vector3(0.38, 0.12, 0.85)`, head-space x right/y up/z back), falling back to
  carrying/dragging's bigger `CARRY_OFFSET`/`DRAG_OFFSET` when those are active, and to true first
  person only when the new `Settings` key `default_camera` is set to `"first_person"` (mirrors the
  existing `carry_camera` key's plumbing end to end: `DEFAULTS`, `_sanitize`, `settings_screen.gd`'s
  choice row, and `settingstest.gd`'s coverage). `DEFAULT_OFFSET` is deliberately modest next to
  `CARRY_OFFSET` (arm length 2.28 m) and `DRAG_OFFSET` (arm length 3.76 m): about 0.93 m open,
  tuned by eye with `tools/hospitalshot.gd` (entrance lobby, a `WARD` doorway, the longest hallway)
  and a one-off wall-backed shot (see below) so it reads as "just over the shoulder" rather than a
  pulled-back third-person view, and so its own `HIDE_BODY_BELOW` (0.55 m) margin survives a modest
  wall pull-in without immediately flipping back to first-person hands.
- **The existing wall-avoidance, aim-segment correction and hands/body swap all now run for the
  default state too**, since it is active almost all the time rather than a rare carry/drag state:
  - `aim_segment()` took a `range` parameter (was hardcoded to `C.INTERACT_RANGE`) so
    `Player._update_scan_progress` (the scanner's local, cosmetic progress ring) applies the same
    "ignore what's between the camera and the head, reach measured from the head" correction with
    `C.SCAN_RANGE` that `_update_aim_core` already applied for interact. `game.gd`'s host-side
    authoritative `_scan_aim`/`_tick_scan` got the same correction, but only for whichever player is
    the host's own local player (`p.carry_cam != null and p.carry_cam.active`) -- the shoulder
    camera is local-only and not replicated (per this file's own doc comment: "nothing new on the
    wire"), so a remote client's shoulder offset still isn't known to the host. That mismatch is
    not new: it already existed for the rare carry/drag case; this just makes it come up far more
    often. Left unfixed (see gap below).
  - `hides_hands()` used to be `blend > 0.02` (hides the instant easing starts). Changed to mirror
    `_show_body`'s own condition (`_body_shown`) instead: a wall pulling the shoulder camera in
    close enough to hide the third-person body (now a routine occurrence in a corridor, not just a
    rare carry-into-a-corner case) hands the first-person hands/held item back rather than leaving
    both hidden. This is a behavior change for the carry/drag case too, but a strictly more correct
    one (no more both-hidden gap), and `tools/carrycamtest.tscn` still passes with it.
- **Test bots that aim from the player's own body position, not the camera, needed updating** --
  a shoulder-offset camera means "face the target with your body yaw" is no longer the same ray as
  "look at the target," exactly like a real player has to use the reticle rather than their
  shoulders. Found this via `tools/databasetest.gd`'s scan test (`_scan_unlocks_tier2`), which
  aimed by computing yaw from `me.global_position` and left pitch at a fixed 0.0 -- with the
  default offset's 0.38 m lateral parallax and 0.12 m raised height, the ray missed the monster's
  collider (it hit a wall past it) instead of undershooting onto its floor-level origin once pitch
  was naively corrected too. Fixed by aiming from the real `me.camera.global_position` toward the
  monster's centre (`+Vector3.UP*1.0`, matching how `game.gd`'s own `_scan_aim` measures distance),
  correcting both yaw and pitch every frame, the same idea `tools/carrycamtest.gd`'s `_aim_camera`
  helper already uses for the carry/drag case. `tools/carrycamtest.gd` also got two new checks
  (default play eases to the small offset and hides FP hands/shows the body; the `first_person`
  setting keeps it in true first person) and now sets `default_camera` to `first_person` for its
  own carry/drag-specific assertions, so "not carrying or dragging" still means true first person
  there.
- **Verified:** re-imported and ran the full mandated suite after the change --
  `tools/inventorytest.tscn` (92 checks, 0 failures), `tools/devtest.tscn` (0 failures),
  `tools/databasetest.tscn` (12 checks, 0 failures, after the scan-aim fix above),
  `tools/looptest.tscn` (0 failures except the pre-existing, already-documented furnace-throw
  flake above), plus `tools/carrycamtest.tscn` and `tools/settingstest.tscn` (both compared against
  the unmodified code on the same machine: `carrycamtest`'s 3 pre-existing failures in its
  wall-pull-in block -- "backed against a wall the camera pulls in," "never ends up behind the
  wall," "stays pulled in" -- reproduce identically before this change, so they are not a
  regression from it; every other check, including the two new default-camera checks, passes).
  Took real windowed screenshots (`tools/hospitalshot.tscn`, not headless, which only gives a dummy
  renderer): the entrance lobby, a `WARD` room doorway and the longest hallway all show the new
  default shoulder view clearly offset from dead centre, the crosshair still reading sensibly on
  the door/hallway centreline, and no wall clipping. Confirmed the `default_camera=first_person`
  opt-out with the same lobby pose: a true centred first-person view with the flashlight-holding
  hand back on screen. Confirmed the wall pull-in itself with a one-off scratch scene (reusing
  `carrycamtest.gd`'s own `_wall_spot()` finder, not committed): arm length pulled in from the
  open 0.94 m to 0.83 m backed into a corner, camera still outside the wall, no clipping.
- **Gaps not covered by this sweep:** the host-authoritative scan-aim mismatch for *remote*
  players' shoulder offset noted above (pre-existing, now more frequent); no dedicated screenshot
  of the wall pull-in was kept (the scratch scene's PNG was deleted after visual confirmation) --
  worth a permanent shot next time `tools/hospitalshot.gd` or a similar tool is touched; the tight
  wall-pull-in checks in `tools/carrycamtest.tscn` were already failing before this change and were
  not investigated further (out of scope here, see that test's own failures for what to reproduce);
  multiplayer with more than one real client was not tested (this is local-only per the file's own
  doc comment, so nothing changes there, but it also was not re-verified with `nettest.gd`).

**Reverted (2026-09-16, same day, user follow-up):** ordinary play is locked to true first person
again. The shoulder camera is carry/drag only, same as before this entry -- the user's intent for
the "over-the-shoulder default camera" audit item was specifically the carry/sling-a-body-or-
monster-over-your-shoulder camera (which already existed), not a permanent third-person-ish default
view. Removed `DEFAULT_OFFSET`/`default_setting_on()`/the `default_camera` Settings key and its
settings-screen row entirely (not just re-defaulted, since there is no longer a "default camera"
concept to toggle) from `scripts/camera/carry_camera.gd`, `scripts/settings.gd` and
`scripts/settings_screen.gd`; `CarryCameraScript.wants()` is back to returning true only while
`carrying != 0 or dragging_monster >= 0`. Left the generalizations that don't depend on the default
case -- `aim_segment(range)` taking a range parameter, `hides_hands()` tracking `_body_shown` -- in
place, since they're strictly correct improvements to the carry/drag case itself and cost nothing
now that the default case doesn't exist. `tools/carrycamtest.gd` and `tools/settingstest.gd` had
their `default_camera`-specific checks removed; `carrycamtest.gd` now asserts ordinary play is
locked first person (`blend 0.0`, hands visible) instead of exercising a setting toggle.

## Sprint + crouch-dive (2026-09-16)

Added a "sprint + crouch-dive" move to `scripts/player.gd`'s `_local_step`: pressing crouch while
sprinting and moving roughly forward (`input_dir.y < -0.5`, the same forward-input threshold the
rest of the file's movement code implies) fires a short diving lunge instead of dropping straight
into an ordinary crouch-walk. Client-owned local movement throughout, same as the rest of
`_local_step` (each machine simulates its own body from its own input; the host only sees the
20 Hz position/rotation snapshot, same as any other walk).

- **Numbers chosen:** an instant burst to `C.SPRINT_SPEED * DIVE_SPEED_MULT` (5.6 * 1.45 = 8.12
  m/s, comfortably faster than a plain sprint but not a teleport), linearly decaying back down to
  `C.CROUCH_SPEED` (1.8 m/s) over `DIVE_DURATION` = 0.4 s, then normal crouch/sprint movement
  resumes. `DIVE_COOLDOWN` = 2.5 s prevents chaining dives into a sustained speed boost. All three
  are new consts on `Player`, picked by feel within the ranges the brief suggested (1.3-1.6x sprint,
  0.3-0.5s decay, "a couple seconds" cooldown) and confirmed by the burst/decay/cooldown checks
  below, not derived from any existing constant.
- **Capsule reuses the existing crouch path, doesn't fork it.** `_apply_crouch()`'s `want_down` is
  now `(_want_crouch or diving) and not downed and carried_by == 0 and not on_table`, so `diving`
  forces the capsule to `C.CROUCH_HEIGHT` through the exact same resize call (and the exact same
  "refuse to stand under a low ceiling" raycast) an ordinary crouch already uses, even if the crouch
  key is released mid-dive. The instant `diving` clears (key released or `DIVE_DURATION` elapsed),
  that same raycast re-runs on the very next `_apply_crouch()` call and keeps the player crouched if
  something is still overhead -- there's no separate "was this a dive" bit to fall out of sync.
- **Not replicated as a new network field.** `diving` forces `crouching` true, and `crouching`
  already replicates (report bit 16 / `report_full`'s `"cr"`), so the flattened capsule height, the
  third-person crouch torso-lean (`_update_down_pose`'s `body_hands.poser.crouch` blend) and the
  lowered eye height all already show up on every other machine for free, the same way an ordinary
  crouch does. A remote peer doesn't need to know *why* someone is crouched, only that they are.
- **Blocked during the dive window:** interacting (E), the shove/use left-mouse actions, starting a
  charged drop, and Alt+1..4 ability slots -- mirrors how `downed`/`winding`/`dragging_monster`
  already gate those same call sites, just with an added `not diving`. Switching the selected item
  slot (plain 1..4 / scroll) was deliberately left allowed, since it's not "interacting" and there's
  no reason to block it. Jumping is already blocked for free (`want_jump` already requires
  `not crouching`, and diving forces `crouching`). Footsteps are already silenced for free too
  (`moving and is_on_floor() and not downed and not crouching` already gates both `_local_step`'s
  and `_remote_step`'s footstep audio, and diving forces `crouching`).
- **Bot support: added, via a one-shot bump counter (`bot_dive`), not the continuous `bot_crouch`.**
  The brief called this optional; went with "add it" because (a) it costs little -- a single
  edge-detected bump, `_bot_dive_seen`/`_bot_dive_fire`, exactly mirroring the existing
  `bot_jump`/`_bot_jump_seen`/`_bot_jump_fire` pattern a few lines above it -- and (b) it made real
  headless verification possible at all (`tools/controlstest.gd`, see below) instead of only being
  checkable by a human playtester, since bots can't type. `bot_crouch` alone still means an ordinary
  hold-to-crouch for bot scripts, matching how `bot_jump` firing a jump doesn't change what holding
  a movement key does; a human triggers the same move by physically pressing crouch (edge-detected
  via `_crouch_prev`) while sprinting forward, no separate input action added.
- **Verified:**
  - `godot --headless --path . --import` re-imported clean.
  - Added `_sprint_dive()` to `tools/controlstest.gd` (not one of the six mandated regression
    scenes, but the existing home for crouch/jump checks, so extended rather than duplicated):
    confirms `bot_dive` enters `diving`/`crouching` the instant it fires, the burst speed clears
    `C.SPRINT_SPEED * 1.15`, E does nothing while diving, speed measurably decays partway through
    the window, the dive ends on its own, an immediate second dive is blocked by the cooldown and a
    later one fires once the cooldown clears, and -- spawning a real `StaticBody3D` ceiling above
    the player mid-dive (elongated along the travel direction so it's only ever encountered while
    already crouched, never shoved into a standing capsule) -- a dive that ends under a low ceiling
    stays crouched exactly like letting go of an ordinary crouch there already does, and standing
    back up works again once the ceiling is removed. 14 of 14 new checks pass
    (`godot --headless --fixed-fps 60 --path . tools/controlstest.tscn`); found and fixed a real
    gating bug along the way (the bot-input path's `bot_press`/`bot_use`/`bot_charge`/`bot_ability`
    branches weren't checking `not diving` at all -- only the keyboard paths were -- so a bot could
    still interact/use/shove/ability mid-dive; the human paths were correct from the start).
  - Ran the full mandated regression suite: `tools/inventorytest.tscn` (92/92), `tools/devtest.tscn`
    (0 failures), `tools/databasetest.tscn` (12/12), `tools/looptest.tscn` (0 failures),
    `tools/settingstest.tscn` (97/97), and `tools/carrycamtest.tscn` (0 failures except the same 3
    pre-existing wall-pull-in failures documented above under "Default over-the-shoulder camera" --
    reproduced identically, nothing new). All unchanged from before this branch's work.
  - Real windowed screenshots (`tools/gameshot.tscn`, not `--headless`, which returns a null
    viewport texture): added `_pose_sprint_dive_prep`/`_pose_sprint_dive` (shots
    `42_sprint_dive_before` / `43_sprint_dive_mid`), a teammate bot sprinting then diving, watched
    by the local bot from a few metres back. First attempt used the same entrance-corridor spawn
    `_pose_human_gait` uses (`_open_ground()`), but that nook turned out too short: the dive's burst
    velocity reached a wall/door within a few frames and the collision visibly killed the very
    motion the shot was supposed to show. Factored `_pose_corridor`'s "longest clear sightline"
    raycast search out into a reusable `_longest_sightline()` and used that instead, which finds a
    real long ward corridor. Actually looked at the resulting screenshots: the "before" shot shows
    the teammate mid-stride, upright; the "mid" shot (9 frames / ~0.15s into the dive) shows her
    visibly leaning forward and lowered -- a clear posture change, not a teleport or a glitch, and
    debug prints during iteration (since removed) confirmed the underlying state matched what the
    picture shows (`sprinting=true` before the bump; `diving=true crouching=true` after).
- **Known gaps:** the dive's direction is locked to the heading at the moment it fires
  (`_dive_dir`, read once) rather than following the player's rotation for the rest of the window,
  so mouse-turning mid-dive doesn't curve it -- this was a deliberate design choice ("keeps its
  launch heading fixed" per the code comment), not a bug, but worth a second look if a playtest
  wants steerable dives. `tools/controlstest.gd`'s pre-existing scanner checks
  (`_scanner()`, holding R aimed at a Walk-In) fail on this branch (`holding R aimed at it builds
  progress`, `looking away resets progress`, `a full hold marks the species scanned`) -- confirmed
  unrelated to this work (nothing in this change touches `_update_scan_progress` or the scanner
  path, and `tools/databasetest.tscn`'s own scanner-adjacent checks pass clean); most likely the
  same "aim from body position instead of the real camera" gap the "Default over-the-shoulder
  camera" entry above already flagged for `databasetest.gd`, just not yet fixed in
  `controlstest.gd`'s older, unmigrated scan test. Not investigated further here since
  `tools/controlstest.tscn` isn't one of this task's mandated regression scenes and nothing in this
  diff touches scanning.

**Playtest follow-up (2026-09-16, user feedback):** four changes after a hands-on test.
- **Toggle sprint is now the default.** New `Settings` key `sprint_mode` ("toggle" default, "hold"
  available in the settings screen). Toggled sprint ends when every movement key is released. Bots
  still use `bot_sprint` as hold.
- **0.2 s grace window** (`DIVE_SPRINT_GRACE`): a crouch press just after sprint drops still dives.
- **It's a real dive now, not a ground slide.** The launch adds `DIVE_HOP_VELOCITY` = 3.0 m/s
  upward (~0.25 m peak, ~0.33 s airborne), full launch speed is held through the air, and the
  0.4 s slide-out decay only starts on touchdown (`_dive_airborne`). The hop is applied after the
  grounded velocity clamp, same as jump. Must be on the floor to start one. The user suggested a
  proper "prone" landing state (lying flat, then getting up) -- not built yet, pending design
  questions (how/when you get up, whether you can crawl, third-person prone pose).
- **No cooldown.** Replaced by a stamina cost: `DIVE_STAMINA_COST` = 0.2 per dive (about five
  back-to-back from full), and stamina no longer regenerates mid-dive -- before this, diving counted
  as "not sprinting" and actually *recovered* stamina, so without a cooldown dives could be chained
  forever at 1.45x sprint speed.
- The `controlstest.gd` scanner failures noted just above no longer reproduce (38/38 pass) -- they
  went away with the default-camera revert, which fits the body-vs-camera aim explanation.
- Verified: `controlstest` 38/38 (dive checks rewritten for hop, touchdown, decay, no cooldown,
  stamina gate, grace window, low ceiling), `settingstest` 97/97 (new `sprint_mode` coverage),
  `inventorytest` 92/92, `devtest`, `databasetest` 12/12, `looptest` (only the known furnace-throw
  flake).

**Prone + crouch toggle (2026-09-16, user design):** the crouch key is now a toggle that steps
stand -> crouch -> prone -> stand (`_stance_want`), and a sprinting press dives and lands prone.
- Prone: capsule `C.PRONE_HEIGHT` 0.8 m (can't go below 2 x `PLAYER_RADIUS`), eye `C.PRONE_EYE_H`
  0.4 m, crawl `C.PRONE_SPEED` 1.0 m/s. `crouching` stays true while prone, so every existing crouch
  gate (no sprint, no jump, silent footsteps, no noise events) covers prone for free. The body uses
  the same lying/crawl pose as a downed player (`_update_down_pose`, `body_hands._human_clip`).
- Replicated: report bit 64 / `report_full` "pr", alongside crouch's bit 16 / "cr".
- Getting up needs headroom: `_apply_crouch` rises as far as fits (prone -> crouch under a ceiling
  between crouch and standing height) and finishes standing up by itself once the ceiling clears.
- Starting a sprint (pressing sprint) also stands you up; going down clears a toggled sprint.
- The old hold-to-crouch is gone for humans. Bots: `bot_crouch`/`bot_prone` set the stance when
  they change; `bot_crouch_press` is one human-style key press; `bot_dive` still fires only a dive.
- Verified: `controlstest` 45/45 (new stance-cycle checks; dive checks now expect landing prone and
  getting up to crouch under a low ceiling), `settingstest` 97/97, `inventorytest` 92/92, `devtest`,
  `databasetest` 12/12, `looptest` clean, `carrycamtest` only its 3 pre-existing wall-pull-in
  failures. Windowed screenshots (`tools/gameshot.tscn -- --only=sprint_dive,prone`, new shot
  `44_prone_crawl`): mid-dive the teammate is already down in the crawl pose; after landing she
  lies flat, arms out.
- Gaps: not checked with two real clients (`nettest`). Melee hit checks against players
  (`combat.gd` ~367) still test a standing-height capsule, so a prone player can be hit as if
  standing. Prone uses the downed crawl pose, so a prone teammate looks the same as a downed one.

**Dive airtime (2026-09-16, playtest):** the hop was there but didn't read -- the view dropped to
prone height the instant the dive fired, cancelling the 0.25 m rise, so it felt like a slide. Now
the body stays standing through the air (`_apply_crouch` wants STAND while `_dive_airborne`), the
hop is `DIVE_HOP_VELOCITY` 4.0 (~0.41 m peak, ~0.47 s airborne measured), the sprint FOV kick holds
through the air, and touchdown goes prone with a camera thud (`fx.land(DIVE_LAND_THUD)` 0.8) and a
fast eye drop (14 m/s while diving vs the usual 6). `controlstest` 48/48; the low-ceiling check now
drops its ceiling after touchdown, since an upright body in the air would otherwise overlap it.

**Dive fall + landing (2026-09-16, playtest):** "quickly pulled to the floor" was the view riding at
standing height all the way down and then dropping ~1.3 m in under 0.1 s at touchdown. Now the eye
stays at full height on the way up and sinks toward prone height in step with the fall
(`_dive_peak_y`/`_dive_launch_y`), so it meets the floor with the body; airborne gravity is softer
(`DIVE_GRAVITY` 12 vs 18) with `DIVE_HOP_VELOCITY` 3.6 (~0.51 m peak, ~0.63 s airborne measured).
Touchdown adds a camera shake (`DIVE_LAND_SHAKE` 0.35, trauma ~0.46 measured) and the existing
"thud" sound on top of the landing dip. `controlstest` 50/50. Its scanner block now clears the
database first: `user://database.save` is shared with any open copy of the game, and a live
playtest running alongside the test left the Walk-In already scanned.
