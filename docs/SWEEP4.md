# Sweep 4: Growths, Grafting, the Fog Lot and the Pharmacy

## Goal
Brain abilities work, but players can't use more than one, can't tell what an ability does, and
gain them through a blender that doesn't fit the game's surgical identity. The outside area also
works against the horror, because it's a busy, fenced parking lot full of props and machines.
This sweep covers:

1. **Controls:** crouch, jump, and a 4-slot ability bar on Alt.
2. **Growths replace brains.** Each monster carries a living parasitic mass instead of a brain.
3. **Grafting is the only way to gain abilities.** It's a surgery, and solo players do it
   through a surgical robot.
4. **A break-room database terminal** replaces the guide binder. Every player has a built-in
   scanner that fills it.
5. **Hive Eyes and Echo readability.**
6. **The fog lot.** Outside is an empty lot ringed by fog, and the ambulance drives in and out
   of it.
7. **Everything mechanical moves inside:** a pharmacy window shop, a crematorium sell room, and
   gold bars replaced by placebo pills.

Read `DESIGN.md`, `docs/CONTRACTS.md`, `docs/KNOWN_ISSUES.md` and `docs/SWEEP3.md` first. Sweep 3
built the systems this sweep changes.

## Where things are today
- `scripts/brains/brains.gd` `ability()` fires on **R** and only runs `best_path()`, the path with
  the most points, so a second absorbed ability can never be used. Points come from brain quality
  (`points_for(factor)`), and levels come from point thresholds.
- Brains are item kinds `brain_walk_in` / `brain_discharged` (`dissection.gd` `BRAIN_KINDS`), with
  meshes from `brain_model.gd`, spoiling in `brains.gd`, and the break-room blender in `blender.gd`.
  The harvest minigame is `scripts/dissection/brain_forceps.gd`.
- Hive Eyes (`_start_hive`) snaps the view straight to the nearest Walk-In's camera
  (`hive_view.gd`). It already ends when the player takes damage, gets stunned or gets carried.
- The guide is a carryable binder on a lectern (`scripts/guide/*`), opened with the `read` action
  (R).
- `scripts/level/neutral.gd` builds a fenced 44x18-tile outdoor area containing the canopy,
  parked cars, a parked ambulance with its bay, the shop van, the dumpster sell bin, the gold bar
  plaza, player spawns and street lights. `mapgen.gd` checks that the shop, sell bin, gold pile
  and ambulance sit inside it. The neutral zone is never dark and never spawns monsters.
- Paramedics walk patients from `level_info.ambulance` (`shift_loop.gd`).
- The shop sells gold bars (`economy.gd` `bar_price`, `economy_props.gd`) that stack on the
  plaza pallet.
- Input actions in `project.godot` include `sprint` (Shift), `shove` (Q), `use` (LMB), `interact`
  (E), `read` (R), `drop`, `slot_next` / `slot_prev`. There is no crouch or jump. Space is used
  in the dev room (`dev_room.gd:801`) and to turn pages in the guide (`guide_ui.gd:454`).
- Players can only join between shifts. Anyone who joins mid-shift spectates until the next one.

---

## 1. Controls
- **Crouch (Ctrl):** hold to crouch. Crouching lowers the camera and collision height and slows
  movement. **Footsteps make no sound and no noise events**, so the Discharged can't hear a
  crouching player walk. It has a matching third-person pose and replicates.
- **Jump (Space):** a small, grounded jump. Nothing floaty. Keep the dev room's Space and the
  guide's page turn working. The guide is being removed (section 4), so only the dev room matters
  in the end.
- **Ability bar (Alt):**
  - While Alt is held, the item icons in the inventory bar **slide up and shrink** into a small
    row at the top-left of the bar, and the **4 ability slots fill the bar**. Releasing Alt
    reverses it. The animation is short, about 0.12 s.
  - When Alt isn't held, the 4 ability icons sit small at the top-left of the bar, so they're
    always visible.
  - **Alt+1..4** fires that slot. Pressing it again while the ability is active ends it, as R
    does today.
  - Holding Alt doesn't block movement. 1–4 without Alt still select item slots.
- **Scan (hold R):** see section 4. R no longer opens the guide or fires abilities.
- Crouch, jump, the ability modifier and scan must all be rebindable in Settings.

## 2. Ability slots and HUD
- Each player has **4 ability slots**, and a player can **never have more than 4 abilities**.
  Grafting a 5th species is refused (section 3).
