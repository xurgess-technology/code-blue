# Sweep 4A: Controls, Abilities HUD, Database, the Fog Lot and the Pharmacy

This is the build brief for a **Sonnet orchestrator**. It covers the part of the original Sweep 4
that Zach picked on 2026-09-15. The rest (Growths, grafting, the solo robot, the dev panel) is in
`docs/backlog/SWEEP4B.md`. **Do not build anything from the backlog.**

**Hard rule: no new Blender models.** Build every new prop (the pharmacy window, tube station,
furnace, terminal, pill bottle and so on) from Godot primitives and procedural meshes, the way the
existing props are built (`economy_props.gd`, `hospital_builder.gd`, `room_furnish.gd`), or reuse
CC0 assets that are already in the project. Poses and looks on existing rigs are done in code
(`scripts/hands/body_poser.gd`, materials), not in Blender.

---

## How to run this sweep (orchestrator instructions)

Zach is watching his usage, so this sweep is set up to be cheap. Follow these rules.

### Order
Run the **four chunks one at a time, in order**. Don't run chunks in parallel. Each chunk is one
**Sonnet** worker in a **fresh session** with its own git worktree and branch:

| # | Branch | Chunk |
|---|---|---|
| 1 | `s4a-controls` | Controls, ability slots and HUD, scanner |
| 2 | `s4a-foglot` | The fog lot, the ambulance, spawns and the safe zone move to the lobby |
| 3 | `s4a-pharmacy` | Pharmacy, crematorium, charged throw, placebo pills, gold bar removal |
| 4 | `s4a-database` | Database terminal, guide removal, Hive Eyes and Echo polish |

Then a short **final integration step** (see the end of this file), done by the orchestrator
itself or one more worker.

