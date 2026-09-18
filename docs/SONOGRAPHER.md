# The Sonographer (the Discharged, redesigned)

Brief for the orchestrator. Agreed with Zach on 2026-09-18 (theory session); rewritten the same
day when the ultrasound cart was dropped. The Discharged gets a new name, a new look and a new way
of hunting. It stays the game's ears monster: blind, and it finds you by sound.

## Who it is

**The Sonographer.** Ultrasound is echolocation, so this is the hospital's echolocation monster:
a doctor who went blind and learned to see with sound, and kept going. It's a **standalone model**,
with no cart or console.

What makes it unique, at a glance:

- **A neck that cranes as it gets suspicious.** Calm, its head sits low on a hunched neck. As
  suspicion builds, the neck stretches upward and the glowing windpipe rings pull apart. Fully
  stretched, it echoes, then the neck snaps back down. The suspicion meter is the body itself.
- **It clicks.** Soft, steady tongue clicks while it wanders, the way blind people really
  echolocate. The clicks speed up as it gets suspicious. It's the sound that tells you where it is.
- **Gel-slick skin.** Shiny and wet with ultrasound gel, with drips at the fingers and chin. It
  catches the flashlight like nothing else in the game.
- **An ultrasound probe grown into its right hand.** The wand is fused into the palm, and its cable
  runs up the arm, under the skin in places, into the side of the neck. The echo fires from the
  probe.
- **Old, tattered doctor's clothes.**

## The look (stylized kit, `art/stylized/`)

Follows DESIGN.md › Art style (one kit, separable parts, posture first, grime in the paint).

- **Height:** about 2.1 m with the neck at rest, up to about 2.7 m fully craned.
- **Posture:** tall and thin, shoulders rounded, head cocked to one side as if listening. Calm,
  the neck is hunched down; the stretch is the tell. Nothing else in the game stands like it.
- **Face:** no eyes. Flat, smooth, slightly shiny scar tissue where the eyes were, with a faint
  seam where the lids used to be. No eye objects in the sockets. A wide mouth that can drop open.
- **Ears:** on the large side of normal, swivelling toward sounds (keep `MonsterModel.set_ears`).
- **The throat:** see-through skin down the front of the neck, over a glowing violet windpipe with
  ribbed rings. It glows faintly when calm, brighter as suspicion builds, and full while charging.
  **Nothing may cover the throat**: open collar, tie pulled loose. (The ability icon is this
  windpipe, `art/icons/echolocation.svg`; match it.)
- **Skin:** grey-pink, with a wet gel sheen over everything and clear gel drips hanging from the
  fingers and chin. A separate glossy material, so the flashlight catches it.
- **The probe hand (right):** a chunky ultrasound wand fused into the palm, the fingers grown half
  around it. Its cable runs up the forearm (under the skin at the wrist and elbow, showing as a
  ridge), over the shoulder and into the side of the neck. The cable carries the charge glow.
- **The free hand (left):** long fingers, spread, feeling the air ahead as it walks.
- **Clothes:** an old doctor's white coat, long, yellowed, stained with gel, torn at one shoulder,
  its hem in chunky tatters. Under it, a stained shirt with a loosened tie and old trousers,
  frayed at the cuffs. Stiff, chunky clothing with thick hems; tears and stains mostly in the
  paint. Scuffed shoes.
- **The neck rig:** extra neck bones beyond the shared skeleton so the neck can stretch about
  0.6 m. The windpipe rings spread apart as it stretches (a shape key or bone-driven). This is the
  one place it departs from the shared skeleton; keep it contained to the neck.
- Reviewed from front, side and face renders, then in the game's lighting (`tools/style_lab`), at
  rest and fully craned.

## Animations

