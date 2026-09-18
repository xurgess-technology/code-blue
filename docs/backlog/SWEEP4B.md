# Backlog: Growths, Grafting, the Solo Robot, the Dev Panel and Later Ideas

**Status: not scheduled.** These items were agreed with Zach on 2026-09-14 as part of the original
Sweep 4. On 2026-09-15 they were postponed so Sweep 4A (`docs/SWEEP4A.md`) could ship first.
Several of them need new models, and Zach doesn't want new Blender work for now.

**Before building any of this,** read what Sweep 4A actually landed (`docs/SWEEP4A_LOG.md` and
the CONTRACTS "Brains" section). 4A made these choices that this backlog has to replace:
- Abilities still come from **brains + the blender**, with points and levels, and feed the 4
  ability slots through a slot API. Grafting replaces that source; the slots and HUD stay.
- The database's third monster tier is called **"Harvested"** (a brain was harvested or
  absorbed). It becomes "Harvested or grafted", and brain wording becomes Growth wording.
- The dev panel got no new Sweep 4 tools, only the gold bar removal.

---

## 1. Growths replace brains
Staff call it **the Growth**, and the database files it as *Anomalous Tissue*. A Growth is a
living parasitic mass. It's what turned the patients into monsters, and its powers become
theirs. Rename every brain item kind, string, model, dissection target and dev tool. The blender
is **removed**.

Today brains are item kinds `brain_hive` / `brain_discharged` (`dissection.gd`
`BRAIN_KINDS`), with meshes from `brain_model.gd`, spoiling in `brains.gd`, the break-room
blender in `blender.gd`, and the harvest minigame in `scripts/dissection/brain_forceps.gd`.

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

**Hive Knot (Hive)**
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
- **Lore:** the Growth ate its eyes and enlarged its hearing, which is why it's blind and hunts
  by sound.
- **Tell on the living monster:** the throat swells and pulses when it stops to listen, with a
  violet glow under the jaw.
- **Extraction:** go in **through the neck, not the skull**. The membranes are fragile, and
  shredding them kills the Growth. Cutting the last attachment makes it **shriek**, a real
  `emit_noise` event that can pull monsters to the OR.
- **Death:** it sags, deflates for good and stops clicking.

**Art:** procedural meshes in the style of `brain_model.gd` (no Blender needed for the Growths
themselves). The Hive Knot is a sphere cluster with a lens shader and animated pupils; the
Bellows is a lathed ribbed shape with two thin membrane planes and an inflate animation.
Register them in `warmup.gd`, and get shaders through `Minigame.cached_shader()`. The dissection
rig needs a per-species host site and opening: `monster_builder.gd` for the skull vs. neck, and
`monster_rig_look.gd` for the glow showing through the skin. The monster tells may need model
work on the Blender-made rigs; check before scheduling.

## 2. Grafting
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
- The first-ability card from 4A becomes the "first graft card."

## 3. Solo surgical robot
- A da Vinci–style **surgical robot** stands at an OR table, with a console. (This likely needs a
  model; decide between primitives and Blender when scheduling.)
- **It only works when exactly one active, non-spectator player is on the shift.** In co-op it
  is present but switched off. Players can only join between shifts; anyone who joins mid-shift
  spectates.
- **Flow:** the solo player puts the Growth on the tray, straps themselves to the table and takes
  control. The camera moves to the robot's view and the player runs the **normal graft minigames
  with their own inputs**. The robot never acts on its own.
- **It works exactly like hands:** same speed, same precision, same tolerances.
- Abort works the same as grafting. Taking damage while strapped doesn't end robot control on
  its own; the player decides whether to abort.

## 4. Dev panel
- Database: unlock all entries, reset.
- Instant graft: pick a species and a level, and it goes into the next slot. Clear slots.
- Spawn a Growth (either species, alive or dead).
- Robot test mode: enable the robot even with more than one player.
- Send the ambulance now.
- Fog toggles: density, and the turnaround effect on or off.
- Give money and placebo bottles.
- Remove the old brain and blender dev actions. (Gold bar actions are already gone after 4A.)

## 5. Tests and shots this work needs
- **Headless:** one graft gives one level; a botched extraction or implant, spoiling and abort
  each kill the Growth; a dead Growth can't be grafted; a 5th species is refused; the robot only
  works with one active player, and robot minigames use the same tolerances as hands; a harvest
  or graft unlocks tier 3.
- **Updated tests:** rename `braintest` to `growthtest`; update `dissectiontest`, `devtest` and
  the nettest scenarios `brains` and `dissection`; add a nettest scenario for grafting.
- **Shots:** both Growths in hand, fresh and dead; both extractions mid-procedure; a first graft
  and a fuse graft; grafted-player tells at levels 1 and 3; the solo robot view.
- Update `DESIGN.md` (brains to Growths, grafting) and `docs/CONTRACTS.md`.

---

## Later (not designed yet)
- **Growths:** size tiers (small / mature / overgrown), selling Growths at the crematorium.
- **Abilities:** Puppet, Rise, ability side effects, moving abilities between slots.
- **Shop:** a gift shop, cosmetics.
- **From the original design:** two-person steps, networked physics and a shopping cart, voice
  chat, classes, progression.
- **Polish:** gown clipping, infection styles, balance, a flashlight for teammates.
- **Placebo ideas that were discussed but not specced:** silly stacking tiers, and a bottle
  rattle the Discharged can hear.
- **Open bugs** stay in `docs/KNOWN_ISSUES.md`. The Steam backend has never been tested against a
  real Steam client.