After each chunk: check its "Done when" list, merge its branch into local `main` (no push), and
append 3–6 lines to `docs/SWEEP4A_LOG.md` (what landed, what's left, any new known issues). Then
start the next chunk from the updated `main`. Zach has asked for autonomous sweeps: **don't stop
to ask him between chunks.** Report once at the end. Only stop early if a chunk can't reach its
"Done when" after a real attempt, and then report what's blocked.

### Token rules for every worker (put these in each worker's prompt)
1. **Don't read `docs/CONTRACTS.md` (128 KB) or `docs/KNOWN_ISSUES.md` (70 KB) end to end.** Grep
   for the headings listed in your chunk and read only those sections.
2. **Don't read `DESIGN.md` or the other sweep docs.** This file is the spec.
3. Read only the files listed for your chunk, and grep before opening anything else. Line
   numbers in this file are hints; code has moved, so grep for the symbol.
4. **Screenshots:** take only the ones listed for your chunk, at most 3, and look at each once.
5. **Tests:** run only your chunk's tests plus **one** `playtest -- --god --seed=1` at the end.
   Don't re-run the whole suite after every edit; run the relevant test when a piece is done.
6. Don't run `nettest_run.gd` in chunks. The final integration step does it once.
7. Keep your final report short: what changed, tests run and their results, anything unfinished.

### Running things
- Godot: `C:\Users\ZachBurgess\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`
  (the first part is a folder).
- From Git Bash, call Windows programs through `cmd.exe //c` (a single slash gets path-mangled).
- Import once per worktree: `godot --headless --path . --import`.
- Headless tests: `godot --headless --path . --fixed-fps 60 tools/<name>.tscn` (always add
  `--fixed-fps 60`). Run **one headless test at a time per checkout**; parallel runs in the same
  directory segfault.
- Bot playthrough: `godot --headless --path . --fixed-fps 60 tools/playtest.tscn -- --god --seed=1`.
- Screenshots: `tools/gameshot.tscn` (windowed).
- GDScript: `:=` fails on untyped autoload returns, so annotate the type.

### Rules that apply to every chunk
- **Multiplayer:** the host owns everything that changes the world: money, scan results, the
  database, the ambulance, thrown items and pill hits. Each client owns its own movement, crouch,
  jump and aim. Anything that changes the world must work when a client does it and must
  replicate. The Hive Eyes fly-through, the warm pill effect and the HUD bar are local only.
- **Performance:** 60 fps with 1% lows above 50 on a Radeon 890M at the medium preset. Register
  every new mesh, material and shader in `scripts/warmup.gd`, and get minigame shaders through
  `Minigame.cached_shader()`. Chunk 2 (fog) and chunk 3 (furnace fire) must check with
  `tools/perfprobe.tscn`.
- **Assets:** CC0 only, looked up through the `Assets` autoload and recorded in `ASSETS.md`.
  Sounds are generated WAVs: add them to a `tools/gen_audio_*.mjs` script and play them through
  the `Audio` autoload.
- **Docs:** each chunk updates only its own section of `docs/CONTRACTS.md` (short, append or edit
  in place) and adds open problems under a new heading in `docs/KNOWN_ISSUES.md`.
- Other Claude sessions sometimes edit this project. Check the mtimes on `player.gd`, `game.gd`
  and `brains.gd` before a big rewrite, and rebase if `main` moved.

---

## Chunk 1: Controls, ability slots and HUD, scanner

**Files:** `project.godot` (input map), `scripts/player.gd`, `scripts/game.gd`, `scripts/main.gd`,
`scripts/hud.gd`, `scripts/brains/brains.gd`, `scripts/settings.gd`,
`scripts/settings_screen.gd`, `scripts/hands/body_poser.gd`, `scripts/perception.gd` (noise),
`scripts/net.gd` (only if a new replicated field is needed).
**CONTRACTS headings to grep:** "Brains (brains worker, sweep 3)", "Settings (settings worker",
"Player: hands, poses and the carry camera", "Networking (net worker".

### 1a. Controls
- **Crouch (Ctrl):** hold to crouch. Crouching lowers the camera and collision height and slows
  movement. **Footsteps make no sound and no noise events**, so the Discharged can't hear a
  crouching player walk. It has a matching third-person pose (done in `body_poser.gd`) and
  replicates. Don't let a player stand up under a low ceiling.
- **Jump (Space):** a small, grounded jump. Nothing floaty. Keep the dev room's Space
  (`dev_room.gd`, grep `ui_accept`/Space) working. The guide's page turn on Space goes away in
  chunk 4, so don't spend effort on it beyond not breaking it.
- **Scan (hold R):** see 1c. R no longer fires abilities. Until chunk 4 removes the guide, the
  guide can keep opening on E at the lectern; move its `read` binding off R (grep `"read"` in
  `main.gd`, `player.gd`, `guide_ui.gd`).
- Crouch, jump, the ability modifier (Alt) and scan must all be rebindable in Settings.

### 1b. Ability slots and HUD
**Where abilities come from (decided for this sweep):** keep the current brain + blender
system and its points and levels exactly as they are. The only change is that abilities go into
slots instead of `best_path()` picking one. When a player's path first reaches level 1, that
ability goes into the first empty slot. Its level keeps coming from the existing points.
Grafting will replace the source later (backlog), so keep the slot contract independent of how
levels are earned: something like `add_ability(peer, id)`, `set_level(peer, id, lvl)`,
`slot_of(peer, id)`.

- Each player has **4 ability slots** and can **never have more than 4 abilities**. Anything that
  would add a 5th is refused. Only two abilities exist today; the cap is for later.
- A new ability goes into the first empty slot. Moving and swapping slots is out of scope.
- Each slot has its **own cooldown**. Replace `best_path()` (`brains.gd`, and its caller in
  `ability()`) with per-slot dispatch.
- **Ability bar (Alt):**
  - While Alt is held, the item icons in the inventory bar **slide up and shrink** into a small
    row at the top-left of the bar, and the **4 ability slots fill the bar**. Releasing Alt
    reverses it. The animation is short, about 0.12 s.
  - When Alt isn't held, the 4 ability icons sit small at the top-left of the bar, so they're
    always visible.
  - **Alt+1..4** fires that slot. Pressing it again while the ability is active ends it, as R
    does today.
  - Holding Alt doesn't block movement. 1–4 without Alt still select item slots.
- **Each slot icon shows:** the key (Alt+N), the ability name on hover while the bar is open, a
  cooldown sweep, and level pips.
- **When it can't be used,** the icon greys out and pressing it shows a short reason, like
  "No Hive in range", "Hands busy" or "Cooling down (12 s)".
- **Costs** appear on the icon, for example a small "LOUD" tag on Echo.
- **First ability card:** the first time an ability lands in a slot, show a short card with its
  name, what it does, its key and its cost. It closes itself after a few seconds or on any key.
- Abilities and levels are still per player and still reset on a wipe with money.

### 1c. Scanner
- **Every player has a scanner built in.** It isn't an item and doesn't take a slot.
- **Hold R** while aiming at a monster to scan it. Scanning needs range and line of sight,
  breaking either resets progress, and it takes a few seconds. Show a small progress ring at the
  crosshair.
- It beeps while scanning. **The beep is not a noise event,** so monsters can't hear it.
- The host checks and records the scan. Completing one shows "Entry updated" to the scanner.
- Chunk 4 builds the database. For now the host keeps a simple per-species record of
  **sighted** and **scanned** in a small class (for example `scripts/database/db_record.gd`) that
  chunk 4 will extend and save. "Sighted" means a monster was within range and visible to any
  player. Keep it in memory only for now.

### Tests
- Update `tools/braintest` for slots; add cases to it or a new `tools/controlstest`:
  - Crouch silences footstep noise, and jump works.
  - Alt+1..4 fires the right slot, each slot keeps its own cooldown, and a 5th ability is
    refused.
  - Scanning needs line of sight, breaking it resets progress, and a completed scan sets
    `scanned` on the host.
- Run `settingstest`, `devtest`, then `playtest -- --god --seed=1`.

### Screenshots (max 3)
The ability bar closed, the bar with Alt held showing a greyed slot, and crouch in third person.

### Done when
All the tests above pass, the old `best_path()` single-ability path is gone, and the CONTRACTS
"Brains" section documents the slot API and the scan record.

---

## Chunk 2: The fog lot, the ambulance, and the safe zone moves inside

**Files:** `scripts/level/neutral.gd`, `scripts/level/entrance.gd`, `scripts/mapgen.gd`,
`scripts/hospital_builder.gd`, `scripts/loop/shift_loop.gd`, `scripts/level/level_state.gd`,
`scripts/camera_fx.gd` or the environment/fog setup (grep `volumetric_fog`),
`scripts/audio_manager.gd`, `tools/mapcheck.gd`, `tools/spawncheck.gd`.
**CONTRACTS headings to grep:** "Hospital (hospital worker", "Shift loop and patients",
"Doors and the per-shift wings" (only "The map").

Leave the shop, sell bin and gold pile working where they are for now; chunk 3 moves or removes
them. Just don't break them when the lot is stripped. If they physically have to go, move them
to the lobby as plain placeholders and note it in the log.

### 2a. Strip the lot
Remove from `neutral.gd`: the parked cars and the fence, the barriers, cones and benches, the
shop van and crates, the parked ambulance. (The dumpster and the gold pallet go in chunk 3.)
Keep the asphalt, faded stall lines, the ambulance bay marking, the entrance canopy and a few
street lights. Outside should be **nothing but an empty lot and fog**.

### 2b. The fog ring
- Thick fog surrounds the lot. Walking into it, visibility drops to nothing within a few metres
  and sound gets muffled.
- **Turning players around:** past a certain depth, the player's heading slowly bends back. At
  the deepest point, while they're fully blinded, they're quietly turned to face the lot, so they
  walk straight back out without ever touching a wall.
- The host controls this, and it also works for a carried player. Dropped or thrown items that
  land in the fog come back out at the edge. Monsters never go into the fog.
- Keep it cheap. The existing volumetric fog is tuned (`fog 96x48` on medium). Prefer a local fog
  volume, a screen-space fade by depth into the ring, or both, over raising global fog.

### 2c. The ambulance
- When a patient delivery starts, the ambulance appears deep in the fog. Headlights and flashing
  lights glow through it and the siren gets louder, then it **drives out along a lane** to the
  bay.
- It parks, the paramedics unload the patient along the existing gurney walk, and then it
  **drives back into the fog** and disappears once it's out of sight.
- If a player stands in its lane, it stops and honks. It never hurts anyone.
- If another patient is due while it's still there, it waits or makes another trip.
- The host drives it, and clients see a replicated transform. `level_info.ambulance` becomes the
  bay position, and the vehicle is no longer a static prop. Reuse the existing ambulance model.

### 2d. Spawns and the safe zone move inside
- Player spawns and respawns move **inside the main doors, into the lobby**.
- The safe neutral zone (no monster spawns, never dark) now covers the **lobby and the break
  room**, plus room for the pharmacy and the crematorium that chunk 3 adds off the lobby.
  Reserve that space now and record it in `level_info` so chunk 3 has fixed spots. Chases can
  still lead monsters in, as they can today.
- Update `mapgen.gd`'s checks: spawns must be inside the new indoor neutral zone. Leave the shop,
  sell and gold checks for chunk 3 to replace.

### Tests
- `mapcheck`, `spawncheck`, `looptest`.
- New cases (in `looptest` or a new `tools/fogtest`): a player walking into the fog comes back
  out, a dropped item in the fog comes back, and the ambulance arrives, unloads, leaves, and
  stops for a player in its lane.
- `perfprobe` once in the lot, facing the fog. It must hold the target.
- `playtest -- --god --seed=1`.

### Screenshots (max 3)
The fog lot from the doors, the view from inside the fog, and the ambulance emerging.

### Done when
The tests pass, perfprobe holds the target, nothing outside spawns monsters, and the lobby is
the spawn point.

---

## Chunk 3: Pharmacy, crematorium, charged throw, placebo pills, no gold

**Files:** `scripts/economy/economy.gd`, `scripts/economy/economy_props.gd`,
`scripts/economy/gold_pile.gd` (delete), `scripts/economy/loot_models.gd`,
`scripts/items.gd`, `scripts/item_models.gd`, `scripts/world_item.gd` (`toss()`),
`scripts/game.gd` (the drop path), `scripts/player.gd` (the drop key), `scripts/hud.gd`,
`scripts/dev/dev_panel.gd` and `scripts/dev/dev_dispenser.gd` (gold removal only),
`scripts/or_screen/*` (the green blip), `scripts/mapgen.gd`, `scripts/level/neutral.gd`,
`tools/inventorytest.gd`, `tools/devtest.gd`.
**CONTRACTS headings to grep:** "Inventory and money", "World items", "Models (loot and paramedic
models", "OR screen and minimal HUD".

### 3a. Charged throw (build first, the rest needs it)
- Today a drop only does a gentle `toss()` (`world_item.gd`, called from `game.gd`). Add a real
  throw: **hold the drop key to charge, release to throw**. A quick tap still drops.
- The host runs the physics and replicates the item.

### 3b. Gold bars are removed
Remove gold bars from the economy, the shop, the HUD, the dev panel and dispenser, the tests,
`mapgen.gd`'s gold pile check, and `DESIGN.md`. **No gold bar code paths remain** (grep `gold`
and `bar_price` when done).

