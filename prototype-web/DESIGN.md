# Code Blue (working title) — Design

Last updated 2026-09-12 from Zach's design interview. Items marked **TODO** are wanted but not built yet. Items marked **IDEA** are proposals waiting for a yes.

## Vision

You and your best friends clock into the ER with one goal: save a life. The problem is that the patient is an elephant, or a werewolf, or a man who ate a stop sign, and the hospital is full of monsters.

**Tone**: chaos and laughing, until it isn't. The signature moment: a slow, inevitable monster lumbering toward the OR while two surgeons scramble to finish the procedure, two more try to hold the door, and one gets locked out and screams over voice chat to go on without him.

**Genre references**: R.E.P.O. for look and physicality, Lethal Company and Content Warning for the friend-group loop.

**Rating**: bloody, not grim. Cartoon violence with real blood.

## Names (pick one)

- **Malpractice** — the joke is that you are terrible at this and people die. Fits the friendly-fire chaos best.
- **Skeleton Crew** — night-shift staffing pun plus horror. Clean, memorable.
- **Code Blue** — the working title. Reads as a real hospital term, less funny.
- **Graveyard Shift** — obvious, already used by other games.
- **Bedside Manor** — supernatural hospital pun. Charming, maybe too cute.
- **Do No Harm** — dry, ironic.
- **On Call** — short, plain.
- **Stat!** — energetic, hard to search for.

Recommendation: Malpractice, with Skeleton Crew as the runner-up.

## Players

- Up to 4 players, designed so more is possible later. Solo play works (you are just a very lonely surgeon).
- Everyone is a surgeon. You see your own hands and flashlight.
- One player hosts. Friends join by address (LAN, port forward, or Tailscale). Steam lobbies and invites replace this later.
- **Dead players spectate** their teammates until revived.
- **Revival**: the Re-Gen Pod in the clock-in room. A living surgeon holds E at the pod for five seconds to bring back the teammate who has been dead the longest, at two hearts. **IDEA for later**: you must first recover the dead friend's heart or brain and feed it to the pod.
- **Friendly fire is a feature**: Q shoves whatever is in front of you. Shoving a teammate knocks them back and makes them drop their tools. Nothing stops you doing this at the worst possible moment.
- **TODO**: proximity voice chat, and monsters that hear it.
- **TODO (stretch)**: roles or classes with different gear and leveling.
- **TODO**: cosmetics and character customization.

## The shift

1. Everyone spawns in the **clock-in room**, which is always attached to the OR. It is safe until someone punches in.
2. Any surgeon holds E at the **time clock** to start the shift. The patient arrives on the table, the required tools are scattered through the hospital, and the monsters wake up.
3. **The patient is always dying.** Vitals drain from 100 toward 0 for the whole shift. Completing a surgery step buys back some vitals. Sloppy surgery costs vitals.
4. Find the tools, bring them to the OR, and perform the procedure step by step.
5. Save the patient and **punch out**. Win screen, then the next shift starts in a freshly generated hospital with a harder patient and more monsters.
6. Lose if the patient flatlines or everyone is dead. The shift resets and you try again.

- Target run length: 10 to 20 minutes.
- **Difficulty scales with the shift number**: patients need more steps, the steady-hand zone gets narrower, vitals drain faster, more monsters spawn. No quota. Surgeons make surgeon salary.
- **TODO**: progression between runs (money, upgrades, unlocks). Undecided.

## The hospital

- **Procedurally generated every shift** from a seed shared by all players.
- The OR is always in the middle with two anterooms, and the clock-in room is always attached to it. An inner corridor ring surrounds that block, an outer ring hugs the map edge, four spokes connect them, and rooms line every corridor.
- Boilerplate hospital for now: wards with beds, storage rooms with cabinets, offices, empty rooms. Themed areas (morgue, psych ward, maternity, boiler room) come later.
- **Supernatural**: the whole building is vaguely magical. Monsters, cloning pods, ghosts as patients. Nothing needs to make sense.
- **Lighting**: partially lit. Ceiling fixtures that flicker, some dead, some steady, plus your flashlight. Dark corners everywhere.
- **TODO**: locked doors, keycards, fuse boxes and cuttable power, hiding spots, closable and barricadable doors, multiple floors, elevators.

## Patients and surgery

Patients are randomized from a small list. Each has a procedure: an ordered list of steps, each needing a specific tool. Only the tools the patient needs spawn, so early shifts are three or four tools, not seven.

