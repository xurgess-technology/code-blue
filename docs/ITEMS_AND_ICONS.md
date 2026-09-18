# Items and icons: the cut-down, the trinkets, and an icon for everything

Brief for the orchestrator. Agreed with Zach on 2026-09-18 (theory session).

## The goal

1. **Cut the item list to 26 items, each with a clear job.** The loot goes from 21 kinds to 11:
   five plain loot items and six **trinkets** that sell but also do one thing.
2. **Give every item and ability an icon,** drawn in one style, and **replace the text item bar**
   with an icon bar.

The icons are done: `art/icons/items/` (items) and `art/icons/` (abilities). Look at
`art/icons/items/sheet.html` in a browser to see them all.

## The item list

**Surgery (8):** anesthetic, gauze, suture kit, forceps, tourniquet, bone saw, and the scalpel and
eye spoon from grafting (`docs/GRAFTING.md`).

**Shop (2):** placebo pills, rocket boots. Unchanged.

**Body parts (4):** the Hive's eyeball, a surgeon's eyeball, the Sonographer's trachea, a
surgeon's trachea. These come from the grafting briefs (`docs/GRAFTING.md`,
`docs/GRAFTING_TRACHEA.md`). Named "X's Y"; a surgeon's own part carries their name ("Zach's
eyeball").

**Plain loot (6):** they exist to be sold.

| Item (kind) | Role |
|---|---|
| Pill bottle (`pill_bottle`) | Common; stacks |
| X-ray film (`xray_film`) | Common; flat; radiology |
| Heart monitor (`heart_monitor`) | Bulky; mid value; fragile |
| Gold watch (`gold_watch`) | Tiny and rare |
| Portable ultrasound (`ultrasound`) | Bulky and rare; the jackpot |
| Specimen vat (`specimen_vat`) | Equipment from grafting; counts as plain loot for its icon |

**Trinkets (6):** they sell, but each also does one thing, so it's always use it or sell it. One-use
trinkets sell for a small scrap value once used up.

| Item (kind) | What it does |
|---|---|
| **Desk phone** (`desk_phone`, existing loot) | Set it down and it rings loudly for about 10 s: a decoy. It can be picked up and used again. **Every time you pull it out (select it) there's a small chance, about 12%, that it starts ringing in your hands.** |
| **Laptop** (`laptop`, existing loot) | Once: open it (left mouse) for a few seconds of a map of the area around you (about 25 m), with **blips for surgery items** nearby. Then the battery dies. |
| **Defibrillator** (`defibrillator`, existing loot) | Once: aim at a downed teammate and use it to revive them where they lie, no carrying to the table. Bulky, and very loud (a real noise event). |
| **Pulse oximeter** (`pulse_oximeter`, new trinket; replaces the old loot of that name) | **Tag a monster.** In the same window as the sedative jab (a monster stunned by a shove), use it on the monster instead of sedating it. The monster gets up and carries on, and from then on **the whole team hears its heartbeat**: positional, through walls, slow while it wanders, faster when it's suspicious, racing when it hunts. You get the pulse ox back when that monster is caught or killed. The Night Nurse can't be tagged (shoves don't stun her). |
| **Reflex hammer** (`reflex_hammer`, existing loot) | Bonk anyone in reach and **they instantly spin 180°.** A teammate's camera snaps round. A Hive loses sight of you. A Sonographer turns, and a charging echo goes the wrong way. The Night Nurse ignores it. Reusable, with a short cooldown. |
| **EpiPen** (`epipen`, new) | Once: jab yourself or a teammate for double sprint speed for 10 s, then a 3 s collapse. |

**Cut (13 kinds):** stethoscope, ear thermometer (`thermometer`), BP cuff, otoscope, patient
records, wheelchair wheel, sample rack, wedding ring, coffee maker, IV pump, microscope, the old
pulse oximeter loot, and the brains (the brains go in `docs/GRAFTING_TRACHEA.md`; don't remove them
here, only the loot). Remove them from `scripts/economy/loot_table.gd`, their models from
`loot_models.gd`, and every other mention (dev panel, database, tips, tests, `warmup.gd`).

**Rebalance after the cut:**
- **Room coverage:** no room kind that had loot before may end up with none. The lab, break room,
  cafeteria, maintenance and janitor's closet lose theirs in the cut; spread the kept items over
  them with the room weights (the laptop fits the lab, the desk phone the break room, and so on).
- **Pay:** a shift's total loot value should come out within about 10% of today's. Measure before
  and after on the same seeds, and adjust the price ranges.
- **Trinkets are rarer than plain loot,** so finding one feels like a find.

## The icon style (for anything drawn later too)

- **One object, close up, kept in the middle of the slot.** Tails, nerves and badges fit around
  it; they never pull it off centre.
- **Flat colours, a thick dark outline, chunky shapes.** No gradients, no fine hatching. It has to
  read at about 40 px.
- **Only monster parts glow,** in their monster's colour: the Hive orange, the Sonographer violet.
- **Items sit on rounded squares, abilities on circles.**
- **The slot border's colour is the category:**

| Category | Border |
|---|---|
| Surgery | Doctor blue `#3f86d6` |
| Shop | Green `#3fa860` |
| Body parts | Deep red `#a3182c` |
| Plain loot (and the vat) | Eggshell `#c9b98f` |
| Trinkets | Gold `#f0b429`, with a thin light inner line and a glint: a shinier plain loot |

## The files

- `art/icons/items/make_icons.mjs` draws every item icon from these rules (`node make_icons.mjs`
  in that folder). **Change icons by editing it and re-running**, not by hand-editing SVGs.
- `art/icons/items/<kind>.svg`: **framed** icons (slot, border, a sample count badge) for anywhere
  an icon stands alone, like the database.
- `art/icons/items/bare/<kind>.svg`: **bare** icons, just the object on transparent, for the HUD,
  which draws its own slot, border, selection and live count.
- `art/icons/items/categories.json`: each kind's name, category and glow, plus the border
  colours.
- `art/icons/hive_eyes.svg`, `art/icons/echolocation.svg`: the ability icons (round, framed).
- File names are the item kinds. Import the SVGs big enough for their largest use (the database
  card) with mipmaps, so they stay crisp at 40 px. Register them in `scripts/warmup.gd`.

## The new item bar

Replaces the text boxes in `scripts/hud.gd` `_draw_hands`.

- **Four square slots** along the bottom centre, one per hand slot (`C.CARRY_CAP`), each showing
  its item's bare icon in a dark rounded square with its category border. A small key number
  (1–4) in a corner. Empty slots are dark and faint.
- **The selected slot** is bigger or lifted, with a bright outline.
- **Bulky items** (heart monitor, defibrillator, ultrasound, the vat) take two slots, drawn as
  **one wide slot** with the icon centred across both.
- **Stacks** show a live count badge in the corner (the HUD draws it; the bare icons have none).
- **No prices on the bar.** You find out what something's worth at the furnace.
- **The name flashes:** whenever the held item changes (switching slots, picking something up), its
  name appears above the bar for about 2 s, then fades.
- **Alt keeps its current behaviour:** the item bar shrinks into the small top-left row and the
  ability bar grows into its place, now as small icons.

### Calls the theory session made (not yet approved by Zach)

- **Spoiling:** a body part outside a vat shows a ring draining around its slot, and its icon
  greys as it spoils. A spoiled part stays grey.
- **Used-up trinkets:** greyed, with a crack across the icon.
- **The pickup pop:** picking something up, its icon pops up from the crosshair and flies into
  the slot it lands in (about 0.3 s).

## Icons everywhere else

- **The ability bar:** the Hive Eyes and Echolocation icons replace the drawn glyphs in the round
  slots. The HUD adds a glow in the ability's colour: steady when ready, stronger while in use,
  dim on cooldown (the radial cooldown sweep stays). Any ability without an icon keeps its glyph.
- **The database** (the break-room screen): item and procedure pages show the framed icon beside
  the turning model, and the section cards use icons.
- **The OR's "next step needs":** wherever a surgery step names the item it needs (the OR monitor,
  the prompt at the table), show that item's icon.