### 3c. The pharmacy (shop)
- An **outpatient pharmacy window** in the lobby spot chunk 2 reserved: a counter behind a steel
  grate, an order terminal (or E on the grate) and a price board.
- **You never clearly see the pharmacist.** Maybe a shape moves in the back. No mechanic.
- **Buying** takes the crew's money. A moment later a **pneumatic tube capsule thunks** into a
  wall delivery station next to the window and drops the item.
- It sells one item for now: placebo pills (3e). Remove the shop van flow.

### 3d. The crematorium (sell point)
- A small, grim room off the lobby with a **cremation furnace**. Its steel door stays open and the
  fire glows inside. Add a cremation cart and a shelf of empty urns for set dressing. All
  primitives.
- **Selling means throwing.** Items that land in the fire burn and sell. There's no
  walk-up-and-click. Missed throws bounce off the frame onto the floor.
- **Feedback:** a burst of flame and a roar, then the amount floats up from the fire and the
  money is added.
- **Safety:** players (downed, dead or carried) can never go in; their bodies bounce off like a
  missed throw. Items that can't be sold bounce back out.
- Remove the dumpster sell bin. Update `mapgen.gd`: the shop and sell point must be inside the
  indoor neutral zone.
- Keep the fire cheap (a few emissive cards plus a flickering light, see `light_flicker.gd`);
  check with `perfprobe`.

