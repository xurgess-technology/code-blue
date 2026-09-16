# Sweep 4A Log

## Chunk 1: Controls, ability slots and HUD, scanner (`s4a-controls`)
Landed: crouch (silent, no low-ceiling stand-up), grounded jump, hold-R scanner with
range/LOS/host-recorded sighted+scanned, and the 4-ability-slot system (Alt bar animation,
per-slot cooldowns, first-ability card) replacing `best_path()`. Guide's `read` moved to E.
Tests: controlstest (18/18), braintest (82/82), settingstest (84/84), devtest (0 failures),
two independent `playtest --god --seed=1` runs (PASS). CONTRACTS "Brains" section documents
`add_ability`/`set_level`/`slot_of`.
Known issues logged: item slot bar doesn't shrink/slide when Alt is held (only ability icons
animate — a visual TODO, not a bug); no rebind-conflict detection; scanner LOS is a single
centre raycast, not a cone; crouch's third-person pose is a fixed-weight lean, not blended
against every hold/carry pose.

## Chunk 2: The fog lot, the ambulance, and the safe zone moves inside (`s4a-foglot`)
Landed: lot stripped to bare asphalt/stall lines/canopy/bay marking/a few street lights; fog
belt (steer-back, item pull-back, screen-space tint) via `fog_ring.gd`; driven ambulance
(emerges from fog, parks, unloads, drives back, honks/stops for a blocked lane); spawns and
the safe zone moved indoors to the lobby+break room, with space reserved for chunk 3's
pharmacy/crematorium. Tests: mapcheck (one pre-existing, unrelated morgue-tray nav flake, not
caused by this chunk), spawncheck, looptest, fogtest (new, 0 failures), perfprobe ("lot, facing
the fog" holds 60fps/60fps 1% low on all quality tiers), `playtest --god --seed=1` (PASS).
**Follow-up during review:** the initial build's fog was screen-tint-only (only visible once
the local player's own position was already deep in the belt), so the border wall was plainly
lit and visible from the clear area / doors — caught by an actual look at `tools/fogshot.tscn`
screenshots. Fixed with a real local `FogVolume` in `hospital_builder.gd` and by pulling several
street lights (left over from the old parking-lot layout) back inside the fog belt's clear area;
re-verified with fresh screenshots, fogtest, and perfprobe. Known issues logged: `FogVolume` only
renders when volumetric fog is on (off at the LOW quality preset — the lot gets only the base
depth fog there, not specifically retuned); one repositioned lamp's beam still faintly reaches
the wall; the ambulance's own headlights light the wall behind the bay by design.

## Chunk 3: Pharmacy, crematorium, charged throw, placebo pills, no gold (`s4a-pharmacy`)
Landed: charged throw (hold to charge, tap to drop, host-run physics); gold bars fully removed
(`grep -ri gold` finds only a UI color name reused for loot in general and removal-documentation
comments, no functional gold-bar code); pharmacy window (tube delivery, sells placebo pills);
crematorium furnace (throw-to-sell, bounces unsellable items and bodies, cheap fire visuals);
placebo pills (buy/eat/throw, warm effect, floating lines, OR green blip, burns for $0). Tests:
inventorytest (79/79), devtest, mapcheck (same pre-existing morgue flake), spawncheck, looptest,
perfprobe's crematorium scenario (60fps all tiers), `playtest --god --seed=1` (PASS).
**Follow-up during review:** the furnace was unreachable on some seeds — `economy.gd`'s
floor-placement probe cast its ray from above a normal ceiling height, so on seeds where the
reserved crematorium rect had full ceiling coverage the furnace got built a full storey up,
floating on the ceiling. `looptest.gd`'s bot-driven furnace throw always timed out because of
this even though the manual `inventorytest.gd` check (which teleports straight there) passed.
Fixed the probe height and, separately, widened the furnace's grate gaps (0.13m → 0.37m) since
the narrow original gaps meant ordinary aim/position variance was enough to miss. Known issues
logged: the pharmacy/crematorium footprints can still overlap lobby furniture on some seeds (not
this chunk's fix to make — flagged for whoever owns entrance.gd's lobby layout); the pill hit
check is a per-frame distance poll, not swept, and untested under lag; chunk 4 owns the placebo
pill database/terminal entry.