| Clip | What it does |
|---|---|
| **Idle** | Stands with the neck low, head cocked. The free hand's fingers twitch. A click every second or so (the jaw ticks with it). Ears drift. |
| **Wander** | A careful, high-stepping walk, placing each foot. Free hand out in front feeling the air. Probe arm hanging, the probe swaying. Clicks steady. |
| **Listen** | Freezes mid-step. Ears snap toward the sound, the head turns to it. Clicks stop for a beat, then come faster. |
| **Crane** (procedural, not a clip) | The neck's stretch is driven by suspicion, 0 to 1: it rises smoothly as suspicion builds and sinks as it drains. The windpipe rings spread and glow brighter with it. Blends on top of every other clip. |
| **Charge** (about 1.2 s) | At full stretch: the head tips up, the jaw drops, and the probe arm rises to point where it heard the noise. The glow runs from the throat, down the cable along the arm, into the probe. The clicks rise into a whine. |
| **Echo** | A pulse through the whole body, a jolt back, and the fan fires out of the probe. The neck snaps back down over about 0.5 s. |
| **Rush** | Neck low and forward, head leading, both arms out, a fast loping stride. The clicks become a continuous rattling shriek. |
| **Wail** | A flurry: clubbing with the probe arm and clawing with the free hand. **Between bursts it stops and cocks its head to listen**; that pause is when you can slip away. |
| **Search** | Target lost: stands still, the neck slowly rising, the head sweeping side to side. |
| **Stagger** (shoved) | Reels back, ears pinned flat, neck recoiling down. |
| **Sedated / lying** | Collapses; the lying pose for the table and dragging has the neck at rest length and the probe hand at its side. |

## How it hunts

1. **Suspicion.** Quiet noises fill a suspicion meter, scaled by loudness and distance. It fills
   easily and drains slowly. The game already rates its noises (CONTRACTS › Monsters: walk 0.25,
   pickups 0.15, containers 0.5, and so on). **The meter drives the neck,** so players read it by
   looking at it.
2. **Loud noises skip the echo.** Anything around 0.8 or louder (sprinting, breaking glass, the
   saw, a slammed door) sends it straight to the spot.
3. **Suspicious:** it stops, its ears snap toward the noise, the neck rises and the throat glows.
4. **Echo, when the meter is full.** The charge (about 1.2 s), then an echo fires from the probe
   toward where the noise came from. The echo empties the meter.
5. **The echo is a wedge,** like a bat's beam or an ultrasound fan: about 60° and about 14 m to start
   with. **On deeper wings and later shifts it sweeps**, the probe arm turning through an arc while
   it pings, so the fan covers a whole room. You can see it clearly: a translucent fan of grainy
   scan lines sweeping out fast, but slow enough to read, leaving a grainy afterimage on the
   surfaces it swept. **Walls and closed doors block it.**
6. **Caught in the echo = seen.** Every player the echo catches is **imaged**: a flash of
   ultrasound grain over their screen, and **deafened** by a short squeal (below). It only knows
   where each of them was at that moment.
7. **The rush:** it rushes to where it imaged the **nearest** player. If that player has crept
   away, it arrives, stops and listens again.
8. **Contact: it wails on them** until that player is **downed** or gets far enough away that it
   loses them. While it's on someone, it follows them by sound, so sprinting keeps it on you. The
   way out is to break away during a listening pause, get distance, then go quiet: a few seconds
   without hearing you and it drops back to searching (and usually echoes again).
9. **Once the player is downed,** it stops and goes back to hunting. It doesn't finish them off.

### The deafen squeal

Everyone the echo catches hears a squeal and goes briefly deaf. **It must never hurt a real
player's ears:** capped volume, about 1–1.5 s, soft ramps in and out, not piercing. Underneath it
the game's audio is muffled (a low-pass on the bus) and comes back over the same time.

### Escaping it

- **Freeze or crouch:** crouched footsteps are already silent.
- **Watch the neck:** a rising neck means it's close to echoing.
- **Break the fan:** step sideways during the charge, get behind a wall, or shut a door (gently;
  a slam is loud).
- **Decoys:** anything thrown makes noise where it lands, and pulls it there.
- **The wail's listening pauses:** never a lock you can't get out of.
- **Shove it:** the shove still stuns it (2 s). A teammate shoving it off you is the co-op save.

## Sounds

All generated with `tools/gen_audio.mjs`, numbered variants for anything repeated:

- **Clicks:** dry tongue clicks, several variants; the rate follows suspicion. The main "where is
  it" sound, positional.