- A new ability goes into the first empty slot. Moving and swapping slots is out of scope.
- Each slot has its **own cooldown**. Replace `best_path()` with per-slot dispatch.
- **Each slot icon shows:** the key (Alt+N), the ability name on hover while the bar is open, a
  cooldown sweep, and level pips.
- **When it can't be used,** the icon greys out with a short reason on press, like
  "No Walk-In in range", "Hands busy" or "Cooling down (12 s)".
- **Costs** appear on the icon, for example a small "LOUD" tag on Echo.
- **First graft card:** after a successful first graft, show a short card with the ability name,
  what it does, its key and its cost. It closes itself or on any key.
- Abilities and levels are still per player and reset on a wipe with money.

## 3. Growths and grafting

### 3a. Growths replace brains
Staff call it **the Growth**, and the database files it as *Anomalous Tissue*. A Growth is a
living parasitic mass. It's what turned the patients into monsters, and its powers become
theirs. Rename every brain item kind, string, model, dissection target and dev tool. The blender
is **removed**.

**Shared look.** Every Growth has:
- wet, pale, slightly see-through flesh with veins under the surface
- a dull **inner glow that pulses** like a slow heartbeat, in a colour set per species
- pale root-threads trailing where it was attached
- about fist size, fitting in one hand slot
- small twitches while fresh
- signs of death as it spoils: the pulse slows, the glow dims, and the flesh turns grey and dry

**A Growth is either alive or dead. It has no quality value.** It dies if:
- the extraction is botched badly enough,
- the implant surgery is botched badly enough,
- a graft is aborted,
- or it spoils.

A dead Growth is useless and can't be grafted. Smaller botches cost vitals, as surgery does
today.

**Hive Knot (Walk-In)**
- **Look:** a grape-cluster knot of 6–10 marble-sized eyeball nodules fused at the base, with
  cloudy lenses and dark pupils that **drift and look around** even after harvest. A tail of pale
  threads hangs off the back. Yellow-white glow.
- **Host site:** behind the eyes, rooted in the optic nerves, with threads down the spine.
- **Lore:** every Hive Knot grew from one mother mass, so they're all still connected. That's
  why Hive Eyes works.
- **Tell on the living monster:** cloudy eyes with extra drifting pupils, and a faint glow at the
  temples.
- **Extraction:** open the skull and **cut the optic threads one at a time**. Each cut twitches
  the body and shakes the minigame. Tearing too many threads or crushing the knot kills it.
- **Death:** the nodules close one by one, like eyelids.

**Bellows (Discharged)**
- **Look:** a ribbed, hollow, pear-shaped sac with thin cartilage rings. Two thin, veined,
  almost transparent membranes trail off the top. It **slowly inflates and deflates** with a
  faint wet clicking. Deep violet glow.
- **Host site:** the throat under the jaw, with the membranes wrapped around both inner ears.
- **Lore:** the Growth ate its eyes and enlarged its hearing, which is why it's blind and
  hunts by sound.
- **Tell on the living monster:** the throat swells and pulses when it stops to listen, with a
  violet glow under the jaw.
- **Extraction:** go in **through the neck, not the skull**. The membranes are fragile, and
  shredding them kills the Growth. Cutting the last attachment makes it **shriek**, a real
  `emit_noise` event that can pull monsters to the OR.
- **Death:** it sags, deflates for good and stops clicking.

**Art:** procedural meshes in the style of `brain_model.gd`. The Hive Knot is a sphere cluster
with a lens shader and animated pupils; the Bellows is a lathed ribbed shape with two thin
membrane planes and an inflate animation. Register them in `warmup.gd`, and get shaders through
`Minigame.cached_shader()`. The dissection rig needs a per-species host site and opening:
`monster_builder.gd` for the skull vs. neck, and `monster_rig_look.gd` for the glow showing
through the skin.

### 3b. Grafting
**Grafting is the only way to gain or level an ability.**
- **One graft = one level.** The first graft of a species installs it at level 1 in a free slot.
  Each later graft of the same species adds one level. There are no points or thresholds.
- **Grafting a 5th species** is refused before surgery starts, with "No viable site."
- **The graft is an OR procedure on a player strapped to a patient table:**
  - **First graft:**
    1. Local anesthetic. The patient stays awake.
    2. Open the site: scalpel at the temples (Hive Knot) or neck (Bellows).
    3. Seat the Growth.
    4. **Connect:** attach the threads to the optic nerves (Hive Knot, the reverse of
       extraction), or seal the membranes around the throat and inner ears without tearing
       them (Bellows).
    5. Close: stitches, then gauze.
  - **Later grafts:** open the site, then **fuse** the new tissue onto the existing Growth, then
    close. For the Hive Knot, nest the new nodules without crushing the old ones. For the
    Bellows, seal the new chamber without tearing either membrane.
