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
| E | Use what you are looking at: take, open, put on the shelf, operate. Hold for the time clock and the Re-Gen Pod |
| 1 / 2 / mouse wheel | Switch hands |
| G | Set down what is in the selected hand |
| R | Read the medical guide (while holding it or looking at it) |
| Q | Shove |
| Esc | Pause, or stop operating |
| F2 / F3 / F11 | Graphics quality / FPS counter / fullscreen |

While operating, the mouse moves the tool and the mouse buttons use it.

## Playing with friends

One person chooses **Host a shift**; the lobby shows the address to share. Friends type it into **Join**. On the same network that just works; over the internet, forward UDP port 7777 or put everyone on Tailscale.

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
| `--headless --path . tools/nettest.tscn -- --role=host` then `--role=client` | Real two-process multiplayer test over ENet |
| `--path . tools/minigame_lab.tscn -- --game=saw --patient=seal --bot=1.0` | Run one surgery minigame, interactively or with its bot |
| `--path . tools/gameshot.tscn` | Poses the real game and saves screenshots to `tools/game_shots/` |
| `--path . tools/bench.tscn` | Frame-time benchmark across quality presets |
| `--headless --path . --script tools/mapcheck.gd` | Validates hundreds of generated hospitals |
| `node tools/gen_audio.mjs` (and `gen_audio_*.mjs`) | Regenerates the synthesized sounds |

Asset licences are recorded in [ASSETS.md](ASSETS.md).