### 3e. Placebo pills
- **Item:** a pill bottle holding 10 pills. It has a flat price, never gets more expensive, and
  you can buy as many as you like. It does **nothing mechanically** and can't be found in the
  wings. Burns for $0.
- **Take one:** use the held bottle to swallow a pill.
- **Throw one:** throw a single pill (uses 3a). Whoever it hits takes it:
  - **A player** (yourself or a teammate): a line appears on **that player's** screen and they
    get the warm effect.
  - **A patient or a monster:** the line floats above them in quotes, and everyone nearby sees
    it. For a patient on the OR table, the monitor also shows a hopeful green blip reading
    "Patient appears comforted." **Vitals and sedation don't change.**
  - **A miss:** the pill stays on the floor as a small pickup. Anyone can pick it up and eat it.
- **Warm effect** (local, on the screen of the player who took it):
  - **Look:** a soft warm tint, slightly richer colours and slightly softer screen edges. Cozy,
    not a filter.
  - **Timing:** fades in over about 2 s, holds about 15 s, fades out over about 3 s.
  - **Stacking:** another pill resets the timer and strengthens the effect slightly, up to a low
    cap that never hurts visibility.
- **Lines:** small, casual, lowercase text. Pick randomly, and don't show the same line to the
  same player twice in a row.
  1. oh yeah, that's working
  2. you feel fine. you already felt fine
  3. tastes like a tums
  4. your back pops
  5. you're gonna be okay
  6. huh. neat
  7. that hit different
  8. you feel like calling your mom
  9. your headache is gone. you didn't have a headache
  10. swallowed it dry. bold
  11. chalky
  12. you feel slightly taller
  13. this is definitely doing something
  14. your left arm feels normal. good
  15. you feel ready to clock in
  16. that'll be $40
  17. you stop worrying about the noise down the hall. you should not stop worrying
  18. you can breathe through both nostrils
  19. you feel like you could lift the seal
  20. your hands stop shaking. they weren't shaking
  21. you think about getting a dog
  22. that went down wrong
  23. ten out of ten, would swallow again
  24. you're cured
  25. the ringing in your ears changes key
  26. you suddenly remember where you left your keys
  27. you feel like you slept eight hours. you did not
  28. your blood pressure is probably fine
  29. kinda sweet actually
  30. pretty sure that was a tic tac
  31. you feel brave. don't
  32. you're doing great, champ
  33. a warm feeling. hopefully from the pill
  34. your joints feel oiled
  35. you feel like a real doctor now
  36. you could go another shift
  37. you take a deep breath. it smells like bleach
  38. best pill you've ever had
  39. you feel like everyone likes you
  40. your eye stops twitching
  41. you're not scared of the dark anymore. for like a minute
  42. it's working. it has to be working
  43. you should probably read the label
  44. you don't need to see a doctor. you are one. kind of
  45. your stomach makes a noise
  46. you get the urge to organize the supply closet
  47. you feel like humming
  48. something in your chest unclenches
  49. you can hear colors. no you can't
  50. one more couldn't hurt
