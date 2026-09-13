# Code Blue

A co-op first-person horror game set in a dark, half-abandoned hospital. Clock in with your friends, search the wards for the supplies a dying patient needs, stock the OR shelf, and operate, while something blind listens for your footsteps and something tall waits for you to look away.

Built with Godot 4.7 (GDScript). See [DESIGN.md](DESIGN.md) for the game design and [docs/CONTRACTS.md](docs/CONTRACTS.md) for how the systems fit together.

## Play

Double-click `play.bat`. It expects Godot at `Desktop\Godot_v4.7.2-stable_win64.exe\`; edit the file if yours lives elsewhere.

From a terminal:

```bash
"/c/Users/ZachBurgess/Desktop/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe" --path .
```

Or open the folder as a project in the Godot editor and press F5.

## Controls

| Key | Action |
| --- | --- |
| Mouse / WASD / Shift | Look, move, sprint |
| F | Flashlight |
| E | Use what you are looking at: take, open, put on the shelf, operate. Hold for the time clock and to pick up a downed teammate; E again puts them down or on the player table. Downed, E calls for help |
| 1-4 / mouse wheel | Select a hand slot (bulky loot fills two) |
| G | Set down what is in the selected slot |
| R | Read the medical guide (while holding it or looking at it) |
| Q | Shove |
| Esc | Pause, or stop operating |
| F2 / F3 / F11 | Graphics quality / FPS counter / fullscreen |

While operating, the mouse moves the tool and the mouse buttons use it.

## Playing with friends

**With Steam** (Steam running on every machine): one person chooses **Host with Steam**. That opens a friends-only lobby. Invite friends with **Invite Steam friends** on the pause screen (Esc) or from the Steam overlay (Shift+Tab); they accept the invite, or pick **Join game** on you in their friends list, and land in your shift. Names come from Steam. The Steam button only appears when Steam is running; the game uses Steam's test app id 480 (`steam_appid.txt`) until it has its own.

**By IP** (LAN, Tailscale, port forwarding, or testing on one machine): one person chooses **Host (IP)**; the lobby shows the address to share. Friends type it next to **Join (IP)**. On the same network that just works; over the internet, forward UDP port 7777 or put everyone on Tailscale.

Built and tested for four surgeons. Someone who joins while a shift is running watches through a teammate's eyes and clocks in with everyone at the next shift. If a friend drops out, whatever they carried falls where they stood, and if they were operating, the step waits for someone else to pick it up where they left off. If the host leaves, everyone goes back to the menu.

## The loop

1. Aim at the time clock in the clock-in room and hold E.
2. The case arrives: Bob or the seal, with a gunshot wound or an infected limb to amputate.
3. Find the supplies (the HUD lists what the shelf still needs), opening fridges, drawers, trauma bags and pegboards.
4. Put them on the OR supply shelf.
5. Aim at the table and press E to operate each step.
6. Save the patient to punch out into a harder shift.

## Tools for development

| Command (from this folder, with the console Godot binary) | What it does |
| --- | --- |
| `--headless --fixed-fps 60 --path . tools/playtest.tscn -- --god --seed=4242` | A bot plays a whole shift (`--fixed-fps 60` runs it about 12x faster than real time). `--skill=0.0` plays badly, `--ailment=` / `--patient=` pin the case, drop `--god` for a mortal run |
| `--headless --path . --script tools/nettest_run.gd` | Every multiplayer scenario as real separate processes (host plus up to three clients) on localhost: names, fetch and deliver, surgery, leaving with items or mid-operation, joining mid-shift, host quitting or crashing, a whole shift under simulated lag. `-- --only=deliver,late_join` picks scenarios, `--lag=150 --loss=0.05` puts every client behind a bad network, `--only=bandwidth` measures bytes per second |
| `--path . -- --net-lag=120 --net-jitter=40 --net-loss=0.03` | Any joining client plays through a simulated bad connection |
| `--path . tools/minigame_lab.tscn -- --game=saw --patient=seal --bot=1.0` | Run one surgery minigame, interactively or with its bot |
| `--path . tools/gameshot.tscn` | Poses the real game and saves screenshots to `tools/game_shots/` |
| `--path . tools/bench.tscn` | Frame-time benchmark across quality presets |
| `--headless --path . --script tools/mapcheck.gd` | Validates hundreds of generated hospitals |
| `node tools/gen_audio.mjs` (and `gen_audio_*.mjs`) | Regenerates the synthesized sounds |

Asset licences are recorded in [ASSETS.md](ASSETS.md), third-party code (GodotSteam) in [THIRD_PARTY.md](THIRD_PARTY.md).
