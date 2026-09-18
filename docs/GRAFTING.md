# Grafting, part one: the Hive eye

Brief for the orchestrator. Agreed with Zach on 2026-09-18 (theory session). It replaces the old
Growths and grafting backlog, which is gone from `docs/backlog/SWEEP4B.md`. Don't build from any
older grafting notes.

## The goal

The first graft in the game, deliberately small. The team catches a Hive, takes one of its eyes
out on an OR table, keeps it in a specimen vat, then straps a surgeon down and swaps one of their
eyes for it. The grafted surgeon has one normal eye and one orange Hive eye, and gets **Hive Eyes**
from it. The surgeon's own eye goes into the vat and can be swapped back in or sold.

## The loop

1. **Catch a Hive** and strap it to an OR table (the existing shove, jab, drag and strap).
2. **Eyeball Extraction** on the Hive. The eye comes out in the operator's hand.
3. **Put the eye in a vat.** Vats are specimen jars on the lab wall. Outside a vat an eye spoils.
4. **A surgeon straps themselves** to the player table.
5. **Bring the vat** from the lab benches to the graft stand, a small spot right next to the
   player table. Afterwards it gets carried back to the benches.
6. **Another player runs Eyeball Grafting** on the strapped surgeon. Their eye goes into the vat
   and the Hive eye goes into their socket.
7. The surgeon now has **Hive Eyes, level 1**. The eye glows low normally and high while the
   ability is in use.
8. **Swapping back** is the same surgery with the surgeon's eye in the vat on the stand. They lose
   Hive Eyes, and the Hive eye goes back into the vat.

## Decisions (locked by Zach)

- **One eye, one level.** A graft gives Hive Eyes level 1. There's no second eye and no levelling;
  the level system is going to be redone from scratch.
- **The grafted surgeon is awake.** They lie strapped down in first person, looking up, and watch
  the tools come at their own eye. This is the moment the feature exists for, so the patient's
  camera matters: face up, a little freedom to look around, the operator and tools in view.
- **Eyes spoil outside a vat.** Reuse the brain spoil system: over a minute or two the eye clouds
  over and dulls. A vat stops the clock. A spoiled eye can't be grafted.
- **A graft is always a swap, never an empty socket.** You can only operate when the vat on the
  graft stand holds the eye that goes in. The eye that comes out goes into that vat.
- **No botching on grafts** for now. The graft minigames play, but mistakes cost nothing and the
  steps can't fail.
- **Two new tools: a scalpel and an eye spoon.** Both are ordinary non-consumable items, like
  the forceps.
- **Another player has to operate.** You can't graft yourself, and there's no solo robot yet.
  For testing alone, the dev panel lets you take control of Dr. Botsworth (below).
- **Eyes are labelled with their owner.** A surgeon's eye is "Zach's eye" on the vat label and
  in the hand. A Hive eye is "Hive eye".
- **A first-person tell:** a grafted surgeon sees a faint orange tint or vignette on the left edge
  of their view (the side of the grafted eye), stronger while Hive Eyes is active.
- **Eyes can be sold** by throwing them into the crematorium furnace, like any loot.

## Calls the theory session made (approved by Zach)

