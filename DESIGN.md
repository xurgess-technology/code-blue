# Malpractice (working title) — Design

Last updated 2026-09-17 (Sweep 4A: the ability bar, the database terminal, the fog lot, the pharmacy and crematorium, placebo pills, no gold bars). Items marked **TODO** are wanted but not built yet. Items marked **IDEA** are proposals waiting for a yes.

## Vision

You and your best friends clock into the ER with one goal: save a life. The problem is that the patient is a man who got shot or a seal with a rotting flipper, and the hospital is full of monsters.

**Tone**: chaos and laughing, until it isn't. The signature moment: something creeping toward the OR while two surgeons scramble to finish the procedure, somebody is supposed to be watching the door, and nobody is.

**Genre references**: R.E.P.O. for look and physicality, Lethal Company and Content Warning for the friend-group loop.

**Rating**: bloody, not grim.

## Names (picked 2026-09-17)

- **The game is Malpractice** — the joke is that you are terrible at this. Working title: a Steam game already carries that exact name, so this gets revisited before any public release (**Gross Malpractice** is the fallback, and it was clear on Steam and itch.io).
- **The hospital is St. Doe's General Hospital**, shortened to **Doe General** on faxes and signage. "Code blue" survives in-world as the hospital's own alarm code.
- Dropped: Skeleton Crew, Code Blue, Graveyard Shift, Bedside Manor, Do No Harm, On Call, Stat!

## Players

- Up to 4 players, built so more is possible. Solo works.
- Everyone is a surgeon, first person, with your own hands visible.
- One player hosts over ENet; friends join by address (LAN, port forward or Tailscale). **TODO**: Steam lobbies and invites via GodotSteam.
- **0 HP means downed**, not dead: you lie on the floor, crawl, and bleed out over five minutes. A teammate carries you to the OR's player table and stitches you up with a suture kit. Bleed out and you are dead until the next shift (spectating). Everyone down or dead fails the shift.
- **Friendly fire is a feature**: Q shoves whatever is in front of you. A shoved teammate drops everything, and the vials smash.
- **Controls**: crouch (Ctrl, silent footsteps, no low-ceiling stand-up), a small grounded jump (Space), hold R to scan a monster in view (range and line of sight, a progress ring at the crosshair; built in, not an item or a slot). All rebindable in Settings.
- **Ability bar**: up to 4 abilities, one per slot, in the order you first earn them. Hold Alt to bring the bar up (icons slide in from a small always-visible row); Alt+1-4 fires that slot. Each slot has its own cooldown, level pips, a cost tag (like "LOUD" on Echo) and greys out with a reason when it can't fire. A card introduces a new ability the first time it lands in a slot.
- **TODO**: proximity voice chat (and monsters that hear it), roles and classes, cosmetics, progression.

## The shift

1. Everyone spawns in the clock-in room next to the OR. Aim at the time clock and hold E.
2. One patient with one ailment arrives. Vitals drain the whole shift.
3. Search the hospital for the supplies the procedure needs and put them on the OR supply shelf.
4. Operate step by step. Each step is its own minigame.
5. Stabilise the patient to punch out. The next shift is harder, with more monsters, and its wings are new: while the team is out in the parking lot the gates stay locked and the wings behind them are rebuilt; the entrance building never changes during a run.
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

