# Development rules

How we work on Malpractice. Short, and meant to be followed. More rules land here as we make them.

## Changelog

[CHANGELOG.md](CHANGELOG.md) is the log of what we do.

- **Versions are days.** Each day of work gets one minor version. The next day with changes bumps
  the minor (0.7.x), and 1.0.0 waits until it's a game you'd charge money for.
- **Patches are things.** Each thing we do that day gets the next patch number and a short name.
  The first thing of the day is `.0`. Newest first, both days and entries.
- **The shape.** A bold date line with the day's version, a bullet per thing, and a sub-bullet per
  change starting with `Added:`, `Changed:`, `Fixed:` or `Removed:`. No headings.
- **Stay out of the weeds.** One line per change, saying what changed, not how it works: how it
  works belongs in DESIGN.md or docs/CONTRACTS.md. Numbers only when the number is the point.
- **Only what someone would notice.** A day is usually a handful of entries; a day with lots of
  cool stuff can have more. Small things share one **Polish** entry. Cool technical wins (a netcode
  rewrite, a big performance cut) get a line; test tools, docs and dev-panel buttons usually don't,
  since git history already has them.

  ```markdown
  **2026-09-18 (0.6.x)**

  - **0.6.2**: Rocket boots
      - Added: Rocket boots at the pharmacy: fly on a fuel bar, faceplant into walls.
  ```
- **Log it when it lands.** A change and its changelog entry go in the same commit. There is no
  "Unreleased" section: new work goes straight under today's date as the next patch.
- **The version lives in two places.** Update `config/version` in `project.godot` to match the
  newest entry.
- **Tone.** Casual, and a joke now and then is welcome, but every line says what actually changed.
- **Big moments get shouted.** A decision that changes what the game is (a rename, a new player
  body, a whole rebuild) gets a loud name, capitals and exclamation marks and all:
  `- **0.5.10**: WE ARE NOW MALPRACTICE!!!!!!!`. Keep it rare so it stays funny.
