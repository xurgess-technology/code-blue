# Grafting, part two: the Sonographer's trachea

Brief for the orchestrator. Agreed with Zach on 2026-09-18 (theory session). It builds on
grafting part one (`docs/GRAFTING.md`) and the Sonographer (`docs/SONOGRAPHER.md`); read those
first. Everything part one decided (the vats, the graft stand, strapping yourself down, the awake
patient, no botches on grafts, Dr. Botsworth, swaps only) applies here too, unless this brief says
otherwise.

## The goal

**Echo comes from a graft now, the same way Hive Eyes does.** The team catches a Sonographer, takes
its glowing trachea out on an OR table, keeps it in a vat, then swaps it with a surgeon's trachea
on the player table. The grafted surgeon's throat glows violet through the skin, and they get
**Echo**.

**Brains and the blender are gone.** Neither monster has a brain to harvest any more (the Hive
lost its brain in 0.6.5), so the brain items, the brain harvest and the break-room blender are
removed. Grafting is the only way to get an ability.

## The loop

1. **Catch a Sonographer** and strap it to an OR table (shove, jab, drag, strap).
2. **Trachea Extraction** on the Sonographer. The trachea comes out in the operator's hand.
3. **Put it in a vat.** A vat holds one body part: an eyeball or a trachea. Outside a vat it
   spoils.
4. **A surgeon straps themselves** to the player table, and the vat goes on the graft stand.
5. **Another player runs Trachea Grafting.** The surgeon's own trachea goes into the vat and the
   Sonographer's goes in.
6. The surgeon now has **Echo, level 1**. Their throat glows low normally and bright while Echo
   fires.
7. **Swapping back** is the same surgery with the surgeon's trachea in the vat.

## Decisions (locked by Zach)

- **Body parts are named "X's Y":** the Sonographer's trachea, the Hive's eyeball, and a surgeon's
  own parts by name: "Zach's trachea", "Zach's eyeball".
- **The brains, the brain harvest and the blender are removed.** The spoil system they used stays,
  renamed for body parts, since eyeballs and tracheas use it.
- **Echo comes only from the trachea graft.**
- **The Echo ability itself doesn't change here.** It's still today's loud shriek and outlines.
  Turning it into the Sonographer's ping is later (docs/backlog/SWEEP4B.md).

## Calls the theory session made (not yet approved by Zach)

- **Extraction steps (on a Sonographer):** 1. Scalpel: open the throat along the glowing line.
  2. Scalpel: cut the windpipe free, top and bottom. **The last cut makes it shriek**: a real loud
  noise event that can pull monsters to the OR. 3. Forceps: lift it out. The usual monster-table
  rules apply (sedation wears off, stirring shakes the hand, botches damage the part; enough damage
  shreds it). The Sonographer dies on the table.
- **Graft steps (on a surgeon):** 1. Scalpel: open the throat. 2. Forceps: lift the old trachea
  out (it drops into the vat, and the vat's trachea comes up onto the stand). 3. Forceps: seat the
  new one. 4. Suture kit: stitch the throat closed. No botches, the surgeon is awake, and they can
  get up until step 2, as in part one.
- **A surgeon can have both grafts,** an eye and a trachea: different sites, different abilities,
  each at level 1. Refusals work as in part one ("already has one", no vat on the stand, spoiled,
  nobody strapped down), and a vat holding an eyeball can't be used for a trachea graft.
- **The grafted surgeon's look:** see-through skin down the front of the throat with the violet
  windpipe glowing through it, matching the Sonographer's throat and the Echolocation icon
  (`art/icons/echolocation.svg`). It shows in third person, on other players' screens and in the
  Personnel mirrors. Stitches across the throat.
- **A first-person tell:** a faint violet glow along the bottom edge of the view, stronger while
  Echo fires (like the eye graft's orange edge).
- **The database's third tier** ("harvested") now means a part was extracted or grafted.

## Chunks

| # | Branch | What | Who | When |
|---|---|---|---|---|
| A | `trachea-art` | The surgeon's grafted throat (a `surgeon_graft` style variant with the see-through throat and stitches, `art/stylized/`), and the two trachea item models: the Sonographer's (violet, glowing) and a surgeon's (pale pink cartilage). | Orchestrator's call; Blender-from-Python work | Any time |
| B | `graft-trachea` | Remove the brains, the brain harvest and the blender; rename the spoil system for body parts. Trachea Extraction, the trachea items, vats holding either part, Trachea Grafting, the refusals, the throat glow (replicated), the first-person tell, Echo from the graft. Update DESIGN.md and docs/CONTRACTS.md. | Opus, high | After grafting part one's chunk C, the Sonographer's two chunks, and A are all merged |

**Zach sees:**
- A: `TRACHEA: the grafted throat and the two tracheas` (renders, or a lab scene).
- B: `TRACHEA: as Botsworth, give yourself the Sonographer's trachea, then Echo in the mirror`.

## Done when

- A whole run of the loop works from a normal shift: catch a Sonographer, extract, vat, strap,
  graft, Echo, swap back, sell a trachea.
- No brain items, brain harvest or blender are left anywhere (items, dev panel, database, tips,
  tests).
- Headless checks: a trachea spoils outside a vat and not inside; the last extraction cut emits a
  noise; the graft gives Echo 1 and swapping back takes it away; a surgeon can hold both grafts; an
  eyeball vat is refused for a trachea graft.
- A nettest scenario: the throat glow is seen by the other machine.
