# Code Blue (working title) — Design

Last updated 2026-09-12. Items marked **TODO** are wanted but not built yet. Items marked **IDEA** are proposals waiting for a yes.

## Vision

You and your best friends clock into the ER with one goal: save a life. The problem is that the patient is a man who got shot or a seal with a rotting flipper, and the hospital is full of monsters.

**Tone**: chaos and laughing, until it isn't. The signature moment: something creeping toward the OR while two surgeons scramble to finish the procedure, somebody is supposed to be watching the door, and nobody is.

**Genre references**: R.E.P.O. for look and physicality, Lethal Company and Content Warning for the friend-group loop.

**Rating**: bloody, not grim.

## Names (undecided)

- **Malpractice** — the joke is that you are terrible at this. Fits the friendly-fire chaos best. *(recommended)*
- **Skeleton Crew** — night-shift staffing pun plus horror. *(runner-up)*
- **Code Blue**, **Graveyard Shift**, **Bedside Manor**, **Do No Harm**, **On Call**, **Stat!**

## Players

- Up to 4 players, built so more is possible. Solo works.
- Everyone is a surgeon, first person, with your own hands visible.
- One player hosts over ENet; friends join by address (LAN, port forward or Tailscale). **TODO**: Steam lobbies and invites via GodotSteam.
- **0 HP means downed**, not dead: you lie on the floor, crawl, and bleed out over five minutes. A teammate carries you to the OR's player table and stitches you up with a suture kit. Bleed out and you are dead until the next shift (spectating). Everyone down or dead fails the shift.
- **Friendly fire is a feature**: Q shoves whatever is in front of you. A shoved teammate drops everything, and the vials smash.
- **TODO**: proximity voice chat (and monsters that hear it), roles and classes, cosmetics, progression.

## The shift

1. Everyone spawns in the clock-in room next to the OR. Aim at the time clock and hold E.
2. One patient with one ailment arrives. Vitals drain the whole shift.
3. Search the hospital for the supplies the procedure needs and put them on the OR supply shelf.
4. Operate step by step. Each step is its own minigame.
5. Stabilise the patient to punch out. The next shift is a new hospital, harder, with more monsters.
6. Lose if the patient flatlines or everyone is dead.

Run length 10 to 20 minutes. Difficulty rises with the shift number: tighter minigame tolerances, faster vitals drain, more monsters.

## Patients and ailments

| Patient | Notes |
| --- | --- |
| **Bob** | An ordinary 52-year-old man. |
| **The seal** | A harbor seal. Heavier, so it needs more anesthetic, and its flipper takes more sawing. |

| Ailment | Steps |
| --- | --- |
| **Gunshot wound (GW)** | 1. Sedate (anesthetic). 2. Remove the bullet (forceps). 3. Pack and dress the wound (gauze x1). |
| **Amputation (AM)** | 1. Sedate (anesthetic). 2. Apply the tourniquet. 3. Saw through the infected arm or flipper (bone saw). 4. Dress the stump (gauze x2). |

Ailments refer to named sites (`injection`, `gunshot`, `limb`, `limb_cut`) and each patient body provides a marker for each, so a new patient only needs its markers placed.

## Surgery minigames