- **The pickup pop** (above).
- Not now: the pharmacy fax form (it would want printed, inky versions of the icons).

## Chunks

| # | Branch | What | Who | When |
|---|---|---|---|---|
| A | `items-cut` | The cut, the rebalance (rooms and pay), trinket rarity, and the new kinds `epipen` and the new `pulse_oximeter` as items with models (Godot primitives are fine, like the existing loot models). No trinket behaviour yet. | Sonnet, medium | Any time |
| B | `trinkets` | What the six trinkets do, the scrap value when used up, the noises, networking. | Opus, high (it touches monsters, downed players and cameras over the network) | After A |
| C | `icon-bar` | The icon item bar, the name flash, bulky wide slots, counts, spoil rings, used-trinket look, the pickup pop; icons in the ability bar, the database and the OR step. | Sonnet, high | Any time; it reads kinds generically, so items without an icon yet (anything grafting hasn't added) fall back to a plain slot |

**Zach sees:**
- A: `ITEMS: walk a shift and see what loot turns up` (a normal shift with a seed or two).
- B: `TRINKETS: try all six` (the dev room with each trinket laid out, and a monster to tag, bonk
  and escape from; `-Count 2` for the defibrillator and the reflex hammer on a teammate).
- C: `ICONS: pick things up, switch slots, hold Alt, open the database`.

## Done when

- Every kept item has its icon in the bar, the database and (for surgery items) the OR step.
- No cut item is left anywhere (items, models, dev panel, database, tips, tests).
- Every room kind that had loot still gets some; a shift pays within about 10% of before.
- Headless checks: each one-use trinket works once, then sells for scrap; the desk phone's pull-out
  ring happens at about its chance over many pulls; a tagged monster's heartbeat follows its mode
  and the pulse ox comes back when it's caught; the reflex hammer turns a Hive and it loses sight.
- A nettest scenario: a trinket used on a teammate (the defibrillator or the reflex hammer) works
  on the other machine.
- Update DESIGN.md (Items) and docs/CONTRACTS.md (Inventory and money, the HUD).
