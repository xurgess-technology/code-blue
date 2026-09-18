# Handoff: items-cut (slot wt-1)

## Done and working
- **The cut.** Loot table is 11 kinds: pill bottle, X-ray film, heart monitor, gold watch, ultrasound
  (plain) and desk phone, laptop, defibrillator, reflex hammer, EpiPen, pulse oximeter (trinkets,
  `trinket: true`), plus the brains and eyes. The 11 cut kinds and the old pulse oximeter are gone from
  `loot_table.gd`, `loot_models.gd`, `assets.gd`, `grips.gd`, `wall_pages.gd`, tests, docs, and the unused
  model files (`git rm`).
- **New kinds** `epipen` and the new `pulse_oximeter`: primitive models, grips, database blurbs, no behaviour (chunk B).
- **Room keys** now use the real generated kinds (`patient_room`, `supply_closet`, `janitor_closet`, `lab`, ...).
  The old table used `ward`, `storage`, `maintenance`, `janitor`, `break_room`, which never existed
  (`break_room` is also a safe room), so those rooms were living off the `*` weight.
- **Trinkets are rare:** each shift draws 3 to 5 in total (`LootTable.TRINKETS_PER_SHIFT`, `trinket_weight`
  per kind; phone and hammer likeliest, defibrillator `max_per_shift: 1`). `loot_spawner.gd` places the drawn
  ones, swapping into a plain stack if no spot fits. Radiology spots are floor-only, so X-ray film and
  ultrasound may sit on the floor, and `ROOM_CHANCE` makes radiology spots likelier to hold loot.
- **Pay** (seeds 1..3, shifts 1..3): before $103,668, after $104,153 (+0.5%). Per seed 35,136 / 32,285 / 36,732
  against 34,809 / 35,886 / 32,973 (seed 2 is -10.0%, seed 3 +11.4%; the total is what I held).
- `items.gd` container `rooms` lists (display only) match `room_furnish.gd`; container filling was not touched.
- **Review setup** `--setup=items` (scripts/review_setups.gd, from the icon-bar skeleton, cherry-picked from 0b4a535):
  solo shift on seed 1, standing in the densest loot area, EpiPen in hand, the other trinkets on the floor ahead;
  the log prints the shift's loot count per kind.
- Docs: ASSETS.md, docs/CONTRACTS.md (Loot), docs/KNOWN_ISSUES.md, DESIGN.md (Items).

## Review
`tools\review.bat 1 "ITEMS: walk a shift and see what loot turns up" --setup=items` (from the main checkout's
tools folder: the slot copy of review.ps1 doubles the path). `--seed=N` overrides the seed.

## Zach's feedback and what is open
- Trinkets too common, radiology empty, container room names: all fixed (above).
- He opened the `--setup=items` window and said it "isn't showing anything, I think it's headless". I could
  NOT reproduce: the log showed frames drawn climbing (~50 fps while minimized), tree not paused, camera
  current, menu hidden, and a real-pixel grab of the restored window showed the game. Probable cause: the
  window takes ~30 s (warmup ~20 s, then world) before the shift shows. **Unconfirmed.** I changed
  `scripts/review.gd` so the yellow bar and title say "(loading, about 30 s...)" until `ReviewSetups.stage`
  finishes (`staged()` via group `review_bar`). Reconcile with icon-bar's own fix to the same skeleton.
- Not yet checked by Zach: the loot feel (counts per room, prices), whether 3 to 5 trinkets feels right, the
  EpiPen and pulse oximeter models.

## About to do next
Nothing new. Chunk B (trinket behaviour) is next and uses `trinket_weight` / `max_per_shift`.

## Tests
- `godot --headless --path . --fixed-fps 60 -s tools/loottest.gd -- --seeds=1,2,3,4,5,6,7,8,9`: PASS (84 checks;
  adds `--report`). New: no cut kind anywhere, every kept kind has a model, every room kind that had loot still
  gets some, 3 to 5 trinkets in every shift, defibrillator at most 1, radiology gets X-ray film or ultrasound.
- inventorytest, braintest, databasetest, dissectiontest: PASS.
- devtest: FAIL 1, "unticking it puts you back behind your eyes" (already in docs/FAILING_TESTS.md, #4).
- mapcheck (run earlier, before the trinket rework; no furnishing changes since): only morgue trays out of
  reach on seeds 1, 38, 112 (known issue #2; seed 1 not previously listed).
- Skipped: nettest (its `KEEP` kind changed to `xray_film`), doortest, the other suites, playtest shifts.
- Smoke look: `tools/lootshot.tscn` (shots in tools/loot_shots, gitignored) and `tools/setupshot.tscn` for the setup.

## Risks
- The renderer error "indexing did not unpair geometries from light" also appears in a normal solo start; not from this work.
- Loot spawner rng stream changed, so plans differ from before for the same seed (expected).
- The 54 untracked `art/icons/**.svg.import` files in this slot are Godot's generated imports of art already on
  main; I did not commit them (icon-bar owns them, and committing here risks a both-added conflict).