- Reuse the existing surgery minigame framework and OR monitor. Botches cost the grafted player's
  vitals, and a bad enough botch kills the Growth. The surgery itself never kills the player
  outright beyond the normal vitals rules.
- **The patient's view:** the strapped player sees the procedure from the table and can't act,
  apart from aborting (below).
- **Visible tell on the grafted player** (third person, and the first-person hands where they
  show):
  - **Hive Knot:** a few faint glowing bumps at the temples at level 1, with more bumps spreading
    toward the ears each level.
  - **Bellows:** a violet glow and slight swelling under the jaw at level 1, with ribbing along
    the throat as levels rise. The throat swells when Echo fires.
- **Abort:** the strapped player can hold a key to unstrap after a short delay. Aborting
  mid-graft kills the Growth.

### 3c. Solo surgical robot
- A da Vinci–style **surgical robot** stands at an OR table, with a console.
- **It only works when exactly one active, non-spectator player is on the shift.** In co-op it
  is present but switched off.
- **Flow:** the solo player puts the Growth on the tray, straps themselves to the table and
  takes control. The camera moves to the robot's view and the player runs the **normal graft
  minigames with their own inputs**. The robot never acts on its own.
- **It works exactly like hands:** same speed, same precision, same tolerances.
- Abort works the same as in 3b. Taking damage while strapped doesn't end robot control on its
  own; the player decides whether to abort.

## 4. Break-room database and scanner

### 4a. The terminal
- **A computer terminal in the break room replaces the whole guide binder**, including the
  surgery and item pages. **No carryable version.** Remove the lectern binder and the `read`
  flow, and move the guide page content into the terminal.
- It opens with E. It's full-screen UI on the local machine, and the player can't move while
  using it.
- **Sections:** Monsters, Growths & Abilities, Items & Procedures.
- **Monster entries unlock in tiers:**
  1. **Sighted** (seen within range): name and silhouette.
  2. **Scanned:** behaviour, senses, threat level, how many sedative doses it takes, and an
     **X-ray showing where its Growth sits**.
  3. **Harvested or grafted:** the Growth's look, spoil time, the ability it grants, and a table
     of what each level does (range, duration, cooldown, costs).
- Items and procedures are unlocked from the start, as the guide is today.
- **Saving:** the database **belongs to the host**. It's saved on the host's machine, survives
  wipes, and is shared with connected guests during the session. Anything a guest sights, scans,
  harvests or grafts is recorded in the host's database. Guests don't keep a copy.
- The Night Nurse's entry lists her Growth site as "unknown." She has no Growth.

### 4b. Scanner
- **Every player has a scanner built in.** It isn't an item and doesn't take a slot.
- **Hold R** while aiming at a monster (or another scannable thing) to scan it. Scanning needs
  range and line of sight, breaking either resets progress, and takes a few seconds. Show a
  small progress ring at the crosshair.
- It beeps while scanning. **The beep is not a noise event,** so monsters can't hear it.
- The host checks and records the scan. Completing one shows "Entry updated" to the scanner.

## 5. Hive Eyes and Echo
- **Fly-through camera on activation:** the local camera leaves the player's head and flies
  **along the navmesh path** to the Walk-In, then settles into its eyes.
  - The flight takes about 1–1.5 s no matter the distance, speeding up on long paths. If there's
    no path, it glides in a straight line.
  - It's local only. The host's duration timer starts **after** the flight lands.
- **Normal exit:** a quick fly back to the body. **Taking a hit:** an instant snap back with no
  fly-back.
- **Range pulse:** a subtle HUD pulse or tick on the Hive Eyes slot while a Walk-In is within
  range.
- **Cycling:** at a higher level (level 2), pressing the slot during Hive Eyes switches to another
  Walk-In in range, with a short fly-through between them. At level 1 you only get the nearest
  one.
- **Teammates can see it:** the player's body shows glazed eyes while in Hive Eyes.
- **Echo:** the shriek visibly comes from the player who used it, with a short pulse ring and
  body pose on every machine.

## 6. The fog lot
**Strip `neutral.gd` down.** Remove:
- the parked cars and the fence
- the barriers, cones and benches
- the shop van and crates
- the dumpster and the gold pallet
- the parked ambulance

Keep the asphalt, faded stall lines, the ambulance bay marking, the entrance canopy and a few
street lights. Outside should be **nothing but an empty lot and fog**.

**The fog ring:**
- Thick fog surrounds the lot. Walking into it, visibility drops to nothing within a few metres
  and sound gets muffled.