Holding E at the table (with the step's supply on the shelf) moves your camera over the site and frees the mouse; the tool follows your cursor across a work plane lying on the patient. Teammates see your tool move. Mistakes cost vitals and nothing else.

- **Anesthetic**: draw the plunger to the dose band for this patient's weight, then hold the needle steady on the vein. Underdosing makes the patient stir and jolt your hands in later steps; overdosing costs vitals.
- **Forceps**: steer down a winding wound channel to the bullet, grip it, and draw it back out without touching the sides. Dark deep in the wound: a teammate's flashlight helps.
- **Tourniquet**: slide it above the infection line and cinch it, then crank the windlass into the right pressure and lock it. A weak tourniquet makes the saw step bloody.
- **Bone saw**: long, steady strokes on tempo along the cut line, fast through skin, slow through bone.
- **Gauze**: pack the gunshot wound and wrap it, or wrap the stump, keeping the tension even.

**TODO**: two-person steps (one holds, one cuts).

## Items

All items are physical 3D objects: on shelves, in containers, in hands, on the OR shelf.

| Item | Used in | Consumable | Found |
| --- | --- | --- | --- |
| Anesthetic | GW, AM | yes, batches of 2 to 3, fragile | medicine fridges (pharmacy, storage); sometimes loose |
| Gauze | GW, AM | yes, rolls of 2 to 4 | nurse-station drawers; often loose on counters, trays, gurneys |
| Forceps | GW | no | steel drawer units (storage, maintenance); sometimes on a tray |
| Tourniquet | AM | no | red trauma bags (corridors, nurse stations); sometimes dropped |
| Bone saw | AM | no | pegboards (maintenance, storage); sometimes leaning on a gurney |

- **Aim and press E** for everything: take items, open and close containers, put supplies on the shelf, clock in, revive, operate.
- **Two hands.** A batch fills one hand; picking up more of the same consumable merges into it. 1, 2 or the mouse wheel switch hands; G sets the selected stack down gently.
- **Getting hit or shoved** drops both hands; fragile stacks lose about a third, never all of it.
- Containers stay open once opened (so the team can see what has been searched); E closes them again.
- Items the current ailment does not need also spawn, so the pool feels real.
- **Softlock guard**: if breakage leaves the shift unwinnable, fresh supply quietly appears somewhere far away.
- **TODO**: the shopping cart, throwing, more item types (defibrillator, sedative dart, batteries, keys).

## The medical guide

A battered reference binder on a lectern in the clock-in room. It is a physical item: take it with you (it uses a hand), drop it, lose it. Press R while holding it or looking at it to read.

- An index of tabs, one per item, plus procedure checklists and a shopping list per ailment.
- Each item page shows the item model turning, its real-world use, where to look, which steps use it, and how to handle it.
- Locked, torn-out tabs hint at items still to come.

## The hospital

- Procedurally generated from a shared seed every shift. The OR is always in the middle with its anterooms and the clock-in room attached.
- Room kinds include wards, storage, offices, pharmacy, maintenance and nurse stations; containers are placed by room kind.
- Dim and half-dead lighting: most ceiling fixtures flicker or are out; your flashlight does the rest.
- **TODO**: doors that open and close, power and fuse boxes, hiding spots, multiple floors.

## Monsters

Each monster runs on one sense, so players learn them in order: eyes, then ears, then being watched.

| Monster | Sense | Rule |
| --- | --- | --- |
| **The Walk-In** | Eyes | A shambling patient, common near the start of every wing. Sees you and lumbers slowly after you; break line of sight and it loses interest within a few seconds. Deaf. Weak: the easy fight that teaches the saw and the capture loop. Has a brain. Walk-Ins share a hive mind (that is why they forget you so fast). |
| **The Discharged** | Ears | Eyeless and a head taller than a surgeon, with clear ears on the large side of normal that swivel toward sounds. Drags a rattling IV pole. Hunts by sound: the rattle stops, the ears turn, then it rushes the noise. A shove stuns it. Has a brain. |
| **The Night Nurse** | Being watched | Moves only while nobody is looking at it with light on it. A shove does nothing, and neither do the saw or the needle: she is the one you run from. No brain. |

Surgery is the worst case: the monitors and the bone saw call the Discharged, and every surgeon's eyes are on the table instead of the door.

## Fighting and capturing monsters (sweep 3)

The core choice in every fight: **kill it to be safe, or catch it to get paid.**

- **Kill:** the bone saw is a weapon (left mouse while holding it). Hits stagger, a few hits kill. Every hit has a chance to snap the saw, which is also the saw the surgery needs. Swinging is loud. A killed monster pays nothing: organs are only worth anything harvested alive.
- **Catch:** shove it (stunned), then jab it with anesthetic (left mouse while holding a vial) inside the stun window. It drops, sedated, for a while. Hold E to drag it, E on a free patient table to strap it down. Strapped monsters cannot hurt anyone.
- **On the table:** sedation wears off, faster with noise (the saw is the loudest). Low sedation makes it stir (the operator's hand shakes); lower still it is awake and thrashing, which botches the work and damages the brain. Anyone can re-dose it with anesthetic from their hands (E at the table), but every dose works for less time than the last.
- **Dissection:** saw open the skull, pull the brain out with the forceps. Botches cost brain condition instead of patient vitals. The finished monster dies on the table.
- **Brains spoil.** A harvested brain loses value quickly: run it to the dumpster (the only sell point) or to the break-room blender.
- **The blender:** blend a brain and drink it to absorb that monster's knowledge. Per player, and lost on a game over along with the money.
  - Walk-In brains, **Hive Eyes** (R): see through a nearby Walk-In's eyes for a few seconds while your body stands helpless. More brains: longer range and time. (Later: Puppet, steering it.)
  - Discharged brains, **Echo** (R): a loud shriek; for a few seconds everything nearby shows as outlines through walls. It is loud enough to bring every Discharged in the wing. More brains: bigger radius and longer.
- Later sweeps: Puppet, Rise (get back up as a shambler when downed), visible side effects (pale skin, groans, bigger ears, loud noises hurt), rare strap breaks.

Shift 1 has Walk-Ins and one Discharged; the Night Nurse joins from shift 2; more of each on later shifts and with more players.

## Look and sound

- R.E.P.O.-adjacent: chunky low-poly, harsh pools of light, volumetric haze, a sickly teal grade with warm flashlight light. Film grain, vignette and damage effects.
- Generated soundtrack in three phase-locked layers (dread, hunt, critical) plus positional sound effects, all synthesized offline into WAVs.

## Technical shape

- Godot 4.7, GDScript. `docs/CONTRACTS.md` describes how the systems fit together.
- Host-authoritative simulation; each player owns their own movement and aim; 20 Hz snapshots; surgery minigames are run by the operator's machine and reported to the host.
- Everything is testable headlessly: `tools/playtest.tscn` plays full shifts, `tools/nettest.tscn` runs a real host and client, `tools/minigame_lab.tscn` runs any minigame with scripted input.

## Open questions

- Which name?
- Should the guide's "where to look" get less reliable on later shifts (pages going missing)?
- Should the Night Nurse drag a player away instead of hitting them?
