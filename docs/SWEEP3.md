# Sweep 3: fight, capture, dissect, absorb — brief for every worker

Project: Code Blue, Godot 4.7.2, GDScript. Read `DESIGN.md` (the monsters and "Fighting and
capturing monsters" sections are the design), `docs/CONTRACTS.md`, `docs/KNOWN_ISSUES.md`
and this file first. Godot console binary:
`"/c/Users/ZachBurgess/Desktop/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"`.

## How we work (same as sweep 2)

- **Every worker runs in its own git worktree on its own branch.** Commit on your branch as you
  go (small commits, messages ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`).
  Never push, never touch `main`, never rebase other branches. The main session merges.
- `.godot/` is not in git: run `godot --headless --path . --import` once in your worktree first
  (and again after adding a script with a `class_name`).
- **Stay inside your ownership list.** Small, clearly commented hooks (`# SWEEP 3 HOOK (<worker>)`)
  in files you do not own are allowed when your feature cannot exist without them; keep them
  minimal and list every one in your final report.
- Prefer `const X := preload(...)` over another file's `class_name`.
- Assets: CC0 only, recorded in `ASSETS.md` under a heading for your area; everything degrades when
  an asset is missing. Primitive/procedural models are fine and expected.
- New content that renders must be registered in `scripts/warmup.gd`. Performance target: 60 fps,
  1% lows above 50 on a Radeon 890M at 1600x900 medium. Do not regress `tools/perfprobe.tscn`.
- Multiplayer rules: the host owns monsters, items, cases, damage, money; each client owns its own
  movement and aim. Anything that changes world state must work for a client and replicate:
  continuous state in a report (quantized, copies, small), one-offs as reliable events. Events for
  your system use your prefix (`cb_`, `dx_`, `br_`) and arrive in your `on_event`. Interactables
  keep `interact_prompt / interact_hold / interact` with machine-stable `interact_id`s.
- **Other workers are building against the contracts below at the same time.** When a method from
  another worker does not exist yet on your branch, check with `has_method` and fall back to
  something simple, so your branch runs and tests on its own.
- **Test for real.** Headless runs always pass `--fixed-fps 60`. Keep `tools/playtest.tscn -- --god`
  passing, build a headless test for your system, add a `tools/nettest` scenario if you change what
  crosses the wire, and take windowed screenshots (`--resolution 1280x720`) of anything visual and
  judge them honestly. Screenshots go in a gitignored `tools/*_shots/` folder.
- Delete throwaway probe scripts before your final commit.
- Final report (your last message): what you built, how you tested it (commands and results), every
  hook outside your ownership, contracts others rely on, known problems. Add your open problems to
  `docs/KNOWN_ISSUES.md` and your contracts to `docs/CONTRACTS.md` (a short section for your area).

## Locked decisions (Zach, 2026-09-13)

- Players can fight monsters. **Kill** with the bone saw (pays nothing) or **capture** (shove, jab
  anesthetic, drag, strap to a patient table) and dissect for the **brain** (the money / upgrades).
- The bone saw is a weapon with a chance to break on each hit. It is the same item surgery needs.
- The Night Nurse stays unfightable: the saw and the needle do nothing to her. No brain.
- New monster **The Hive** (sight only, slow, loses interest fast, weak, common near wing
  starts). **The Discharged** redesign: eyeless, somewhat taller than a surgeon (not extremely),
  ears clear and on the large side of normal (not comical), ears react to sound.
- Strapped monsters cannot hurt anyone. They wake up (stir, then thrash) and need more anesthetic;
  each extra dose works for less time (tolerance).
- Both the Hive and the Discharged carry a brain. Brains spoil fast. The **dumpster** (the
  existing sell bin in the neutral area) is the only sell point.
- The break-room **blender**: blend and drink a brain to absorb it. Per player; reset on game over
  with the money. Hive brains teach **Hive Eyes**, Discharged brains teach **Echo** (R key).
- No tackle move: shove (Q, or left mouse with nothing usable in hand) opens the capture window.
- Not in this sweep: Puppet, Rise, side effects, strap breaks.

## Scaffold already on main (main session)

- Input: `use` = left mouse (removed from `shove`, which is Q only). `read` (R) opens the guide
  when holding it or aiming at it, otherwise it is the brain ability.
- `Player`: `use_count`, `ability_count` (client -> host in `report_state()` slots 9 and 10),
  bot seam `bot_use`, `bot_ability` (bump to press once). Left mouse increments `use_count` when
  `game.combat.is_usable(selected_stack().kind)`, else it shoves. `_consume_actions` calls
  `game.player_used(p)` (not while downed or carrying a player) and `game.player_ability(p)`
  (not while downed).
- `game.combat` (`scripts/combat/combat.gd`), `game.dissection` (`scripts/dissection/dissection.gd`),
  `game.brains` (`scripts/brains/brains.gd`): stubs, children of Game on every machine. Each has
  `setup(game)`, `physics_tick(delta)` (every machine, every physics frame), `net_state() ->
  Dictionary` (host, rides in the global snapshot fields `cb` / `dx` / `br`: keep it small and
  quantized), `apply_net_state(d)` (clients, applied after cases, money and the loop),
  `on_event(kind, data)`. Plus `combat.is_usable(kind)`, `combat.use(p)`,
  `combat.on_monsters_cleared()`, `combat.on_monster_removed(m)` (called by `game.kill_monster`),
  `dissection.owns_case(c)` (true skips the vitals drain), `brains.ability(p)`, `brains.on_reset()`
  (called from `game.reset_money`). Replace your stub entirely; keep its API.
- `ShiftLoop.pay_for(c)` returns 0 for a case with `monster: true`.

## Workers and ownership (all in parallel)

| Worker | Builds | Owns |
| --- | --- | --- |
| `monsters` | The Hive; the Discharged redesign; monster hp, hits, stun, sedation, lying and dragged states; roster and spawn placement | `scripts/monster.gd`, `scripts/monsters/**`, `scripts/perception.gd`, `tools/monster_lab.*`, `tools/gen_audio_monsters.mjs`, `audio/sfx/monsters_*`; hooks: `game._spawn_monsters`, dev panel monster spawn list, `warmup.gd` |
| `combat` | Saw swings and breaking, anesthetic jabs (monsters and teammates), dragging a sedated monster, strapping it to a patient table, first-person swing/jab animation | `scripts/combat/**`, `tools/combattest.*`, `tools/gen_audio_combat.mjs`; hooks: `player.gd` (drag field, speed, busy flags, aim prompt, held-item animation), `game.gd` (strap path), dev room dispensers if needed |
| `dissection` | Monster patients and bodies on the table, the `dissection` ailment, sedation decay / stir / thrash, re-dosing with tolerance, brain condition, handing over the brain | `scripts/dissection/**`, `scripts/procedures.gd`, `scripts/patient_body.gd` (create dispatch only), new variants in `scripts/surgery/games/saw.gd` and `forceps.gd`, `tools/dissectiontest.*`, `tools/gen_audio_dissection.mjs`; hooks: `game._table_prompt` / `_proxy_used`, `game.finish_case` wording, OR screen labels, dev panel "strap a monster" |
| `brains` | Brain items and spoilage, the dumpster wording, the blender, per-player brain levels, Echo, Hive Eyes | `scripts/brains/**`, brain entries in `scripts/economy/loot_table.gd` and `loot_models.gd`, `economy.gd` prompts, `tools/braintest.*`, `tools/gen_audio_brains.mjs`; hooks: `world_item.gd` / `game.gd` pickup, drop and sell paths (spoil time), `player.gd` (Hive Eyes freeze, report key), `main.gd` camera choice |

## Contracts

### Monsters (`monsters`)

```gdscript
const HIVE := "hive"                       # Monster; DISCHARGED, NIGHT_NURSE stay
static func roster(shift, player_count) -> Array[String]   # now also Hives (their own cap, see below)
static func is_capturable(kind: String) -> bool  # hive, discharged
enum State { WANDER, CHASE, STUNNED, SEDATED }   # SEDATED appended
enum Mode { ..., SEDATED }                       # appended at the end (ints stay stable)
var hp: int; var max_hp: int                     # hive 2, discharged 4, night_nurse 0
func can_be_hurt() -> bool                        # false for the Night Nurse
func take_hit(dir: Vector3, amount: int, source: String) -> String
	# host: "stagger" (a short stun, knocked back), "killed" (hp reached 0; the CALLER then calls
	# game.kill_monster(m)), "immune" (the Night Nurse: nothing happens)
func can_sedate() -> bool       # capturable, not sedated, and stunned right now (the shove window)
func sedate(seconds: float) -> bool   # host: falls down, lies still, brain stops; wakes when it runs out
func is_sedated() -> bool
var sedation_left: float        # host seconds; replicated as a flag only
func wake() -> void             # host: gets up staggering, then hunts normally (alerted to the nearest player)
var dragged_by: int = 0         # peer id dragging it (set by combat); while non-zero the brain does not
                                # think and every machine places it at game.combat.monster_pin(m)
static func make_lying(kind: String) -> Node3D    # monster_model.gd: a still copy lying on its back along
	# X, head toward -X, origin at the middle of its back (the PatientBody convention); primitives OK
```

- Shove stuns the Hive (2 s) as it does the Discharged. A sedated monster never hits anyone and
  is not solid to players (still on the navigation mesh).
- `report()` adds `sd` (sedated), `db` (dragged_by) and `hp` only if clients need it. Clients show
  the lying pose while `sd`.
- The Hive: sight only (ignores noise). Cone about 110 degrees, 12 m, clear line (walls block;
  darkness does not matter). Wander 0.8 m/s, chase 1.8 m/s (a surgeon walks 3.4). It lumbers
  straight at a player it sees; 2.5 s without sight it walks to where it last saw them, looks around
  about 3 s, and gives up. Hits for 1 on contact, then backs off like the Discharged. Line-of-sight
  checks staggered (a few Hz), never per frame for every Hive.
- Roster: Hives from shift 1 in small groups (2-3) placed on hallway spawn points of the
  shallowest part of each wing (nearest the entrance building), more with shifts and players, own cap
  (`MAX_HIVES`, about 8); the Discharged and the Night Nurse keep `MAX_MONSTERS`. Never in the
  entrance building or neutral area.
- The Discharged redesign as in `DESIGN.md`; ears swivel toward `listen_yaw` and flare while
  listening. Height about 2.1 m. Keep the IV pole rattle.
- Sounds: Hive groan (occasional, not constant), shuffle, hit, death; sedated breathing.

### Combat (`combat`)

```gdscript
game.combat.is_usable(kind) -> bool      # "bone_saw", "anesthetic"
game.combat.use(p)                        # host
game.combat.monster_pin(m) -> Transform3D # every machine: where a dragged monster lies this frame
game.combat.dragging(p) -> int            # monster id p drags, -1 none (Player field `dragging_monster`, report key `dm`)
game.combat.drop_dragged(p)               # host
SAW_BREAK_CHANCE := 0.12   SWING_COOLDOWN := 0.8   SAW_REACH := 2.0
SEDATE_SECONDS := 75.0     JAB_COOLDOWN := 1.0      JAB_REACH := 1.8
```

- Saw swing (host, from the player's aim): the first monster or player in a short cone. Monster:
  `take_hit`, `"killed"` -> `game.kill_monster(m)`. The Night Nurse: "immune" with a clang, and the
  saw can still break. A player: `game.damage_player(q, 1, "saw:<name>", knock)`. Every connecting
  hit rolls `SAW_BREAK_CHANCE`: the stack is cleared, a snap sound and "X's bone saw snapped.".
  Noise 0.9 on a hit, 0.3 on a swing through air. Kills pay nothing.
- Jab (host): the monster in reach that `can_sedate()` -> uses one vial from the hand stack and
  `sedate(SEDATE_SECONDS)`. Not stunned: no vial used, the monster is alerted, "It shrugged off the
  needle.". The Night Nurse: "The needle will not go in.". A teammate: uses a vial, knocks them out
  for about 8 s (`stun`, hands drop).
- Drag: hold E (1 s, empty hands, like carrying a downed player) on a sedated monster (an aim proxy
  with interact_id `mo_<id>`). The dragger moves at about 0.55 speed and cannot shove, use, drop or
  change slots; the monster slides along behind. E on a free patient table (`game.free_patient_table`
  / `table_interact_id`) straps it: `game.add_case({table, patient_id: m.kind, ailment_id:
  "dissection", monster: true, flags: {sedation: s}})` with `s` from how much sedation is left (0.35
  .. 1.0), then the monster node is removed quietly (no death effect, `on_monster_removed`). E
  anywhere else puts it down. If it wakes while dragged it is dropped, gets up, and hits the dragger.
- First-person swing and jab animations on the held model; others see it (event `cb_swing`).

### Dissection (`dissection`)

- `Procedures.PATIENTS` gains `hive` and `discharged` with `monster: true` (name, weight,
  blurbs). `roll()` never picks a monster. `AILMENTS.dissection` has `monster_only: true` (not in
  `patient_ailments()`), steps: `{id "open", label "Saw open the skull", item "bone_saw", uses 0,
  game "saw", variant "skull", site "skull"}`, `{id "harvest", label "Pull out the brain", item
  "forceps", uses 0, game "forceps", variant "brain", site "brain"}`.
- `PatientBody.create("hive" | "discharged")` returns a monster body (in `scripts/dissection/`)
  with the full PatientBody surface (see CONTRACTS.md "Patient body"), sites `injection`, `skull`,
  `brain`, straps over chest, arms and legs, `make_lying` for the look when present. Flags
  `skull_open`, `brain_removed`, `sedation`. `set_sedation` low = twitching, very low = thrashing
  against the straps.
- The existing limb / gunshot behaviour of `saw.gd` and `forceps.gd` stays exactly as it is; their
  self-tests keep passing; the new variants get `bot_input` and a self-test.
- Sedation (host, per monster case): starts at the strap value; falls to 0 in about 120 s; about
  2.5x faster while someone saws. `flags.sedation` must reach the operator's machine within about
  0.05 (the existing stir code in `surgery_system.gd` reads it) without resending the case every
  tick. 0.35..0.75: stirs (already built). Below 0.35: awake: thrashes (strong jolts, a botch of
  about 1.5 every 3 s while operated, shrieks as noise 0.7).
- Re-dose: anyone holding anesthetic, E on a monster's table (also while someone else operates):
  one vial, sedation `+0.6 * 0.6^n` (n = doses given so far), capped at 1.0. Prompt shows how under
  it is.
- Vitals of a monster case = brain condition: botches lower it, nothing drains it. At 0 the case is
  lost ("The brain is ruined."). The last step wins the case: the brain appears by the table via
  `game.brains.spawn_brain(kind, quality, pos)` (`kind` `brain_hive` / `brain_discharged`,
  `quality` = condition / 100; fall back to a plain loot item when the method is missing), the
  monster flatlines, and the case is removed about 6 s later to free the table.

### Brains (`brains`)

```gdscript
game.brains.spawn_brain(kind: String, quality: float, pos: Vector3) -> Node   # host
game.brains.spoil_factor(age_seconds: float) -> float    # 1.0 for 45 s, down to 0.15 at 225 s
game.brains.current_value(stack_or_item) -> int          # base value * spoil factor
game.brains.level(peer_id: int, path: String) -> int     # path "hive" | "discharged", 0..3
game.brains.points(peer_id: int, path: String) -> float
```

- Loot kinds `brain_hive` (base about $150) and `brain_discharged` (about $350), scaled by
  `quality`; fragile; never spawned by the loot spawner. Spoil start time travels with the item
  (WorldItem and the hand slot, key `bt`, world_time) through pickups and drops. A spoiling brain
  looks worse (darker, greener). The dumpster pays `current_value`; its prompts say dumpster.
- Blender: in the break room (a counter or wall spot from `level_info.rooms`; else near the clock),
  interact_id `blender`. Holding a brain: hold E 1.5 s to blend, then it is drunk: points for that
  path +1.0 fresh (factor >= 0.6), +0.75 spoiling, +0.5 rotten; level = floor(points), max 3.
  Replicated in `br`. Reset by `on_reset()`.
- R (`brains.ability(p)`): uses the path with more points (tie: Echo); none: a short "Nothing
  happens." hint. Echo cooldown about 20 s, Hive Eyes about 12 s.
- Echo: noise 1.2 at the player (every Discharged in range comes), a shriek everyone hears
  (event `br_echo`), and on that player's machine only, for 2.5 + 0.75 per level seconds, the view
  darkens and monsters (red), players (white), surgical items (teal), loot (gold) and containers
  (dim) within 12 m (+6 per level) show as outlines through walls. Cheap: only while active,
  bounded node count.
- Hive Eyes: the nearest Hive within 20 m (+10 per level), through walls; that player's view
  jumps to its eyes for 5 s (+2 per level) with a grainy sickly look; R, E or Esc ends it early; it
  ends if the Hive dies or is sedated or the player is hit. The body stands still and helpless
  (Player field `hive_view`, report key `hv`; others see the head droop).

## After the workers

The main session merges all four, runs every test (headless suites, `playtest --god`, nettest
all scenarios, perfprobe), fixes the seams, updates the test bot if monsters get in its way,
updates `docs/`, and reports once.