- **Footsteps:** a soft, wet squelch (the gel).
- **Charge:** clicks rising into a whine.
- **Echo:** a deep sonar ping with a hiss of scan noise.
- **The deafen squeal:** see above.
- **Rush:** a continuous rattling shriek.
- **Wail:** grunts and wet blows.

## Calls the theory session made (not yet approved by Zach)

- **The neck is the suspicion display.** There's no suspicion meter on the scan ring or anywhere
  on the HUD.
- **The squeal has a settings toggle** to soften it further.
- **The fan comes out of the probe,** aimed by the arm, and the charge glow runs throat → cable →
  probe.
- **In low places the neck bends instead of stretching:** it never pushes the head through a
  ceiling or a door frame (a check upward; under a low ceiling it cranes forward instead of up).
- The starting numbers above (60°, 14 m, 1.2 s charge, 0.6 m of neck) are for tuning in the review,
  not locked.

## Capture and death

- Capture works as it does for the Discharged (shove, jab, drag, strap).
- Sedated or dead, the neck settles to rest length and the throat glow fades out.
- The lying pose on the table and while dragged: neck at rest, probe hand at its side.

## The rename

**The Discharged becomes the Sonographer everywhere:** the monster's kind id, display name,
database entry, tips, sound cue names, the roster, tests and nettest scenarios, DESIGN.md and
docs/CONTRACTS.md. The host's database is saved to disk and keyed by monster kind: map the old
`discharged` key to the new one when loading, so nobody loses what they've learned.

**The Sonographer has no brain to harvest any more.** The player's Echo ability comes from
grafting the **Sonographer's trachea** instead (docs/GRAFTING_TRACHEA.md), which also removes the
brains and the blender. This brief doesn't build that; it only needs the monster renamed and the
throat modelled so the trachea brief can use it. Echo turning into the ping is still later
(docs/backlog/SWEEP4B.md).

## Chunks

| # | Branch | What | Who |
|---|---|---|---|
| A | `sono-model` | The model: the body, the stretching neck rig, the throat, the probe hand and cable, the gel material, the tattered coat, the face. All the clips in the table above. The crane as a 0–1 blend. | Orchestrator's call; Blender-from-Python work, like the Hive and the Night Nurse |
| B | `sono-brain` | The rename, suspicion, the echo (charge, wedge, sweep, blocking, imaging), the deafen squeal, the rush, the wail with its pauses and losing you, the low-ceiling check, sounds, networking. | Opus, high |

A and B can run at the same time. B builds on the current Discharged model with stand-ins (a
glowing throat marker, a head that rises) behind a small look interface. A implements the same
interface on the new model; whichever merges second hooks them up. The interface:

- `suspicion` 0–1: drives the neck stretch and throat glow.
- `charge` 0–1: drives the charge pose and the glow running down the cable to the probe.
- `mode`: which clip family is playing (the existing Mode enum).
- `aim`: the direction the probe points during the charge and echo.
- `crane_limit` 0–1: how far the neck may stretch up before it bends forward (the ceiling check).

**Timing with grafting:** B touches brains, abilities and the database, as grafting does. Start B
after grafting's chunk C is merged. A can start any time.

**Zach sees:**
- A: `SONOGRAPHER: the model, the neck crane, and the charge` (in a lab scene; `monster_lab` has
  close-up shots).
- B: `SONOGRAPHER: make a noise, watch its neck, get pinged, and get away`.

## Done when

- Headless (`tools/monster_lab.tscn`): quiet noises fill suspicion and a full meter echoes; a loud
  noise rushes without echoing; a wall and a closed door block the echo; everyone caught is imaged
  and deafened; it rushes the nearest imaged player; the wail stops at downed; it loses a player
  who gets away and goes quiet; a shove interrupts the wail; under a low ceiling the neck never
  goes through it.
- A nettest scenario: a client sees the neck, the charge, the fan and the deafen, and is imaged
  and hunted correctly.
- A saved database with a `discharged` entry loads as the Sonographer.
- The bot playtest still clears shifts (`playtest --god --seed=1..3`).
