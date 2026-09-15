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