- **Graft steps (on a surgeon):** 1. Scalpel: cut around the socket. 2. Eye spoon: scoop the old
  eye out (it drops into the vat and the vat's eye comes up onto the stand). 3. Eye spoon: seat the
  new eye. 4. Suture kit: stitch it in (the `surgeon_graft` art already shows stitches). No
  anesthetic: the surgeon is simply awake, which is the joke.
- **Extraction steps (on a Hive):** 1. Scalpel: cut around the eye. 2. Eye spoon: scoop it out.
  3. Scalpel: snip the optic nerve. The usual monster-table rules apply: sedation wears off,
  stirring shakes the operator's hand, and botches damage the eye the way they damage a brain
  today. Enough damage bursts it. One eye per Hive; the Hive dies on the table, like a dissection.
- **Getting up:** the strapped surgeon can hold a key to get up **until the scoop** (step 2).
  After that they're committed until the graft is finished.
- **Any surgeon eye fits any surgeon.** You can end up with a teammate's eye; the label says whose.
  It does nothing, and it's funny.
- **Refusals:** the graft isn't offered unless the swap makes sense: a Hive eye into a surgeon
  with two normal eyes, or a surgeon's eye into a surgeon with a Hive eye. The table says why when
  it refuses (no vat on the stand, eye spoiled, "already has one", nobody strapped down).
- **Where things are:** three empty vats sit on the lab wall at the start of a run. The scalpel
  and eye spoon start in the lab storage in the OR, so the feature is never blocked by a search.
  Vats and their contents last the whole run (the entrance building never changes); a new run
  resets them.
- **The graft lasts the run,** through death, like rocket boots, and is lost on a game over
  like abilities from brains today.
- **Hive Eyes comes only from the graft now.** Remove the Hive brain → blender → Hive Eyes path.
  Echo stays on Discharged brains and the blender for now.

## Chunks

A and B can run at the same time. C starts after both are merged.

### A. `graft-extract`: the eye, the vat, the extraction (Sonnet)
- New items: the scalpel, the eye spoon, the Hive eye, a surgeon's eye (owner-labelled). The
  eyes spoil; they sell at the furnace.
- The specimen vat: a glass jar of cloudy fluid, carried in both hands like bulky loot. Aim + E
  with an eye in hand puts it in; the eye floats in the jar. Taking an eye back out needs its own
  input (the implementer picks one and says which). The vat stops spoiling.
- Vats live on the lab benches, not on the graft stand. Aim + E sets a carried vat back down on
  a lab bench (fixed spots along the benches are fine), so after a graft it goes home instead of
  sitting by the table.
- Three empty vats on the lab wall, plus set dressing jars with things floating in them, mostly
  heads. The stylized kit's heads (surgeon, Hive) are the obvious source.
- **Eyeball Extraction** on a strapped Hive, using the steps above and the existing dissection
  flow (its sedation, stirring and condition rules).
- Register everything new in `scripts/warmup.gd`. Add the database entries for the new items.
- **Zach sees:** `GRAFT: catch a Hive, take its eye, put it in a vat`.

### B. `graft-strap`: strapping yourself down, and Dr. Botsworth (Opus, high: player control and netcode)
- A healthy player can aim at the player table and press E to lie down and be strapped in:
  `on_table`, face up, first person. Hold a key to get up (the graft brief blocks this later,
  after the scoop).
- A dev panel option, **Control Dr. Botsworth**: spawns Dr. Botsworth, a full surgeon body that
  can hold items and operate, if he isn't there, and moves your input and camera into him. The
  same option takes you back. Your own body stays where you left it, strapped down or not, and
  other players see both bodies. Botsworth has to be able to do everything a player does at a
  table (take items, operate, run the minigames), because he'll be the one operating on you.
- **Zach sees:** `BOTSWORTH: strap yourself down, switch to Botsworth, look at yourself`.

### C. `graft-surgery`: the graft itself (Opus, high: several systems)
- The graft stand next to the player table: E sets a carried vat down on it, and E picks it back
  up to carry it to the lab benches. The stand holds a vat only for as long as someone leaves it
  there.
- **Eyeball Grafting** on a strapped surgeon, with the steps, refusals and no-botch rule above.
  The strapped player's awake camera during it.
- The eye swap on the body: the surgeon model already has each eye as its own object, and a
  `surgeon_graft` variant with the left eye as a stitched Hive eye (`art/stylized/README.md`).
  It shows in third person, on other players' screens and in the Personnel mirrors.
- The glow: the Hive eye material's `Lock` value (0 = low pinpoint, 1 = the whole ball lit).
  Low normally, high while the surgeon is in Hive Eyes. Replicated.
- Grafting puts Hive Eyes level 1 in the next free ability slot, with the new-ability card;
  swapping back removes it. Remove the Hive brain route to Hive Eyes.
- The first-person orange tint on the left edge.
- Update DESIGN.md (the Hive row, a Grafting section, the lab wall) and docs/CONTRACTS.md.
- **Zach sees:** `GRAFT: as Botsworth, give yourself a Hive eye, then check the mirror`
  (`-Count 2` also works if he wants to test it with two real windows).

## Done when

- A whole run of the loop works from a normal shift: catch, extract, vat, strap, graft, Hive Eyes,
  swap back, sell an eye.
- It works in co-op: a nettest scenario for the graft, with the eye swap and glow seen by the
  other machine.
- Headless checks: an eye spoils outside a vat and not inside; a spoiled eye can't be grafted; the
  graft is refused without a vat on the stand; a graft gives Hive Eyes 1 and swapping back takes it
  away; you can't get up after the scoop.

## Not in this part

Other species' parts, levels past 1, a second Hive eye, graft botches, the solo surgical robot,
Hives seeing through the grafted surgeon (in the backlog), and the Growths redesign (dropped).
