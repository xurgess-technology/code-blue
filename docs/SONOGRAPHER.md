# The Sonographer (the Discharged, redesigned)

Brief for the orchestrator. Agreed with Zach on 2026-09-18 (theory session). The Discharged gets a
new name, a new look and a new way of hunting. It stays the game's ears monster: blind, and it
finds you by sound.

## Who it is

**The Sonographer.** Ultrasound is echolocation, so this is the hospital's echolocation monster.
It's tall and upright, with its head pushed forward and cocked to listen, so in the dark it never
reads like the Hive's hunch. It wheels an **ultrasound cart** around with it, **plugged into it**:
a cable runs from the cart into the back of its neck. The cart has a squeaky wheel.

## The look (stylized kit, `art/stylized/`)

- **No eyes.** Where the eyes were is flat, smooth, slightly shiny scar tissue, with a faint seam
  where the lids used to be. No eye objects in the sockets. No bandage.
- **Ears** on the large side of normal that swivel toward sounds (keep `MonsterModel.set_ears`).
- **A long neck with see-through skin at the throat,** where the windpipe rings glow. The glow is
  faint while it's suspicious and ramps up bright while it charges an echo.
- **The cable** from the back of its neck to the cart. When it charges, **the glow travels down
  the cable** to the cart, so the charge shows even when only the cart is in sight.
- **The ultrasound cart:** a chunky cart with a monitor, a probe holster and the cable, on
  castors, one of them squeaky. Its screen is just on (a dim glow); it doesn't show anything
  special.
- **Clips:** idle, a walk pushing the cart, listen (freeze, ears snap round), charge (head lifts,
  jaw drops), echo, a rush dragging the cart, the wail (a flurry of blows, with pauses), a stagger
  (shoved), and lying (for the table).
- Reviewed from front, side and face renders, then in the game's lighting (`tools/style_lab`), as
  DESIGN.md › Art style says.

## How it hunts

1. **Suspicion.** Quiet noises fill a suspicion meter, scaled by loudness and distance. It fills
   easily and drains slowly. The game already rates its noises (CONTRACTS › Monsters: walk 0.25,
   pickups 0.15, containers 0.5, and so on).
2. **Loud noises skip the echo.** Anything around 0.8 or louder (sprinting, breaking glass, the
   saw, a slammed door) sends it straight to the spot, as the Discharged does today.
3. **Suspicious:** it stops, its ears snap toward the noise, and its throat glows faintly.
4. **Echo, when the meter is full.** A charge of about 1.2 s (throat and cable glow ramping up,
   clicks speeding up, head up, jaw down), then an echo fires toward where the noise came from.
   The echo empties the meter.
5. **The echo is a wedge,** like a real bat's or dolphin's beam, or an ultrasound fan: about 60°
   and about 14 m to start with. **On deeper wings and later shifts it sweeps**, turning its head
   through an arc while it pings, so the fan covers a whole room. You can see it clearly: a
   translucent fan of grainy scan lines sweeping out fast, but slow enough to read, and a grainy
   afterimage left on the surfaces it swept. **Walls and closed doors block it.**
6. **Caught in the echo = seen.** Every player the echo catches is **imaged**: a flash of
   ultrasound grain over their screen, and **deafened** by a short squeal (below). The
   Sonographer only knows where each of them was at that moment.
7. **The rush:** it rushes to where it imaged the **nearest** player, yanking the cart along
   behind it, clattering, the squeaky wheel squealing faster. If that player has crept away, it
   arrives, stops and listens again.
8. **Contact: it wails on them,** a flurry of blows, until that player is **downed** or gets far
   enough away that it loses them. While it's on someone, it follows them by sound, so sprinting
   keeps it on you. The way out is to break away, get distance, then go quiet: a few seconds
   without hearing you and it drops back to suspicious (and usually echoes again).
9. **Once the player is downed,** it stops and goes back to hunting. It doesn't finish them off.

### The deafen squeal

