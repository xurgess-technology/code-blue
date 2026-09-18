# Handoff: where everything stands (2026-09-18, version 0.6.13)

Written by the orchestrator so work can continue on another machine. NOW.md is gitignored and
doesn't travel; this is its stand-in. Work slots (`..\Malpractice-slots`) are local: on a new
machine run `tools\slots.bat` to make them. Every branch below is already merged into `main`.

## What landed today (all unreviewed by Zach unless noted)

| Version | What | Branch (merged) | Zach's state | Handoff notes |
|---|---|---|---|---|
| 0.6.9 | Strap yourself to an OR table; Control Dr. Botsworth | `graft-strap` | Approved | (in CHANGELOG) |
| 0.6.10 | Eyeball Extraction, vats | `graft-extract` | Approved | (in CHANGELOG) |
| 0.6.11 | The icon item bar, icons in the ability bar / database / OR | `icon-bar` | **Not approved.** He had fixes in (slot overlap, name flash, slower pop) but hadn't re-reviewed | [icon-bar.md](icon-bar.md) |
| 0.6.12 | Loot cut to 11 kinds, EpiPen, pulse oximeter, rooms and pay rebalanced | `items-cut` | **Not approved** (his tweaks were done, he hadn't looked again) | [items-cut.md](items-cut.md) |
| 0.6.13 | Eyeball Grafting: vat stands, the graft, the eye swap and glow, Hive Eyes only from the graft | `graft-surgery` | **Never played by Zach** | [graft-surgery.md](graft-surgery.md) |
| (no entry) | The Sonographer model: stretching neck, probe hand, gel skin, tattered coat, the look interface. **Not in the game yet**: nothing hunts with it | `sono-model` | Seven fixes made, **not re-reviewed**; the echo burst was never seen live | [sono-model.md](sono-model.md) |

## Tests

Run after the merges (see docs/FAILING_TESTS.md for what already fails): grafttest, straptest,
downedtest, braintest, dissectiontest, hudtest, inventorytest, databasetest, controlstest, loottest,
monster_lab, the nettest `graft` scenario: all pass. `braintest` was edited: a Hive brain is now
refused at the blender (Hive Eyes come from the graft). **Not run since the merges:** orscreentest,
pockettest, looptest, doortest, mapcheck, the playtest shifts, the other nettest scenarios: the
full sweep is still owed. devtest still has its one known failure.

## Review windows

`tools\review.bat <slot|main> "SYSTEM: what to do" --setup=<name>` opens a window that skips the
menu (about 30 s to load; the title says "loading" until it's ready). Setups (scripts/review_setups.gd):
`icons`, `items`, `graft`, `graft_back`. The Sonographer stage is
`-Scene res://tools/sono_lab.tscn`. Use `main` as the slot on a machine with no work slots.

## What's next, in order

1. **Zach reviews** icons, items and the graft (the graft first: it's the big one). His feedback goes
   to a fresh subagent per fix; the handoff notes list the open questions.
2. **Sonographer B `sono-brain`** (docs/SONOGRAPHER.md, Opus high): the rename, suspicion, the echo,
   the deafen squeal, the rush and wail, sounds, networking, hooked to the model's look interface.
   Was waiting on grafting C; now unblocked.
3. **Items B `trinkets`** (docs/ITEMS_AND_ICONS.md, Opus high): what the six trinkets do. Was
   waiting on items-cut; now unblocked. Don't run it alongside `graft-trachea` (shared item tables).
4. **Trachea A `trachea-art`**, then **`graft-trachea`** (docs/GRAFTING_TRACHEA.md): waits on the
   Sonographer chunks being merged and on the art.
5. **The surgery overhaul** (docs/SURGERY_OVERHAUL.md): phases 0 and 1 are briefed; not started.
6. **Owed:** the full sweep; a fix for the morgue tray on seed 1 (mapcheck; it's the default review
   seed); the orscreentest full-shift run that was skipped on several branches; the "indexing did not
   unpair geometries from light" renderer warnings in the `--setup` boot path (a normal boot has none).

## Open loose ends

- The `--setup` skeleton was built on `icon-bar` and cherry-picked onto three other branches; the
  merges were reconciled by hand in `scripts/review_setups.gd`, so check it still parses if a setup
  seems missing.
- The theory session's briefs live in docs/: GRAFTING.md, GRAFTING_TRACHEA.md, SONOGRAPHER.md,
  ITEMS_AND_ICONS.md, SURGERY_OVERHAUL.md.