| Patient | Procedure |
| --- | --- |
| Gary Pruitt, 44, ate a stop sign | Retractor to open, Forceps to extract the sign, Sutures to close |
| Unregistered werewolf, silver bullet in the shoulder | Anesthetic before the moon, Scalpel, Forceps for the bullet, Sutures for the fur |
| Bartholomew the elephant, swallowed a tricycle | Anesthetic, Bone Saw through the hide, Clamp, Retractor to retrieve the tricycle |
| Patient 0, a ghost with a ruptured appendix | Clamp to pin it down, Scalpel on the count of three, Sutures to close whatever that was |

**Operating** is a steady-hand minigame. Hold E at the table with the step's tool delivered. A marker sways across a bar. Progress only accrues while the marker is in the green zone. Holding E while it is outside the zone is a complication: no progress and the vitals drop. Several surgeons can operate at once and progress adds up, with diminishing returns. The zone narrows and the marker speeds up on later shifts.

**IDEA**: per-patient twists (the werewolf wakes up if the anesthetic wears off, the ghost phases the tool off the tray, the elephant's vitals are huge but drain fast).

## Items and carrying

- Two hands. Walk over a tray to pick up a tool. Walk into the OR to drop it on the instrument tray.
- G drops what you are carrying in front of you so a teammate can take it.
- **TODO**: a real shopping cart you push, with physics, that holds everything. Throwing tools to each other. More item types (batteries, walkie-talkies, defibrillator, sedatives, medkits, keys).
- Physics-based bodies and items are the goal. The current version is grounded and grid-based; the physics layer comes when the cart does.

## Monsters

Fewer than the prototype had. Each one is a rule you can learn.

| Monster | Rule |
| --- | --- |
| **The Nurse** | Hunts by sight. Sees you from far away if your flashlight is on, only close up if it is off. Sprinting nearby gives you away. Runs when it can see you, prowls when it cannot, gives up after a few seconds. Loses interest after it hits you. Can be shoved for a stun. |
| **The Lurker** | Low, six-legged, red eyes. Cannot move while any flashlight is on it, and is harmless while frozen. In the dark it creeps toward the nearest surgeon from anywhere nearby. Can be shoved for a stun. |
| **The Orderly** | Huge and slow. Never stops. Knows where you are if you are anywhere near it, and heads for the OR when someone is operating. Hits for two hearts. A shove only nudges it. The lumbering inevitability from the signature moment. |

- Monster count and mix scale with the shift number and the player count.
- Monsters can be stunned now (shove) and frozen (lurker). **TODO**: weapons and ways to kill them.
- **IDEAS for the roster**: a mimic that looks like a patient on a bed until you get close; something that only moves when nobody is looking at it; a thing that lives in the vents and drags people in; a "visitor" that follows you politely until you turn your back; a swarm that goes for whoever is carrying the most.

## Look and sound

- **Art**: R.E.P.O.-adjacent. Chunky low-poly, saturated materials, harsh lights, big readable silhouettes. Everything is procedural placeholder right now; a Blender friend can replace models one at a time.
- **First person**, own hands visible.
- **Soundtrack**: a generative creepy score. Sparse dissonant notes, swelling pads, distant metal, a pulse that rises when something is hunting you and hammers during surgery.

## Technical shape

- TypeScript, Three.js, canvas HUD, Vite. Desktop via Electron. No engine.
- **The simulation is 2D** (grid, collisions, line of sight, AI, surgery). The 3D scene is a view of it. This is what keeps the netcode small.
- **Netcode**: the host runs the world (monsters, tools, patient, hits). Each player owns their own movement and reports it. The host broadcasts snapshots at 20 Hz; clients smooth between them. Solo is just hosting with nobody connected.
- **Transport**: a tiny WebSocket relay. In the desktop app the host runs it automatically; friends connect to the host's address. Swapping in Steam peer-to-peer later is one adapter behind the same interface.
- **Steam**: Electron plus steamworks.js when the time comes. The store paperwork is the last thing.

## Roadmap

**Now**: procedural hospital, patients and step surgery, vitals, clock-in and punch-out loop, shove, revival pod, the Orderly, flickering lights, soundtrack, desktop app, host and join.

**Next**: voice chat, the shopping cart and physics carrying, throwing, more monsters, themed rooms, doors and power.

**Later**: roles and classes, progression, cosmetics, Steam lobbies and invites, achievements, store page.

## Open questions for Zach

- Which name?
- When a player dies with tools in hand, should the tools stay with the corpse (so the body is worth visiting) or scatter?
- Should the patient's blurb be read aloud in the OR by a text-to-speech triage voice? (Cheap and funny.)
- Should shifts get a modifier ("lights out", "two patients", "the Orderly is already awake") from shift 3 onward?