- **Turning players around:** past a certain depth, the player's heading slowly bends back. At
  the deepest point, while they're fully blinded, they're quietly turned to face the lot, so they
  walk straight back out without ever touching a wall.
- The host controls this, and it also works for a carried player. Dropped or thrown items that
  land in the fog come back out at the edge. Monsters never go into the fog.
- Keep it cheap. Hold the performance target, since the existing volumetric fog settings are
  tuned (`fog 96x48` on medium).

**The ambulance:**
- When a patient delivery starts, the ambulance appears deep in the fog. Headlights and
  flashing lights glow through it and the siren gets louder, then it **drives out along a lane**
  to the bay.
- It parks, the paramedics unload the patient along the existing gurney walk, and then it
  **drives back into the fog** and disappears once it's out of sight.
- If a player stands in its lane, it stops and honks. It never hurts anyone.
- If another patient is due while it's still there, it waits or makes another trip.
- The host drives it, and clients see a replicated transform. `level_info.ambulance` becomes the
  bay position, and the vehicle is no longer a static prop.

## 7. Moving everything inside

### 7a. The neutral zone moves indoors
- Player spawns and respawns move **inside the main doors, into the lobby**.
- The safe neutral zone (no monster spawns, never dark) now covers the **lobby, the pharmacy, the
  crematorium and the break room**. Chases can still lead monsters in, as they can today.
- Update `mapgen.gd`'s checks: the shop, sell point and spawns must be inside the new indoor
  neutral zone, and the gold pile check goes away.

### 7b. The pharmacy (shop)
- An **outpatient pharmacy window** in or next to the lobby: a counter behind a steel grate, an
  order terminal (or E on the grate) and a price board.
- **You never clearly see the pharmacist.** Maybe a shape moves in the back. No mechanic.
- **Buying** takes the crew's money. A moment later a **pneumatic tube capsule thunks** into a
  wall delivery station next to the window and drops the item.
- **Gold bars are removed** from the economy, the shop, the HUD, the dev panel, the tests and
  `DESIGN.md`. The pharmacy sells one item for now: placebo pills (7d).

### 7c. The crematorium (sell point)
- A small, grim room off the lobby with a **cremation furnace**. Its steel door stays open and
  the fire glows inside. Add a cremation cart and a shelf of empty urns for set dressing.
- **Selling means throwing.** Items that land in the fire burn and sell. There's no
  walk-up-and-click. Missed throws bounce off the frame onto the floor.
- **Feedback:** a burst of flame and a roar, then the amount floats up from the fire and the
  money is added.
- **Safety:**
  - Players (downed, dead or carried) can never go in. Their bodies bounce off like a missed
    throw.
  - Items that can't be sold bounce back out.
- Placebo pills burn for $0.
- **Throwing:** today a drop only does a gentle `it.toss()` (`game.gd:1122`), so add a real
  throw on top of it: hold the drop key to charge, release to throw. The host runs the physics and replicates the item. The crematorium and
  placebo pills both need it.

### 7d. Placebo pills
- **Item:** a pill bottle holding 10 pills. It has a flat price, never gets more expensive, and
  you can buy as many as you like. It does **nothing mechanically** and can't be found in the
  wings.
- **Take one:** use the held bottle to swallow a pill.
- **Throw one:** throw a single pill. Whoever it hits takes it:
  - **A player** (yourself or a teammate): a line appears on **that player's** screen and they get
    the warm effect.
  - **A patient or a monster:** the line floats above them in quotes, and everyone nearby sees
    it. For a patient on the OR table, the monitor also shows a hopeful green blip reading
    "Patient appears comforted." **Vitals and sedation don't change.**
  - **A miss:** the pill stays on the floor as a small pickup. Anyone can pick it up and eat it.
- **Warm effect** (on the screen of the player who took it):
  - **Look:** a soft warm tint, slightly richer colours and slightly softer screen edges. It
    should feel cozy, not like a filter.
  - **Timing:** fades in over about 2 s, holds about 15 s, and fades out over about 3 s.
  - **Stacking:** another pill resets the timer and strengthens the effect slightly, up to a low
    cap that never hurts visibility.
- **Lines:** small, casual, lowercase text. Pick randomly, and don't show the same line to the
  same player twice in a row.
- **Pill lines:**
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
- Add the database entry: *Placebo (sugar pill). Efficacy: disputed. Side effects: optimism.*

