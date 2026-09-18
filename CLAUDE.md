# Malpractice

Co-op hospital horror in Godot 4.7 / GDScript. The game is **Malpractice** and the hospital is **St. Doe's General** ("Doe General" on faxes).

## Read first
- **[docs/FAILING_TESTS.md](docs/FAILING_TESTS.md)**: tests already failing on `main`, and how to run every test.
- [DESIGN.md](DESIGN.md): what the game is. [docs/CONTRACTS.md](docs/CONTRACTS.md): how the systems fit together.
- [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md): open problems, grouped by system (long; search it).
- [docs/FAX.md](docs/FAX.md): every fax-screen transition and its timing.
- **[RULES.md](RULES.md) › Workflow: who does what. Talking to Zach, you are the orchestrator (or the theory agent, if Zach says so); handed a slot and a branch, you are a subagent. Follow your part.**
- **NOW.md (gitignored, may be missing): what's being worked on right now.**
- **[RULES.md](RULES.md): how we work, including how every change gets logged in [CHANGELOG.md](CHANGELOG.md) (written by the orchestrator when work lands on `main`: next patch under today's date, `config/version` in `project.godot` to match).**

## Gotchas
- Headless tests: add `--fixed-fps 60`, and run them one at a time per checkout (parallel runs in one directory segfault).
- GDScript `:=` fails to infer the type of an untyped return (autoloads, preloaded scripts without `class_name`): annotate the type.
- An inner class can't see the outer script's constants when the script has no `class_name`.
- `.bat` files must keep CRLF line endings (`.gitattributes` handles checkout; don't rewrite them with tools that emit LF).
- Sounds are generated, not recorded: `node tools/gen_audio.mjs` rewrites `audio/` deterministically. Numbered files (`x_01.wav`, `x_02.wav`) are one cue, `x`.
- New content that draws for the first time must be registered in `scripts/warmup.gd`, or it stutters on first use.
