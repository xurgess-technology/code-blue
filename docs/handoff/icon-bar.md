# Handoff: icon-bar (wt-4)

## Done and working
- Icon item bar (scripts/hud.gd `_draw_hands`, pure layout `Hud.bar_units`): four slots, category borders, key numbers,
  count badges, selected slot lifted, bulky = one wide slot, name flash above the bar (2 s), pickup pop (0.4 s),
  spoil ring + grey, used-trinket crack, Alt swap with the ability bar (small rows sit 46 px above the bar so a lifted slot never touches them).
- `scripts/item_icons.gd` (ItemIcons): icon lookup, category borders, greyscale copies, alias `eye_hive`->`hive_eyeball`.
- Icons elsewhere: ability bar (Hive Eyes/Echolocation icons with glow), database item/procedure pages and item cards,
  OR monitor step + supply rows, table prompt "Hold X to do this." icon. SVG imports have mipmaps; warmup calls `ItemIcons.preload_all()`.
- Review setups skeleton: `scripts/review_setups.gd`, `--setup=<name>` (main.gd `_launch`/`_boot_setup`), setup `icons`. Documented in RULES.md, CONTRACTS.md, tools/review.ps1.
- review.gd logs frames drawn / camera / fax state every 3 s and "[review] first frame shown".

## Half-done / unverified
- Blank-window report: I could not reproduce it. The window draws (~45 fps while minimized, camera current, fax idle).
  The first `icons` setup put the player facing the dark break-room projector wall; that is likely what looked "blank". It now starts in the OR facing the table.
  items-cut's "(loading...)" title (commit bb5878e) touches the same skeleton files: reconcile, don't duplicate. The window also takes ~20 s to warm up before anything shows.
- Zach has not yet confirmed the fixed layout (lift vs abilities, name flash position, 0.4 s pop) or the icons setup.
- Only checked at 1280x720 (layout is bottom-anchored, so 1080p/narrow should match).

## Zach's feedback so far
1. Lifted slot overlapped ability circles -> fixed (SMALL_LIFT).
2. Name flash overlapped abilities -> moved above small rows; message moved up.
3. Pop too fast -> 0.4 s.
4. Wants review windows to start in a state ready to test -> `--setup=`.

## Next
Wait for Zach's reply on the reopened window; database page check in-game (projector screen was dark in my grab).

## Review command
`tools\review.bat 4 "ICONS: pick things up, switch slots, hold Alt, open the database" --setup=icons` (use the main checkout's tools folder).
Smoke tools: `tools/iconshot.tscn` (bar/abilities/database/OR shots), `tools/setupshot.tscn -- --setup=icons`; run minimized via WMI like review.ps1; shots go to tools/game_shots (ignored).

## Tests
Pass: hudtest (new), inventorytest, controlstest, databasetest (this session); orscreentest and pockettest passed before the last layout/setup edits and were not rerun. Nothing skipped.

## Known risks
- Nothing sets `used: true` on trinkets or `fresh`/`spoiled` on non-eye/brain parts yet (eyes and brains use their own systems).
- Table prompt icon is found by parsing "Hold [N] Name to do this." text.
- A bulky pair whose slots wrap round the bar (not adjacent) stays two squares with a bracket, not one wide slot.
- Database "other items" grid is empty until items are picked up (existing behaviour).
- Renderer logs "BUG, indexing did not unpair geometries from light" in the setup path; not investigated.
- RULES.md here lacks main's "straight into the thing to test" bullet; I added a copy plus an example, expect a merge conflict there.