- Chunk 4 adds the database entry: *Placebo (sugar pill). Efficacy: disputed. Side effects:
  optimism.* Leave a note in the log.

### Tests
- `inventorytest`, `devtest`, `mapcheck`, `looptest`.
- New cases (in `inventorytest` or a new `tools/pharmacytest`): a charged throw goes further than
  a tap; buying delivers through the tube and takes money; items thrown into the furnace sell;
  players and unsellable items bounce out; pills burn for $0; a thrown pill on a teammate shows
  the line on their machine; a pill on a patient doesn't change vitals; no gold bar code paths
  remain.
- `perfprobe` once in the crematorium.
- `playtest -- --god --seed=1`.

### Screenshots (max 3)
The pharmacy with a tube delivery, the crematorium burning a thrown item, and the warm effect
with a floating line over a patient.

### Done when
The tests pass, `grep -ri gold scripts tools` finds nothing economy-related, and perfprobe holds
the target in the crematorium.

---

## Chunk 4: Database terminal, guide removal, Hive Eyes and Echo polish

**Files:** `scripts/guide/*` (the content moves; the binder, lectern and `read` flow go),
`scripts/main.gd`, `scripts/player.gd` (the `read` paths, the binder grip in
`scripts/hands/grips.gd`), `scripts/hospital_builder.gd` or `room_furnish.gd` (break room),
the chunk 1 scan record, `scripts/brains/hive_view.gd`, `scripts/brains/echo_view.gd`,
`scripts/brains/brains.gd`, `scripts/dissection/dissection.gd` (the harvest hook),
`scripts/settings.gd` or a new save file, `tools/guide_lab.gd`, `tools/devtest.gd`.
**CONTRACTS headings to grep:** "Medical guide (guide worker", "Brains (brains worker, sweep 3)",
"Dissection (dissection worker", "Networking (net worker".