## 8. Dev panel
- Database: unlock all entries, reset.
- Instant graft: pick a species and a level, and it goes into the next slot. Clear slots.
- Spawn a Growth (either species, alive or dead).
- Robot test mode: enable the robot even with more than one player.
- Send the ambulance now.
- Fog toggles: density, and the turnaround effect on or off.
- Give money and placebo bottles.
- Remove the old brain, blender and gold bar dev actions.

## Out of scope
- Growth size tiers (small / mature / overgrown), selling Growths at the crematorium.
- Puppet, Rise and side effects.
- Moving abilities between slots.
- A gift shop or cosmetics.

## Constraints
- **Performance:** 60 fps with 1% lows above 50 on the Radeon 890M (medium preset). Check with
  `tools/perfprobe`, especially the fog ring, the Growth shaders and the crematorium fire.
- **Multiplayer:** the host owns Growths, grafts, the robot, the database, the scanner results,
  the ambulance, money, thrown items and pill hits. Every client owns its own movement, crouch,
  jump and aim. Anything that changes the world must work for a client and replicate. The
  fly-through, warm effect and HUD bar are local only. Everything must hold up under
  `nettest_run.gd --lag=120 --jitter=40 --loss=0.03`.
- Register every new mesh, material and shader in `scripts/warmup.gd`.
- CC0 assets only, looked up through `Assets` and recorded in `ASSETS.md`.
- Update `DESIGN.md` (brains → Growths, grafting, the fog lot, the pharmacy and crematorium, no
  gold bars) and `docs/CONTRACTS.md`. Add open problems to `docs/KNOWN_ISSUES.md`.
- **Work already in flight:** the `hands` branch (`docs/HANDS_AND_FEEDBACK.md`) rewrites held
  items, wind-ups and the carry camera in `player.gd` and `combat.gd`, and gives the guide
  binder a two-handed carry. `pockets` and `doors` touch `wing_gen`. Sweep 4 should start after
  `hands` merges, or rebase onto it. Drop the binder grip once the binder is removed. Other
  sessions edit this project too, so check file mtimes on `player.gd`, `game.gd` and
  `brains.gd` before big rewrites.
- **Worker split:** run at most 2–3 non-overlapping workers at once, and sequence the ones that
  edit `player.gd` / `game.gd`. A reasonable order:
  - **A.** Controls + ability bar + scanner (section 1, section 2, 4b).
  - **B.** Growths + grafting + robot (section 3), after A's slot contract exists.
  - **C.** Fog lot + ambulance + indoor neutral zone + pharmacy + crematorium + throw + placebo
    (sections 6–7). This can run alongside B.
  - **D.** Database terminal + guide removal (4a) + Hive Eyes/Echo polish (section 5), after A
    and B.

## Done when
- **`tools/gameshot` shots:**
  - the ability bar closed and with Alt held
  - greyed slot reasons
  - crouch
  - both Growths in hand, fresh and dead
  - both extractions mid-procedure
  - a first graft and a fuse graft
  - grafted-player tells at levels 1 and 3
  - the solo robot view
  - each terminal section and tier, and the scan progress ring
  - a Hive Eyes fly-through mid-flight
  - the fog lot from the doors, and from inside the fog
  - the ambulance emerging from the fog
  - the pharmacy with a tube delivery
  - the crematorium burning a thrown item
  - the placebo warm effect and a floating line over a patient
- **Headless tests:**
  - Crouch silences footstep noise, and jump works.
  - Alt+1..4 fires the right slot, each slot keeps its own cooldown, and the 5-ability cap refuses
    a 5th species.
  - One graft gives one level. Botched extraction or implant, spoiling and abort each kill the
    Growth, and a dead Growth can't be grafted.
  - The robot only works with one active player, and robot minigames use the same tolerances
    as hands.
  - Scanning needs line of sight, breaking it resets progress, a completed scan unlocks the tier
    in the host database, and the database persists across a wipe.
  - The Hive Eyes timer starts after the fly-in, and a hit snaps back instantly.
  - A player walking into the fog comes back out, a thrown item in the fog comes back, and the
    ambulance arrives, unloads, leaves, and stops for a player in its lane.
  - Items thrown into the crematorium sell, players and unsellable items bounce out, and pills
    burn for $0.
  - A thrown pill on a teammate shows the line on their machine, and a pill on a patient doesn't
    change vitals.
  - No gold bar code paths remain.
- **Updated tests:** `braintest` (rename to growthtest), `dissectiontest`, `looptest`,
  `inventorytest`, `devtest`, `mapcheck`, and the nettest scenarios `brains`, `dissection` and
  `combat`. Add new nettest scenarios for grafting, scanning, the ambulance, throwing and pills.
- `tools/playtest.tscn -- --god` still passes on the usual seeds.