Holding E at the table (with the step's supply on the shelf or in your own hands) moves your camera over the site and frees the mouse; the tool follows your cursor across a work plane lying on the patient. Teammates see your tool move. Mistakes cost vitals and nothing else.

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
- **Charged throw**: hold the drop key to charge a throw, release to fire it (a quick tap still just drops). Used to sell loot into the crematorium furnace and to throw placebo pills.
- **Placebo pills**: a $15 bottle of 10, sold only at the pharmacy, does nothing mechanically and burns for $0. Swallow one from the bottle, or throw one at a teammate (a warm, cozy screen effect and a line only they see) or at a patient/monster (the line floats above them in quotes for everyone nearby; an OR patient's monitor shows a hopeful green blip, vitals unchanged). A miss just leaves it on the floor as a pickup.
- **TODO**: the shopping cart, more item types (defibrillator, sedative dart, batteries, keys).

## The database terminal

A computer terminal in the break room, opened with E; full-screen, and you can't move while using it. It replaced the old guide binder entirely — no carryable version.

- Three sections: Monsters, Abilities, Items & Procedures.
- Monster entries unlock in tiers as you learn more about that species: **sighted** (name, silhouette), **scanned** (behaviour, senses, threat, sedative doses, an X-ray of where its brain sits), **harvested** (the brain's look, spoil time, the ability it grants, a level table). The Night Nurse has no brain, so her entry never reaches tier 3.
- Items and procedures are unlocked from the start, same as the old guide.
- The database belongs to the host, saved to disk, and survives a wipe; guests share the host's copy for the session but don't keep their own.

## The hospital

- One floor: the entrance building (break room with the time clock, phone and database terminal, the OR, lobby with the pharmacy window and crematorium) and three or four procedurally generated wings behind it, with an outdoor lot outside the main doors: empty asphalt and fog, nothing else. Thick fog rings the lot; walk into it and visibility and sound fall away within a few metres, and past a certain depth you're quietly turned back toward the lot before you ever touch anything. Player spawns and respawns are inside, in the lobby.
- **The ambulance** drives itself out of the fog for every patient delivery, parks at the bay, unloads along the gurney walk, and drives back into the fog once it's done; it stops and honks for anyone standing in its lane rather than hitting them.
- **The pharmacy** is a window behind a steel grate in the lobby: order with E, and a pneumatic tube thunks a capsule into a wall slot a moment later. Sells placebo pills for now.
- **The crematorium** is a small room off the lobby with a lit furnace. Selling loot means throwing it through the grate into the fire (a miss bounces off the frame); a burst of flame and the amount floating up confirms a sale. Bodies (downed, dead, carried) bounce off the grate like a miss and can never go in. No gold bars, no dumpster, no shop van any more.
- **Loading gates.** The entrance building and the neutral area stay the same for the whole run. The wings are regenerated for every shift from that shift's seed: from clock-out until clock-in the wing gates are shut and locked (red lamps, a dead-bolt clunk), the wings behind them are torn down and a new layout with fresh supplies, loot and monsters is built, and the gates unlock and swing open when the next shift starts. Anyone still inside a wing at the end of a shift is walked out to the entrance hall; what was left lying in a wing is gone. The build never hitches: the layout and the meshes are worked out on a background thread and put into the world a few pieces a frame; clocking in waits for it (the lamps blink amber).
- **Doors.** Sliding glass doors at the main entrance; heavy automatic double doors with small windows at each wing gate and the OR, which open for anyone close (players, paramedics with the gurney, someone dragging a monster or carrying a player, and monsters); a deep wing's gate now and then stutters and sticks half open for a few seconds. Every other room has hinged doors (double doors on the cafeteria, radiology and the morgue): E opens or closes them, they swing away from you and stay where you leave them. Opening a door makes a small noise, a slam a big one; closed doors block sight and the flashlight and muffle sound. The Hive pushes doors open slowly, the Discharged bursts through when it is chasing, the Night Nurse opens them silently while nobody is looking, so a door you shut can be open later. No locked doors yet.
- Room kinds include wards, storage, offices, pharmacy, maintenance and nurse stations; containers are placed by room kind.
- Dim and half-dead lighting: most ceiling fixtures flicker or are out; your flashlight does the rest.
- **TODO**: power and fuse boxes, hiding spots, multiple floors, locked doors and keys.

## Monsters

Each monster runs on one sense, so players learn them in order: eyes, then ears, then being watched.

| Monster | Sense | Rule |
| --- | --- | --- |
| **The Hive** | Eyes | A shambling patient, common near the start of every wing. Sees you and lumbers slowly after you; break line of sight and it loses interest within a few seconds. Deaf. Weak: the easy fight that teaches the saw and the capture loop. Has a brain. Hives share a hive mind (that is why they forget you so fast). |
| **The Discharged** | Ears | Eyeless and a head taller than a surgeon, with clear ears on the large side of normal that swivel toward sounds. Drags a rattling IV pole. Hunts by sound: the rattle stops, the ears turn, then it rushes the noise. A shove stuns it. Has a brain. |
| **The Night Nurse** | Being watched | Moves only while nobody is looking at it with light on it. A shove does nothing, and neither do the saw or the needle: she is the one you run from. No brain. |

Surgery is the worst case: the monitors and the bone saw call the Discharged, and every surgeon's eyes are on the table instead of the door.

## Fighting and capturing monsters (sweep 3)

The core choice in every fight: **kill it to be safe, or catch it to get paid.**

- **Kill:** the bone saw is a weapon (left mouse while holding it). Hits stagger, a few hits kill. Every hit has a chance to snap the saw, which is also the saw the surgery needs. Swinging is loud. A killed monster pays nothing: organs are only worth anything harvested alive.
- **Catch:** shove it (stunned), then jab it with anesthetic (left mouse while holding a vial) inside the stun window. It drops, sedated, for a while. Hold E to drag it, E on a free patient table to strap it down. Strapped monsters cannot hurt anyone.
- **On the table:** sedation wears off, faster with noise (the saw is the loudest). Low sedation makes it stir (the operator's hand shakes); lower still it is awake and thrashing, which botches the work and damages the brain. Anyone can re-dose it with anesthetic from their hands (E at the table), but every dose works for less time than the last.
- **Dissection:** saw open the skull, pull the brain out with the forceps. Botches cost brain condition instead of patient vitals. The finished monster dies on the table.
- **Brains spoil.** A harvested brain loses value quickly: run it to the crematorium (thrown into the furnace, the only sell point now) or to the break-room blender.
- **The blender:** blend a brain and drink it to absorb that monster's knowledge. Per player, and lost on a game over along with the money. The ability it grants lands in the next empty slot of your 4-slot ability bar; its level still comes from these same points.
  - Hive brains, **Hive Eyes**: fire from its slot to see through a nearby Hive's eyes for a few seconds. Your camera flies there along the navmesh first (about 1-1.5s), then settles into its eyes; your own body stands with glazed eyes teammates can see. A hit snaps you back instantly instead of flying back. More brains: longer range and time, and at level 2+ you can cycle between Hives in range instead of only the nearest. (Later: Puppet, steering it.)
  - Discharged brains, **Echo**: fire from its slot for a loud shriek, visibly coming from you (a pulse ring, a body lean) on every machine; for a few seconds everything nearby shows as outlines through walls. It is loud enough to bring every Discharged in the wing. More brains: bigger radius and longer.
- Later sweeps: Puppet, Rise (get back up as a shambler when downed), visible side effects (pale skin, groans, bigger ears, loud noises hurt), rare strap breaks.

Shift 1 has Hives and one Discharged; the Night Nurse joins from shift 2; more of each on later shifts and with more players.

## Look and sound

- R.E.P.O.-adjacent: chunky low-poly, harsh pools of light, volumetric haze, a sickly teal grade with warm flashlight light. Film grain, vignette and damage effects.
- Generated soundtrack in three phase-locked layers (dread, hunt, critical) plus positional sound effects, all synthesized offline into WAVs.

## Technical shape

- Godot 4.7, GDScript. `docs/CONTRACTS.md` describes how the systems fit together.
- Host-authoritative simulation; each player owns their own movement and aim; 20 Hz snapshots; surgery minigames are run by the operator's machine and reported to the host.
- Everything is testable headlessly: `tools/playtest.tscn` plays full shifts, `tools/nettest.tscn` runs a real host and client, `tools/minigame_lab.tscn` runs any minigame with scripted input.

## Open questions

- Which name?
- Should the database terminal's "where to look" get less reliable on later shifts (entries going missing)?
- Should the Night Nurse drag a player away instead of hitting them?