Everyone the echo catches hears a squeal and goes briefly deaf. **It must never hurt a real
player's ears:** capped volume, about 1–1.5 s, soft ramps in and out, not piercing. Underneath it
the game's audio is muffled (a low-pass on the bus) and comes back over the same time. Generate it
with `tools/gen_audio.mjs` like every other sound.

### Escaping it

- **Freeze or crouch:** crouched footsteps are already silent.
- **Break the fan:** step sideways during the charge, get behind a wall, or shut a door (gently;
  a slam is loud).
- **Decoys:** anything thrown makes noise where it lands, and pulls it there.
- **The flurry has pauses,** small gaps you can slip away through. It must never be a lock you
  can't get out of.
- **Shove it:** the shove still stuns it (2 s). A teammate shoving it off you is the co-op save.

## Calls the theory session made (not yet approved by Zach)

- **Seeing its suspicion:** Zach wants players to be able to read how suspicious it is. The body
  shows it (ears, the faint throat glow). On top of that: while you hold R on a Sonographer you've
  scanned before, a small suspicion meter shows beside the scan ring. Nothing on the cart's screen.
- **The squeal has a settings toggle** to soften it further.
- The starting numbers above (60°, 14 m, 1.2 s charge) are for tuning in the review, not locked.

## Capture, death, and the cart

- Capture works as it does for the Discharged (shove, jab, drag, strap).
- **When it's sedated or killed, the cable disconnects.** The cart, left without its
  Sonographer, **turns into smoke** a few seconds later, as if the monster was what kept the
  machine going. Nothing is left behind.
- **The cart must never snag or block a hallway.** It's dragged through doors and around corners.
  If it gets stuck, it slides free rather than stopping the monster or blocking players.

## The rename

**The Discharged becomes the Sonographer everywhere:** the monster's kind id, display name,
database entry, tips, sound cue names, the roster, tests and nettest scenarios, DESIGN.md and
docs/CONTRACTS.md. The host's database is saved to disk and keyed by monster kind: map the old
`discharged` key to the new one when loading, so nobody loses what they've learned.

The player's **Echo ability stays** as it is for now (from the Sonographer's brain, through the
blender). Later, the **Sonographer's throat becomes its graft part** and Echo becomes the ping
(docs/backlog/SWEEP4B.md). Don't build that now.

## Chunks

| # | Branch | What | Who |
|---|---|---|---|
| A | `sono-model` | The Sonographer and the cart in the stylized kit, with the clips, the throat and cable glow, and the flat scar face. Uses the one-kit rules in DESIGN.md › Art style. | Orchestrator's call; this is Blender-from-Python work |
| B | `sono-brain` | The rename, suspicion, the echo (charge, wedge, sweep, blocking, imaging), the deafen squeal, the rush, the wail and losing you, the cart following it and turning to smoke, sounds, networking. | Opus, high |

A and B can run at the same time. B builds on the current Discharged model with stand-ins (a
glowing throat marker, a primitive cart) behind a small look interface: suspicion 0–1, charge
0–1, the mode, and the cable being plugged in or not. A implements that same interface on the new
model. Whichever merges second hooks them up.

**Timing with grafting:** B touches brains, abilities and the database, as grafting does. Start B
after grafting's chunk C is merged. A can start any time.

**Zach sees:**
- A: `SONOGRAPHER: the model, the cart and the charge glow` (in a lab scene; `monster_lab` has
  close-up shots).
- B: `SONOGRAPHER: make a noise, get pinged, and get away`.

## Done when

- Headless (`tools/monster_lab.tscn`): quiet noises fill suspicion and a full meter echoes; a loud
  noise rushes without echoing; a wall and a closed door block the echo; everyone caught is imaged
  and deafened; it rushes the nearest imaged player; the wail stops at downed; it loses a player
  who gets away and goes quiet; a shove interrupts the wail; the cart smokes away after capture and
  after death.
- A nettest scenario: a client sees the charge, the fan, the deafen and the cart, and is imaged
  and hunted correctly.
- A saved database with a `discharged` entry loads as the Sonographer.
- The bot playtest still clears shifts (`playtest --god --seed=1..3`).
