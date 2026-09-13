# Code Blue

A co-op first-person horror game set in a dark, vaguely magical hospital. You and your friends clock in, a dying patient lands on the table (an elephant, a werewolf, a man who ate a stop sign), the tools you need are scattered through the wards, and the night shift is not entirely human.

Built with TypeScript, Three.js, a canvas HUD, Vite, and Electron for the desktop build. No asset files: the hospital is generated from a seed, every texture and creature is made in code, and every sound, including the soundtrack, is synthesized.

See [DESIGN.md](DESIGN.md) for the vision, the rules, and the roadmap.

## Run it

```bash
npm install
npm run desktop
```

That starts the dev server and opens the Electron window. Other ways to run it:

| Command | What it does |
| --- | --- |
| `npm run dev` | Browser build at http://localhost:5173 (good for quick iteration; pointer lock works in a normal tab) |
| `npm run desktop` | Dev server plus the Electron window with hot reload |
| `npm run desktop:prod` | Build, then run Electron against the built files |
| `npm run dist` | Build a Windows installer and a portable exe into `release/` |
| `npm run relay` | Run the co-op relay on port 7777 by hand (only needed for browser play) |

## Playing with friends

One person clicks **Host a shift**. The desktop app starts a relay on port 7777 and shows the addresses friends can join with. On the same network they type that address into **Join**. Over the internet the host either forwards port 7777 or everyone installs Tailscale and uses the Tailscale address. Steam lobbies and invites are planned to replace this.

The host runs the world. If the host leaves, the shift ends for everyone.

## Controls

| Key | Action |
| --- | --- |
| Mouse | Look around and aim the flashlight |
| WASD | Move relative to where you look |
| Shift | Sprint (drains stamina, and monsters hear it) |
| F | Flashlight on / off |
| E | Hold to interact: clock in, operate at the table, revive at the pod |
| Q | Shove whatever is in front of you, monster or friend |
| G | Drop what you are carrying in front of you |
| Space / click | When dead, switch which teammate you are watching |
| P / Esc | Pause (in co-op the world keeps going) |
| F11 | Fullscreen (desktop) |

## The loop

1. Everyone spawns in the clock-in room next to the OR. Hold E at the time clock to start the shift.
2. A random patient arrives. Vitals drain the whole shift. Three or four tools spawn somewhere in the hospital.
3. Carry two tools at a time to the OR. Then hold E at the table and keep the swaying marker inside the green zone to perform each step in order. More surgeons at the table means faster surgery; sloppy holding costs vitals.
4. Save the patient to punch out. The next shift generates a new hospital, a harder patient, and more monsters. Lose if the patient flatlines or everyone dies.
5. Dead surgeons spectate. A living teammate holding E at the Re-Gen Pod for five seconds brings the longest-dead one back.

## Monsters

- **Nurse**: hunts by sight, much farther if your light is on. Runs only while it sees you, gives up after a few seconds, loses interest after a hit. Shoving stuns it.
- **Lurker**: cannot move while any flashlight is on it and is harmless while frozen. In the dark it creeps toward the nearest surgeon. Red eyes. Shoving stuns it.
- **Orderly**: huge and slow, never stops, always knows where you are if you are anywhere near, and heads for the OR when it hears the monitors. Two hearts per hit. Shoving barely moves it.

## Where things live

| File | What it does |
| --- | --- |
| `src/game.ts` | The entire simulation: players, tools, monsters, patient, surgery, damage. Tuning constants are at the top |
| `src/mapgen.ts` | Procedural hospital generator (seeded) |
| `src/map.ts` | Tile grid, collision, raycasting for line of sight, A* pathfinding |
| `src/patients.ts` | Patient list and their procedures |
| `src/net/` | Transport interface, the relay client, the wire protocol, and the session that syncs host and clients |
| `src/scene.ts` | The Three.js world: walls, fixtures, furniture, the table and patient, surgeon and monster models |
| `src/hud.ts` | The 2D overlay: party, vitals, checklist, surgery bar, minimap, screens |
| `src/menu.ts` | The main menu (solo / host / join) |
| `src/audio.ts`, `src/music.ts` | Sound effects and the generative soundtrack |
| `electron/` | Desktop shell and the preload bridge (relay control, fullscreen) |
| `server/relay.cjs` | The WebSocket relay that connects players |

The simulation is entirely 2D (positions, collisions, line of sight, AI) and the 3D scene is a view of it. `window.game` is exposed in the browser console for poking at state.

## Next steps

- Steam peer-to-peer transport (steamworks.js) so nobody needs to forward ports.
- Proximity voice chat.
- The shopping cart, physics carrying, and throwing.
- More monsters, themed wards, doors and power.
- Roles, progression, cosmetics.
