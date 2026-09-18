# Development rules

How we work on Malpractice. Short, and meant to be followed. More rules land here as we make them.

## Workflow

Zach talks to one **orchestrator**, sometimes to a second **theory** agent, and never directly to
the subagents doing the work.

- **The orchestrator** takes what Zach wants, splits it into tasks, and hands each one to a
  subagent. It owns `main`: it merges, writes the changelog, bumps the version and keeps NOW.md
  current. It writes code only for merge fixes and one-line tweaks; everything else goes to a
  subagent so it stays free to talk.
- **Subagents** build one task each, in a work slot. Sonnet on medium by default; Opus on high for
  netcode, work across several systems, or a bug that already beat one attempt. They commit on
  their own branch only: no merging, no pushing, and no touching CHANGELOG.md or `config/version`.
- **The theory agent** bounces ideas around. It reads NOW.md to know what's in flight and doesn't
  change code.

### Work slots

Four long-lived worktrees in `..\Malpractice-slots\wt-1` to `wt-4`, reused from task to task so
Godot's import cache stays warm. At most four tasks run at once, one per slot. They leave out
`deprecated/`.

- `tools\slots.bat` makes any missing slots. `tools\slots.bat status` shows what each holds.
- `tools\slots.bat take 2 hive-lunge` starts branch `hive-lunge` from `main` in slot 2 (about 10 s).
- `tools\slots.bat free 2` puts slot 2 back on `main` after its branch is merged.
- Don't use the Agent tool's own worktrees: tell the subagent its slot's path and to stay in it.
- Each slot has its own save folder (`%APPDATA%\Malpractice-wt-N`, set by a gitignored
  `override.cfg`), seeded with Zach's settings and seen tips. Review windows and tests in a slot
  never touch Zach's own saves, and slots never share test files.

### Status

When Zach asks for **status**, the orchestrator answers with a table, one row per slot (all four,
idle ones too): **Slot**, **Branch**, **Overall task** (what the branch is for), **Working on now**
(the step it's on this minute) and **Status** (Building, **Waiting on Zach**, Testing, Ready to
merge, Idle). Below it, one line each for what's queued and what's blocked on what. It checks the
branches (`git log main..branch`, `tools\slots.bat status`) first, and says so when it can't see
something.

### The brief

The orchestrator gives each subagent: the goal, what done looks like, what Zach should see, the
slot, and the branch.

### Reviews

Nothing gets tested hard until Zach has played it.

- When there's something to see, the subagent opens it and stops:
  `tools\review.bat 2 "HIVE: does the lunge read?"`. The window's title and a yellow bar at the top
  of the screen say `SYSTEM: what to do`, short. Add `-Scene res://...` to start in a lab scene,
  `-Count 2` for two co-op windows, and game flags after that (`--seed=3`).
- **A review window drops Zach straight into the thing to test.** No home screen, no lobby, no
  getting ready: it opens in a shift (or a dev-room spot) with the items in hand, the monster or
  patient staged and the player where the action is. Each task adds its own named setup in
  `scripts/review_setups.gd` and opens with `--setup=<name>` after `--`. If setting up needs
  clicks, it isn't ready to be a review. To add one: an entry in `SETUPS` and a static function that
  stages things with the helpers there (`place`, `give`, `give_abilities`, `floor_item`); then
  `toolseview.bat 4 "ICONS: pick things up" --setup=icons`.
- **Review windows never take focus.** They open minimized and flash in the taskbar. Nothing
  opens a game window any other way while Zach might be using the machine.
- Before opening it, the subagent has done the smoke look (Tests that make sense, below).
- The subagent ends its turn with exactly: the window's line, one sentence on what to look at, and
  anything it's unsure of. The orchestrator relays that as is, then continues **the same subagent**
  with Zach's reply, so it keeps its context.
- Zach closes the window when done. The log is in the slot's `.godot\review-1.log`.

### Tests that make sense

- **While building:** it loads, it parses, and the one check that proves it works passes. No full
  suites for something Zach hasn't seen.
- **A smoke look before every review window.** Headless checks test rules, not what's on screen,
  so the subagent launches the game, goes through what it built once, takes a few screenshots and
  looks at them (the new body from another camera, the screen that mentions the new thing, the
  item in the hand). Anything obviously wrong gets fixed before Zach is asked to look. It's one
  pass, plus one after each fix. It doesn't chase polish or tune feel and difficulty: that's Zach's
  review. **If the thing is properly broken** (it doesn't work at all, or the same failure keeps
  coming back), the subagent may loop until it works. The look never takes focus: use the
  minimized review window or an offscreen render (`tools/style_lab`), never a window that pops up.
- **After Zach's okay:** merge `main` into the branch, then run the tests for the systems it
  touched. Anything failing that isn't in docs/FAILING_TESTS.md gets fixed before merging.
- **The full sweep** (every headless test scene, the playtest shifts, `tools/nettest_run.gd`) is
  the orchestrator's, after several merges or at the end of a day. What it finds gets fixed or
  written into docs/FAILING_TESTS.md.

### Merging

The orchestrator merges one branch at a time into `main` with `git merge --no-ff`, writes its
changelog entry and version bump in the same commit (or in a commit right after the merge), updates
NOW.md, and frees the slot.

**Pushing:** `main` goes to GitHub only when Zach says to push. Branches stay local.

### NOW.md

A gitignored file at the root that says what's happening right now. The orchestrator rewrites it
whenever something changes, so the theory agent (or Zach) can read it cold.

```markdown
# Now

- **wt-1** `hive-lunge`: the Hive's lunge gets a wind-up. **Waiting on Zach** (review window open).
- **wt-2** `fax-stamps`: stamps land on the beat. Building.
- **wt-3**, **wt-4**: idle.

## Next
- Rocket boot fuel pickup at the pharmacy.

## Recently merged
- 0.6.9 Cameras: over-the-shoulder follows the flashlight.
```

Statuses: Building, **Waiting on Zach**, Testing, Ready to merge.

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
- **Log it when it lands.** An entry is written when its work lands on `main`, by the orchestrator,
  as part of the merge. There is no "Unreleased" section (work in flight is in NOW.md): new work
  goes straight under today's date as the next patch.
- **The version lives in two places.** Update `config/version` in `project.godot` to match the
  newest entry.
- **Tone.** Casual, and a joke now and then is welcome, but every line says what actually changed.
- **Big moments get shouted.** A decision that changes what the game is (a rename, a new player
  body, a whole rebuild) gets a loud name, capitals and exclamation marks and all:
  `- **0.5.10**: WE ARE NOW MALPRACTICE!!!!!!!`. Keep it rare so it stays funny.