### 4a. The terminal
- **A computer terminal in the break room replaces the whole guide binder**, including the
  surgery and item pages. **No carryable version.** Remove the lectern binder, the binder's
  two-handed grip and the `read` flow, and move the guide page content into the terminal.
- It opens with E. It's full-screen UI on the local machine, and the player can't move while
  using it.
- **Sections:** Monsters, Abilities, Items & Procedures.
- **Monster entries unlock in tiers:**
  1. **Sighted** (seen within range): name and silhouette.
  2. **Scanned:** behaviour, senses, threat level, how many sedative doses it takes, and an
     **X-ray showing where its brain sits**.
  3. **Harvested** (for now: a brain of that species was successfully harvested, or one was
     absorbed): the brain's look, spoil time, the ability it grants, and a table of what each
     level does (range, duration, cooldown, costs). This tier is renamed when grafting arrives.
- Items and procedures are unlocked from the start, as the guide is today. Add the placebo entry:
  *Placebo (sugar pill). Efficacy: disputed. Side effects: optimism.*
- The Night Nurse's entry lists her growth site as "unknown." She has no brain, so tier 3 stays
  locked for her.
- **Saving:** the database **belongs to the host**. It's saved on the host's machine (a file
  under `user://`), survives wipes, and is shared with connected guests during the session.
  Anything a guest sights, scans or harvests is recorded in the host's database. Guests don't
  keep a copy.
- Remove `tools/guide_lab` or turn it into a terminal lab; fix anything in `devtest` that used
  the guide.

### 4b. Hive Eyes
- **Fly-through camera on activation:** the local camera leaves the player's head and flies
  **along the navmesh path** to the Hive, then settles into its eyes.
  - The flight takes about 1–1.5 s no matter the distance, speeding up on long paths. If there's
    no path, it glides in a straight line.
  - It's local only. The host's duration timer starts **after** the flight lands.
- **Normal exit:** a quick fly back to the body. **Taking a hit:** an instant snap back with no
  fly-back.
- **Range pulse:** a subtle pulse or tick on the Hive Eyes slot while a Hive is within range.
- **Cycling:** at level 2 and up, pressing the slot during Hive Eyes switches to another Hive
  in range, with a short fly-through between them. At level 1 you only get the nearest one.
  **Keys:** at level 1, tapping the slot again ends Hive Eyes. At level 2 and up, tapping cycles
  and **holding the slot key for about 0.4 s** ends it. Show this on the ability card.
- **Teammates can see it:** the player's body shows glazed eyes while in Hive Eyes (a material
  swap on the existing head).

### 4c. Echo
The shriek visibly comes from the player who used it, with a short pulse ring and body pose on
every machine.

### Tests
- `braintest`, `dissectiontest`, `devtest`, `looptest`.
- New cases (in `braintest` or a new `tools/databasetest`): a completed scan unlocks tier 2 in the
  host database; a harvest unlocks tier 3; the database persists across a wipe and a reload; a
  guest's scan lands in the host's database; the Hive Eyes timer starts after the fly-in; a hit
  snaps back instantly; no `read` action or guide binder code remains.
- `playtest -- --god --seed=1`.

### Screenshots (max 3)
A terminal monster entry at tier 2 with the X-ray, the scan progress ring, and Hive Eyes
mid-flight.

### Done when
The tests pass, the binder and lectern are gone from the break room, and the database file
survives a wipe.

---

## Final integration step
Run once after chunk 4 is merged:
1. Fresh import, then `playtest -- --god` on seeds 1, 2 and 3.
2. `nettest_run.gd --lag=120 --jitter=40 --loss=0.03` with the existing scenarios `brains`,
   `dissection` and `combat`, plus new scenarios for scanning, the ambulance, throwing and pills.
   Fix only what breaks.
3. One `perfprobe` pass (lobby, fog lot, crematorium). Record the numbers in the log.
4. Update `DESIGN.md` for this sweep only: the ability bar, the database terminal, the fog lot,
   the pharmacy and crematorium, placebo pills, and no gold bars. Brains stay brains.
5. Commit on local `main`. **Don't push.**
6. Report to Zach once: what landed per chunk, the test and perf results, and the new known
   issues. Keep it short.
