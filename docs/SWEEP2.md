# Sweep 2: brief for every worker

Project: Code Blue, Godot 4.7.2, GDScript. Read `DESIGN.md`, `docs/CONTRACTS.md` and
`docs/KNOWN_ISSUES.md` first. Godot console binary:
`"/c/Users/ZachBurgess/Desktop/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"`.

## How we work

- **Every worker runs in its own git worktree on its own branch.** Commit your work on your
  branch as you go (small commits, clear messages ending with
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`). Never push, never touch `main`,
  never rebase other branches. The main session merges branches wave by wave.
- `.godot/` is not in git: run `godot --headless --path . --import` once in your worktree
  before anything else (and again after adding a script with a `class_name`).
- **Stay inside your ownership list.** Small, clearly-commented hooks in a core file are
  allowed when your feature cannot exist without them; keep them minimal and list every one in
  your final report, because the main session resolves merge conflicts from that list.
- Prefer `const X := preload(...)` to relying on another file's `class_name`.
- Assets: CC0 only, recorded in `ASSETS.md` under a heading for your area. Everything must
  degrade when an asset is missing (`Assets.has()` / `Assets.spawn()` returning null).
- New content that renders must be registered in `scripts/warmup.gd`; shaders through
  `Minigame.cached_shader()` where relevant. Performance target: 60 fps, 1% lows above 50 on a
  Radeon 890M at 1600x900 medium. Do not regress `tools/perfprobe.tscn` numbers noticeably.
- Multiplayer rules stay: the host owns the truth (monsters, items, containers, patients,
  damage, phases, money); each client owns its own movement and aim and the host trusts it.
  Anything you add that changes world state must work for a client, not only the host, and
  must replicate. Interactables keep the `interact_prompt / interact_hold / interact` contract
  with machine-stable `interact_id`s.
- **Test for real.** Headless: always pass `--fixed-fps 60` (runs ~12x faster). Keep
  `tools/playtest.tscn` passing (`--god` runs for both patients and both ailments), extend the
  test tools for what you build, and take windowed screenshots (`--resolution 1280x720`) of
  anything visual and look at them honestly. Two-process tests: `tools/nettest.tscn`.
- Delete throwaway probe scripts before your final commit. Put screenshots in a gitignored
  `tools/*_shots/` folder.
- Final report (your last message): what you built, how you tested it (commands and results),
  every hook you added outside your ownership list, new contracts other workers rely on, and
  known problems left. Also add your open problems to `docs/KNOWN_ISSUES.md` and your new
  contracts to `docs/CONTRACTS.md` (short sections under a heading for your area).

## Locked design decisions (from Zach, 2026-09-13)

Networking
- Steam through GodotSteam (dev app id 480, `steam_appid.txt`), with invites and lobbies.
  ENet by IP stays for local testing and bots. `Net` keeps one API for both.
- Clients own their movement; the host trusts them. Someone joining mid-shift spectates and
  spawns at the next shift. The host leaving ends the session. A client leaving drops what they
  held where they stood; if operating, the step pauses for someone else.

Dev room (an easter egg)
- A secret way into a dev room that only Zach knows, something he can show friends. Not a menu
  button. It must also work when hosting so friends can join into it.
- A dev gun: primary kills whatever it hits (monsters, players, bots), secondary knocks down
  without killing.
- Bot allies you can spawn: follow, stay, carry, operate. Target dummies. Any of them can be
  downed or killed.
- A dev panel: god mode, noclip, time scale, spawn any item / monster / patient with any
  ailment, set vitals, set difficulty, trigger the patient phone call, toggle lights, graphics.

Settings
- Master / music / effects volume, window mode (fullscreen, borderless, windowed), brightness,
  mouse sensitivity, field of view, graphics preset. No invert Y, no key rebinding.

Downed players
- 0 HP means downed, never killed outright. A downed player can crawl. After 5 minutes of
  bleeding out they are dead until the next shift.
- Teammates carry a downed player to the extra player table in the OR, and with a suture kit
  do a "stitches" minigame. The Re-Gen Pod is deleted. Everyone down or dead fails the shift.

Hospital
- One floor. An entrance building holds the break room with the time clock and phone, and the
  OR (two patient tables plus one player table, the supply shelf, a wall screen). Three to four
  procedurally generated wings branch off it; deeper means bigger, darker, better loot.
- Wings are made of real hospital rooms with sensible furniture layouts: patient rooms, supply
  closets, pharmacy, nurse stations, waiting room, restrooms, offices, lab, radiology, morgue,
  janitor closet, cafeteria, joined by long, empty, liminal hallways.
- Monsters never spawn in the entrance building.
- About twice as many needed supplies as before, and every wing holds some of what the case
  needs.
- Outside the entrance: a neutral area (ambulance bay and parking lot) with the shop in a
  parked van, a sell bin, and a spot in the middle where bought gold bars stack.

Shift loop
- Players start in the neutral area, walk in, clock in. A 60 second grace period to look
  around. Then the break-room phone rings (subtitles, no voice) about a patient on the way;
  shortly after, paramedics wheel the patient in and put them on an OR table.
- Mid-shift the phone may ring again with an optional extra patient: answering accepts
  (second patient table, bonus pay if saved), ignoring is fine.
- No shift timer besides each patient's vitals.
- Clock out once every accepted patient is stable or dead (a dead patient costs pay), then
  walk out to the neutral area: sell loot, buy things, walk back in for the next shift.
- Money persists across shifts. No quota. A team failure (everyone down or dead) is game over:
  money resets.

Inventory and loot
- Four hand slots (1-4 and the wheel). Bulky loot takes two slots.
- Sellable non-surgical loot spawns around the hospital. Surgical supplies have a teal tint /
  glow, sellable loot a gold one, so it is obvious what the surgery needs.
- The shop sells gold bars, for now: each one bought stacks on the pile in the middle of the
  neutral area, higher and higher until it is ridiculous.

OR screen and HUD
- A wall monitor in the OR shows each patient's vitals, ailment, step checklist and the
  supplies needed (ticking off as they reach the shelf).
- The HUD becomes minimal: the four slots, the interact prompt, health, short messages, and a
  minigame's one-line hint. Everything else moves into the world.

Minigames
- More intuitive: the patient and the tool show what is right (colour, sound, motion,
  reaction), no slider matching, at most one short hint, more forgiving windows. Bandaging and
  sawing felt the worst.

## Waves and ownership

**Wave 1 (parallel):**

| Worker | Builds | Owns |
| --- | --- | --- |
| `dev` | Dev room easter egg, dev gun, bots, dev panel | new `scripts/dev/**`, `tools/devtest.*`; hooks in `main.gd`, `menu.gd`, `player.gd`, `game.gd` |
| `settings` | Settings screen (main menu and pause), persistence | new `scripts/settings.gd` (autoload), `default_bus_layout.tres`; hooks in `menu.gd`, `main.gd`, `look.gd`, `audio_manager.gd`, `music.gd`, `player.gd` |
| `net` | GodotSteam backend, lobbies and invites, the join-name bug, a working multi-client `nettest` with lag, mid-shift join (spectate), leave handling, snapshot deltas | `scripts/net.gd`, `addons/godotsteam/**`, `steam_appid.txt`, `tools/nettest.*`; the networking section of `game.gd`; `report*` / `apply_remote*` in `player.gd`, `world_item.gd`, `monster.gd`; hooks in `menu.gd`, `main.gd` |
| `minigames` | Rework gauze and saw first, then remove slider-matching from the other steps | `scripts/surgery/games/**`, `tools/minigame_lab.*` |
| `hospital` | Entrance building, wings of real rooms, liminal halls, neutral outdoor area geometry and anchors, monster spawn rules, supply density | `scripts/mapgen.gd`, `scripts/hospital_builder.gd`, `scripts/item_spawner.gd`, `scripts/fallback_level.gd`, `scripts/containers/**`, new `scripts/level/**`, `assets/**`, `ASSETS.md`, `tools/mapcheck.gd`, `tools/spawncheck.gd`; hooks in `game.gd` for reading new `level_info` |

**Wave 2 (after merging wave 1):** `loop` (shift loop, phone, paramedics, several patients at
once, clock out, neutral area flow, game over) and `inventory` (four slots, two-slot loot, loot
items and colours, selling, money, gold bar shop).

**Wave 3:** `downed` (downed state, crawling, carrying, player table, stitches ailment, suture
kit, stitches minigame, pod removal) and `orscreen` (OR wall monitor, minimal HUD).

**Wave 4:** integration, test bot updates, performance pass, docs.

## Contracts wave 1 introduces (so later waves can rely on them)

- `hospital` adds to `level_info` (keep every existing key working, `table_pos()` still means
  the first patient table):
  - `tables`: `[{position: Vector3, yaw: float, kind: "patient" | "player"}]` (2 patient, 1 player)
  - `or_screen`: `{position, yaw, size: Vector2}` for a wall monitor in the OR
  - `phone`: `{position, yaw}` in the break room
  - `entrance`: `{position, yaw}` (the main doors), `entrance_rect`: `Rect2` in world XZ of the whole entrance building
  - `ambulance`: `{position, yaw}` where paramedics arrive and leave, outside
  - `neutral`: `{spawn_points: [Vector3], shop: {position, yaw}, sell_bin: {position, yaw}, gold_pile: {position}}`
  - `wings`: `[{id, rect: Rect2, depth: int}]`, and each room entry carries `wing` and `depth`
  - monster spawn points never lie inside `entrance_rect` or the neutral area
- `dev` adds `game.damage_player(p, amount: int, source: String)` and
  `game.kill_monster(m)` on the host (routes through the existing hit code), and a dev mode flag
  `game.dev_mode`. Wave 3 `downed` will make damage down players instead of killing them.
- `settings` adds the `Settings` autoload: `Settings.get_value(key)`, `Settings.set_value(key, v)`,
  `signal changed(key, value)`; keys `master_volume`, `music_volume`, `sfx_volume`,
  `window_mode`, `brightness`, `sensitivity`, `fov`, `quality`.
- `net` keeps `Net.host() / join() / leave() / is_host() / my_id() / names` and adds
  `Net.host_steam()`, `Net.join_steam(lobby_id)`, `Net.backend` (`"enet" | "steam" | "solo"`),
  `Net.invite_friends()`.
