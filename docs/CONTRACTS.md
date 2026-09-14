# Code Blue: system contracts for the content sweep

This is the agreement between the systems being built in parallel. If a contract here is wrong
or missing something, do not silently change it: tell the main session (SendMessage to
"main") what you need and why, and build against the contract as written meanwhile.

Project: `C:\Users\ZachBurgess\workspace\code-blue-godot`, Godot 4.7.2, GDScript.
Godot binary: `"/c/Users/ZachBurgess/Desktop/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"`.
Design brief: `DESIGN.md`, plus the "Design decisions" section at the bottom of this file.

## Ground rules for every worker

- **File ownership is strict.** Only edit the files your brief lists. The core files
  `scripts/game.gd`, `scripts/player.gd`, `scripts/hud.gd`, `scripts/main.gd`,
  `scripts/items.gd`, `scripts/procedures.gd`, `scripts/world_item.gd`,
  `scripts/item_models.gd`, `scripts/supply_shelf.gd`, `scripts/surgery/minigame.gd`,
  `project.godot` and this file belong to the main session.
- **Do not touch the performance work:** `_attach_light_flicker` and `_add_occluders` in
  `game.gd`, `set_quality` / `_load_quality` / the FPS label in `main.gd`, the quality code in
  `look.gd`, the `[rendering]` section of `project.godot`, and `tools/bench.gd`.
- **Stubs.** Some files you own already exist as a stub written by the main session so the game
  keeps running. Replace the stub entirely; keep its public API.
- **Cross-file references:** prefer `const X := preload("res://...")` over relying on another
  file's `class_name`, because the global class cache only refreshes on an import. After you
  create a new script with a `class_name`, run `godot --headless --path . --import` once.
  Several workers share this project: if an import errors on a locked cache file, wait 20
  seconds and retry.
- **Scale:** `scripts/consts.gd` (`C`). One tile is `C.TILE` = 1.5 m, walls `C.WALL_H` = 3 m,
  eye height 1.7 m, +Y up, Godot forward is -Z.
- **Assets:** `Assets` autoload (`scripts/assets.gd`, licences in `ASSETS.md`). Everything
  degrades: `Assets.has(key)` false / `Assets.spawn(key)` null means build a primitive instead.
  Only CC0 assets unless the main session says otherwise. Do not download new assets without
  recording them in `ASSETS.md` under a heading for your work area.
- **Sound:** do not edit `tools/gen_audio.mjs`. Put new sounds in your own generator
  `tools/gen_audio_<area>.mjs` writing `audio/sfx/<area>_<name>.wav` (numbered `_01`, `_02`
  variants get picked at random). Play with `Audio.play("<area>_<name>", position_or_null)`.
  Same deterministic, dependency-free style as `gen_audio.mjs`.
- **No git commands.** Delete throwaway probe scripts when done.
- **Verify headless where possible, and with real windowed screenshots for anything visual.**
  Read the screenshots back and judge them honestly.

## Shared data (main session)

- `Items` (`scripts/items.gd`): `ITEMS[kind]` with name, consumable, batch `[min,max]`, fragile,
  `found` weights by container type or `"loose"`, `loose_surfaces`, `real_use`, `where`,
  `handling`. `CONTAINER_TYPES[type]` with `rooms`. `LOCKED` placeholder tab names.
  Surgical kinds: `anesthetic`, `gauze`, `forceps`, `tourniquet`, `bone_saw` (`Items.SURGICAL`,
  what a patient case can need), plus `suture_kit` (surgical and consumable, not in `SURGICAL`;
  see "Downed players"). Plus `guide`.
- `Procedures` (`scripts/procedures.gd`): `PATIENTS` (`bob`, `seal`, with weight and limb
  radius), `AILMENTS` (`gunshot`, `amputation`, and `stitches` with `player_only: true`) with
  steps `{id, label, item, uses, game, variant?, site}`, `roll(seed, shift)` (never a
  player-only ailment), `patient_ailments()`, `is_player_only(id)`, `requirements(ailment)`,
  `remaining_requirements(ailment, from_step)`, `difficulty(shift)`, `MINIGAME_SCRIPTS`.
- `ItemModels.make(kind: String, count: int = 1) -> Node3D` (`scripts/item_models.gd`): the
  visual for a stack, origin at its base, no collision. Checks `Assets` for `item/<kind>` first.

## Interaction (main session owns the plumbing)

The player aims with a ray from the camera (`C.INTERACT_RANGE` metres). Anything interactable is a
`CollisionObject3D` (usually `StaticBody3D` or `Area3D`) on physics layer `C.L_INTERACT`
(bit 16) or `C.L_PICKUP` (bit 8), in the group `"interactable"`, with a metadata
`interact_id` that is **identical on every machine** (derive it from tile coordinates or the
seed, never from instance ids). The collider may be a child: the game walks up the parents to the
first node that has the meta.

That node implements:

```gdscript
func interact_prompt(player) -> String   # "" means not interactable right now; e.g. "Open fridge"
func interact_hold() -> float            # 0.0 for a press, seconds for a hold
func interact(player) -> void            # HOST ONLY, called after the host validated range and sight
```

`player` is a `Player` node: `peer_id`, `player_name`, `slots` (see below), `global_position`.

## Containers (containers worker)

Built by `scripts/hospital_builder.gd`. Each container node is in groups `"container"` and
`"interactable"`, has meta `interact_id` like `"ct_<tx>_<ty>_<n>"`, and implements:

```gdscript
var container_type: String                   # a key of Items.CONTAINER_TYPES
func slot_count() -> int
func slot_transform(i: int) -> Transform3D   # global; where an item stack sits inside
func is_open() -> bool
func set_open(open: bool, animate: bool = true) -> void
# plus interact_prompt / interact_hold / interact (toggle open/closed)
```

The host toggles containers through `interact()`; the game replicates `is_open()` to clients in
its snapshot and calls `set_open(value, true)` there. A container must not change its own open
state anywhere else. Opening calls `game.emit_noise(pos, 0.5, "container")` on the host only
(`get_tree().get_first_node_in_group("game")`).

`HospitalBuilder.build(gen, info)` additionally fills:

```gdscript
info["containers"]    = [{id, type, room_kind, wing, depth, node, position, slots}]
info["loose_anchors"] = [{position: Vector3, yaw: float, surface: "counter"|"tray"|"gurney"|"floor", room_kind: String, wing, depth}]
info["shelf"]         = {position: Vector3, yaw: float}   # OR supply shelf, near the tables
info["lectern"]       = {position: Vector3, yaw: float}   # in the break room
```

Sweep 2: which room kinds a container type stands in is `CONTAINER_ROOMS` in
`scripts/level/room_furnish.gd` (`Items.CONTAINER_TYPES[type].rooms` still names the old kinds
and is not used for placement). Every wing has a supply closet (medicine fridge, drawer unit,
often a pegboard), a nurse station (station drawers, a trauma bag), a janitor closet (pegboard)
and at least one trauma bag on a hallway wall.

## Item spawning (containers worker)

```gdscript
# scripts/item_spawner.gd
static func plan(seed: int, shift: int, ailment_id: String, info: Dictionary) -> Array
static func shortfall_plan(seed: int, need: Dictionary, have: Dictionary, info: Dictionary,
		occupied: Dictionary, avoid: Array) -> Array
# Each entry: {kind: String, count: int, container_id: String ("" when loose), slot: int, anchor: int}
# `occupied` is {"ct_id:slot": true, "anchor:<i>": true}; `avoid` is an Array[Vector3] to stay far from.
```

Rules (sweep 2): every needed consumable totals at least twice `Procedures.requirements()`, in
4 to 6 stacks at different places; every needed tool exists twice; every wing holds at least one
stack of something the case needs, and extra stacks lean toward deeper wings; nothing needed
spawns in `ItemSpawner.SAFE_ROOMS` (the entrance building's rooms and halls, the neutral area);
at least one needed item is far from the table; items the current ailment does not need also
spawn as red herrings; spawn counts respect `Items` batch sizes; deterministic from the seed.
Levels without `wing` on their containers and anchors count as one wing. The game instantiates
`WorldItem`s from the plan. `tools/spawncheck.gd` checks all of it.

## World items (main session)

`scripts/world_item.gd`, a `RigidBody3D` on layer `C.L_PICKUP`, group `"interactable"`,
meta `interact_id` `"it_<n>"`. Fields: `item_id`, `kind`, `count`, `state` (`IN_CONTAINER`,
`LOOSE`, `ON_LECTERN`), `container_id`, `slot`, `value` (loot only: dollars for the whole stack,
reported as `v` when above 0). Host-simulated physics when dropped; clients lerp to the snapshot
transform. Picking up removes the node and fills a hand slot (value included).

## Hands (main session)

`Player.slots` is an `Array` of `C.CARRY_CAP` (4) dictionaries `{kind: String, count: int}` plus
`v: int` (sell value) on loot; `kind` `""` when empty. `Player.selected` is 0..3 (keys 1-4, the
wheel). Stacks of the same kind merge when `Items.stacks(kind)` (consumables, stackable loot).
Bulky loot takes its slot and a second one, stored as `{kind: "", count: 0, of: <head index>}`:
not free, but invisible to code that walks slots looking for stacks. Host authoritative,
replicated in the snapshot. See "Inventory and money" for the helpers; do not assign slots by hand.

## The OR supply shelf (main session)

`game.shelf` is a `Dictionary` kind -> count. Pressing E on the shelf places the selected stack
(surgical kinds only; loot is refused).
`game.shelf_count(kind) -> int`.

## Patient body (patients worker)

```gdscript
# scripts/patient_body.gd
static func create(patient_id: String) -> Node3D       # a PatientBody, lying on its back, origin at the table top centre
func set_ailment(ailment_id: String) -> void            # shows the gunshot wound or the infected limb
func has_site(site: String) -> bool
func site_transform(site: String) -> Transform3D        # global; +Y out of the body surface, X along the limb or across the wound
func set_vitals(v: float) -> void                       # 0..100: breathing rate/depth, pallor, twitching when low
func set_sedation(s: float) -> void                     # 0 awake .. 1 fully under; low values fidget
func stir(strength: float) -> void                      # a sudden jolt right now
func set_bleeding(site: String, amount: float) -> void  # 0..1 blood at a site
func apply_flags(flags: Dictionary) -> void             # idempotent: "bullet_removed", "tourniquet" (float), "amputated", "dressed", "sedation"
                                                        # REPLACES the flag set (no merge): always pass every flag the case has
func flatline() -> void
func site_section(site: String) -> Dictionary           # limb sites: {half_up, half_side, axis_depth, shape}; {} elsewhere
func infection_start(site: String) -> float             # metres along the site's +X to where the body's infection begins; INF if none
func make_severed_limb(parent: Node) -> Node3D          # adds a static copy of the limb an amputation removes, posed where it is; may be null
```

Sites every patient provides: `injection`, `gunshot`, `limb` (above the infection, where the
tourniquet goes), `limb_cut` (the amputation line). Along the limb the order is always
tourniquet (`limb`), then the cut (`limb_cut`), then the infection, so the saw goes through
healthy tissue. The game places the body on the table and calls these; minigames may call
`set_bleeding` and `stir` for live effects.

`site_section`: `half_up` is skin-at-the-site to limb axis, `half_side` the half width across the
limb (site Z), `axis_depth` how far below the site origin the axis runs, `shape` a superellipse
exponent (2 round, 6 boxy). Minigames read limb geometry only through `site_section`,
`infection_start` and `make_severed_limb`, never through `PatientBody.parts`.

## Surgery (surgery worker)

```gdscript
# scripts/surgery/surgery_system.gd, a Node the game creates and adds as a child
func setup(game: Node) -> void
func start_case(patient_id: String, ailment_id: String) -> void   # every machine, when a shift begins
func clear_case() -> void
func can_begin(player) -> String      # host: "" if this player may start the current step now, else the reason
func begin(player) -> void            # host: this player becomes the operator
func end(player) -> void              # host: operator leaves (step progress is kept)
func physics_tick(delta: float) -> void
func net_state() -> Dictionary        # host -> clients inside the game snapshot
func apply_net_state(s: Dictionary) -> void
func receive_operator_report(peer_id: int, report: Dictionary) -> void   # host
func camera() -> Camera3D             # the camera to render through when the LOCAL player is operating, else null
func wants_mouse() -> bool            # local player is operating and needs a visible cursor
func local_operator_exit() -> void    # local player pressed Esc/E to stop operating
func hud_state() -> Dictionary        # what the HUD draws for the step being watched, or {}
```

Sweep 2 (loop): there is one surgery system per patient table (`game.surgeries`), each with
`var table_index: int` (index into `level_info.tables`) and `end_current()` (the case finished:
the operator steps back). A player operates at one table at a time. `bot_skill` is shared by all
of them (stored as `game.surgery_bot_skill`). `hud_state()` also carries `table`, `step_index`,
`steps`, `vitals`.

Game-side API the surgery system uses:

- `game.case_on_table(table_index)` (the case it operates on while its state is `on_table`) and
  `game.body_for_table(table_index)`; see "Shift loop and patients". `game.case` /
  `game.patient_body` remain as aliases of the first patient case.
- `game.shelf_count(kind)`, `game.is_host()`, `game.world_time`, `game.shift`, `game.players`
- `game.surgery_botch(amount: float, reason: String, table_index := -1)` host: costs that case's
  vitals, says why (-1: the first patient case)
- `game.surgery_step_done(result: Dictionary, table_index := -1)` host: consumes the step's items
  from the shelf, merges `result` into the case's flags, gives vitals back, advances; the last step
  makes the case stable (`game.finish_case`)
- `game.send_operator_report(report: Dictionary)` client operator -> host. Every report carries
  `"tb": table_index`; the game routes it to that table's `receive_operator_report` (on the host
  it calls it directly)
- `game.emit_noise(pos, loudness, kind)` host

Minigames extend `scripts/surgery/minigame.gd`; read that file, it is the contract. Parts of it that
are easy to miss:

- `on_jolt(offset, strength, duration)` is called on the operator's machine when an underdosed
  patient stirs; for `duration` seconds the cursor passed to `handle_cursor` carries a decaying
  shake of up to `offset`. React there rather than inferring jolts from cursor jumps.
- `Minigame.OWN_LAYER` (render layer 20) is reserved for a minigame's own props. Decals project
  only onto layer 1, so nothing on layer 20 gets painted. Cameras keep the default cull mask.
- `hud_state()` may add `cross_section: {layers: [{name, from, to, color}], depth, layer}`; the
  surgery HUD draws it as a strip under the gauges (the saw uses it).
`tools/minigame_lab.tscn` runs a single minigame on a stand-in patient, interactively or with its
`bot_input()`, and can take screenshots:
`godot --path . tools/minigame_lab.tscn -- --game=<id> [--patient=bob|seal] [--ailment=...] [--variant=...] [--bot=1.0|0.0] [--seconds=N] [--shot=res://tools/lab_shots/name.png] [--headless-report]`.

## Minigames (minigames worker, sweep 2)

The five steps no longer ask the player to read gauges or match sliders; the patient and the
tool show what is right. Conventions every step follows (and a new one, such as wave 3's
stitches, should too):

- `hud_state()` returns `gauges: []` and one short `hint` line. No step uses `cross_section`
  any more (the HUD still draws it if given).
- Colour language in the world: **green** = right / holds / grab it now (tourniquet strap and
  pulse probe, gauze path ring and trail, saw guide, forceps reach ring and exit glow);
  **amber** = works but weak (loose wrap, short saw pass, strap too high); **red** = a mistake is
  happening (strap on the infection, rushed or off-line saw, forced wound wall); **purple / grey**
  = too much (tourniquet too tight, overdose). Targets that must never hide (the anesthetic vein,
  the forceps glint and rings) draw with `no_depth_test`.
- Every botch has an in-world cause at the moment it happens (blood spurt, flinch via
  `body.stir`, blanching, slipping strap, unwinding gauze) and a reason string naming it.
- Timings and forgiveness targets, measured with the lab bots: skill 1.0 finishes in about
  8-20 s with 0-2 vitals of botches; skill 0.0 in under 40 s losing about 15-25.
- Stir shakes (`on_jolt`) never cause a botch by themselves except where the design says so
  (gauze: a jolt while winding slips the wrap).
- Forceps `net_state` keys: `x y i j g b st h dm p` plus `w` (0..1 how hard a wall is being
  forced) and `e` (jaws closed on nothing). `h` counts wall tears (each one spurts on every
  machine).
- Each game has a static `self_test()`: `godot --headless --path . tools/minigame_lab.tscn
  --fixed-fps 60 -- --selftest=<game>`. The lab re-places the minigame on the body's site every
  physics frame (as `surgery_system._place_mg` does), `--flags=sedation:0.4` makes stirs, and the
  stump variant defaults to `amputated` so the limb shows off.

## Monsters (monsters worker)

`scripts/monster.gd` keeps this public surface, which the game and the test bot rely on:
`static func new_monster(id: int, kind: String, pos: Vector3) -> CharacterBody3D`,
`static func roster(shift: int, player_count: int) -> Array[String]`,
`enum State { WANDER, CHASE, STUNNED }`, fields `monster_id`, `kind`, `state`, `damage`,
`knockback`, `calm`, `moving`, and methods `alert_to(pos)`, `shoved(dir)`,
`recoil_after_hit()`, `report() -> Dictionary`, `apply_remote(d)`.
Kinds: `"discharged"` and `"night_nurse"`.

Game-side API for monsters:

- `game.alive_players()`, `game.players`, `game.level_info`, `game.is_host()`
- `game.recent_noises(max_age := 1.5) -> Array` of `{pos: Vector3, loudness: float, kind: String, time: float}`
- `game.monster_hit_player(monster, player)` host
- `game.say(text, seconds)`
- `Perception.is_observed(game, point: Vector3) -> bool` in `scripts/perception.gd` (monsters
  worker): true when some living player has the point inside their camera view with clear
  line of sight AND the point is lit, by any player's flashlight cone or by a ceiling fixture
  that is currently on. Fixtures: `game.level_info["lights"]`, each `{position, mode, node}`
  where `node` is the fixture whose child `OmniLight3D` named `Bulb` carries the live energy.

Noise the game already emits on the host: footsteps (walk 0.25, sprint 0.8), containers 0.5,
pickups 0.15, drops 0.4, breaking glass 0.9, shoves 0.6, surgery monitors 0.6 while someone
operates.

### Monsters, sweep 3 (monsters worker): the Walk-In, fighting and capturing

Kinds: `Monster.WALK_IN` `"walk_in"`, `DISCHARGED`, `NIGHT_NURSE` (`Monster.KINDS`).

```gdscript
static func roster(shift, player_count) -> Array[String]  # Discharged/Nurse first (MAX_MONSTERS 5), then Walk-Ins
static func walk_in_count(shift, player_count) -> int     # 3 + shift + (players - 1), cap MAX_WALK_INS 8
static func walk_in_spots(level_info, count, rng, space = null) -> Array[Vector3]   # game._spawn_monsters uses it
static func is_capturable(kind) -> bool                    # walk_in, discharged
static func max_hp_for(kind) -> int                        # walk_in 2, discharged 4, night_nurse 0
static func display_name(kind) -> String                   # "Walk-In", "Discharged", "Night Nurse"
static func make_lying(kind) -> Node3D                     # = monster_model.gd make_lying (below)
enum State { WANDER, CHASE, STUNNED, SEDATED }             # modes.gd mirrors both enums; append only
enum Mode { IDLE, WANDER, LISTEN, RUSH, SEARCH, STALK, STUNNED, RETREAT, SEDATED }
var hp: int; var max_hp: int
var sedation_left: float      # host only
var dragged_by: int = 0       # set by combat; replicated
var hit_count: int            # bumps (mod 64) on every take_hit; replicated
func can_be_hurt() -> bool                                  # false for the Night Nurse
func take_hit(dir: Vector3, amount: int, source: String) -> String   # host: "stagger" | "killed" | "immune"
func can_sedate() -> bool                                   # capturable, not sedated, mode STUNNED now
func sedate(seconds: float) -> bool                         # host; false for the Nurse / already sedated
func is_sedated() -> bool                                   # every machine (clients read report "sd")
func wake() -> void                                         # host
func eye_transform() -> Transform3D                         # every machine: eyes on the animated head, -Z forward
```

- **take_hit**: hp -= amount; hp 0 returns `"killed"` and does nothing else (the caller calls
  `game.kill_monster(m)`). Otherwise a 0.7 s stagger (mode STUNNED, pushed 0.45 m along `dir`),
  after which it goes for whoever hit it (the nearest player within 3.5 m, else the side the blow
  came from): the Walk-In walks at them, the Discharged rushes the spot. A sedated monster takes
  the damage and stays down (`"stagger"`). The Night Nurse returns `"immune"` and nothing changes.
  Any stagger opens `can_sedate()` for its duration, like a shove (2 s).
- **sedate(seconds)**: mode and state SEDATED, the brain stops, it never hits anyone, it does not
  hear or see. On the host it first turns to the facing closest to its current one that leaves
  room to lie down (rays half its height each way), so a body never lies inside a wall. When
  `sedation_left` reaches 0 it calls `wake()`. Players never collide with monsters (their mask is
  the world only), so a sedated monster is not solid to them. Its collision capsule (layer
  `C.L_MONSTER`) lies down with it on every machine: along local Z, centred on the origin.
- **wake()**: stands up over 1.2 s (mode STUNNED), then hunts the nearest player (Walk-In: walks
  to where they are; Discharged: rushes them). If `dragged_by` is set it calls
  `game.combat.drop_dragged(dragger)` when combat has it, clears `dragged_by`, and hits the dragger
  (`game.monster_hit_player`) when they are within 3 m. Combat should not hit them a second time.
- **dragged_by != 0**: the brain does not think (host); every machine sets the monster's position
  to `game.combat.monster_pin(m).origin` and its yaw to the pin's -Z each physics frame when
  combat has `monster_pin` (otherwise clients keep interpolating the snapshot). The pin's tilt is
  ignored. The lying body is centred on the monster's origin along its local Z axis, head toward
  local **+Z** (behind its former facing), face up, about 0.13 m off the floor: a pin whose -Z
  points away from the dragger drags it head first.
- **The lying pose** plays on every machine from mode SEDATED (report `sd`): the model tips over
  backwards and settles in about 0.6 s; it gets up in about 0.9 s when `sd` clears.
- **Report** (`Monster.report`) adds `sd` (bool), `db` (peer id), `hc` (hit counter). `hp` and
  `sedation_left` stay on the host. Clients flinch and play `monsters_flesh_hit` when `hc` changes.
- **make_lying(kind)** (`scripts/monsters/monster_model.gd`, static): a still copy lying on its back
  along X, head toward -X, face up (+Y), origin at the middle of its back (the PatientBody
  convention). Lengths: Walk-In about 1.7 m, Discharged about 2.1 m. No IV pole. Rig-less
  fallback: primitives. Its node named `Head` follows the head bone. It keeps an AnimationPlayer
  frozen on the idle pose; do not free the skeleton. The shaper's optional cfg `lying_spread`
  (degrees, default 11) sets how far the arms lie out from the sides.
- **The Walk-In**: sight only (110 degree cone, 12 m, rays to the player's head then chest, walls
  block, light does not matter; 5 Hz, staggered; the ray count is in `brain.rays`). Wanders 0.8 m/s
  within 7 m of where it spawned, chases at 1.8 m/s straight at whoever it sees, keeps walking to
  the last sighting for up to 2.5 s after losing them, looks around about 3 s, gives up. Ignores
  every noise; `alert_to(pos)` sends it to look at `pos`. Hits for 1 on contact, then backs off
  and stays calm 4 s. Shove: 2 s stun. Height about 1.75 m, collision radius 0.36.
- **The Discharged**: about 2.1 m (collision capsule 2.1 m, radius 0.36), eyeless, ears on the
  large side of normal; `MonsterModel.set_ears(listen, yaw, delta)` swivels them toward `listen_yaw`
  and flares them while listening (every machine, from the report's mode and `ly`).
- **Placement** (`walk_in_spots`, host): hallway tiles (`.`/`M`, outside every room rect grown by a
  tile, not in a doorway's mouth) of each wing (`zone_of` == the wing id), at least 5 m from the
  entrance building and within 12 m of the wing's shallowest such tile; blocked tiles rejected
  with a sphere query when a physics space is given. Groups of 2-3 (4 when there are more
  Walk-Ins than wings can take), one group per wing while wings last, each within 3.5 m of a
  random shallow centre. Levels without `wings`/`zones`/`entrance_rect` (dev room, lab) group
  them around `monster_spawns`.
- **Shapes.bake(root, key)**: every part added through `MonsterModel.add_part` is merged into one
  mesh per material, cached per kind and part for the session (a Walk-In went from about 90 draw
  calls to about 6). Parts that move on their own must carry meta `no_bake` (the ears).
- Sounds (`tools/gen_audio_monsters.mjs`): `monsters_walkin_groan` (occasional, and when it first
  sees someone), `monsters_walkin_shuffle` (per step), `monsters_flesh_hit` (any struck monster),
  `monsters_walkin_death` (played by the dev room's `monster_died_fx` for a Walk-In),
  `monsters_sedated_breath` (every 3-4 s near a sedated monster).
- Tests: `tools/monster_lab.tscn` (headless scenarios 1-10: hearing, darkness, the Nurse, contact,
  roster, client mirrors, the Walk-In, hits/sedation/waking, dragging/lying copies, placement over
  generated hospitals), `-- --shots` (windowed close-ups into `tools/monster_shots/`), `-- --perf`
  (Walk-In frame cost, windowed; `-- --perf --nurses`: 0, 1 and 4 Night Nurses in view), `-- --real`
  (a bot in a generated hospital), and the nettest scenario `monsters`.

### The Night Nurse's model (2026-09-14)

Asset `monster/night_nurse` (`assets/models/monsters/night_nurse/`, built in Blender from
`art/night_nurse/`, see `ASSETS.md`): 2.30 m, feet at y 0, faces -Z after the registry's yaw 180,
clips `Idle`, `Walk` (in place, no root motion), `Frozen`. `MonsterModel.setup("night_nurse")` builds
it through `scripts/monsters/night_nurse_rig.gd`; without the asset she falls back to the reshaped
Kenney rig and `night_nurse_look.gd` (unchanged).

```gdscript
model.nurse                  # NursePoser (SkeletonModifier3D) or null; lunge, recoil, slump (0..1)
model.rig / skeleton / anim  # the GLB's root, Skeleton3D and AnimationPlayer (the lab and tests read anim)
model.play(logical, rate, blend)   # "idle" Idle, "walk"/"run"/"attack" Walk, "frozen"/"static" Frozen
model.hand_point(left)       # the hand.L / hand.R bone, world
model.eye_offset()           # eyes in the Head node's frame: (0, 0.134, 0.079) for her, (0, 0.13, 0.1) the rig looks
NurseRig.WALK_SPEED 1.0      # m/s at which Walk's planted foot keeps pace; rate = speed / WALK_SPEED
```

- A `BoneAttachment3D` named `Head` rides her head bone (`Monster.eye_transform`, the lab's head shots).
- `Monster._nurse_visual` (every machine, from the report): watched (`ob`) stops the clip on its frame
  (`anim.speed_scale = 0`) and holds every pose; moving (or lunging) plays Walk at `speed / WALK_SPEED`
  (0.3..4x) with the model lifted `WALK_LIFT` 3.5 cm; lunging adds the `lunge` reach; a calm that starts
  outside a retreat (a dev gun knock-down) throws her back (`recoil`, 0.6 s) and then holds `Frozen`
  while she stands down; otherwise Idle. Footstep squeaks follow the clip (0.8 s / speed).
- She never lies down, is never dragged, sedated or strapped (sweep 3 locked design), so she has no
  lying or dissection body. `make_lying("night_nurse")` returns her rest pose if anyone asks.
- The dev room's corpse (`dev_gun.gd monster_corpse`) shows her `Frozen` pose with `slump` 1.

## Medical guide (guide worker)

```gdscript
# scripts/guide/guide_ui.gd, a CanvasLayer the main scene creates
func open(page: String = "") -> void     # page: an item kind, "procedure:<ailment>", or "" for the index
func close() -> void
func is_open() -> bool
signal closed
# scripts/guide/guide_models.gd
static func make_book() -> Node3D        # the binder as a world object, origin at its base
static func make_lectern() -> Node3D     # visual only, origin at the floor
```

The main scene opens the guide when the local player presses R while holding the guide or
looking at it. While it is open the mouse is visible and the player cannot move; in co-op the
world keeps running.

## Hospital (hospital worker, sweep 2 wave 1)

`MapGen.generate(seed)` (`scripts/mapgen.gd`, parts in `scripts/level/`) lays out one floor:
an entrance building (28 x 20 tiles: main hall, break room, locker room, OR, scrub room, lobby),
three or four wings around it (`west`, `north` or `north_west` + `north_east`, `east`) and the
neutral area outside the main doors. `HospitalBuilder.build(gen, info)` builds it and fills
`info`. Maps without furniture data (hand-made tile maps, `tools/monster_lab.gd`) go through
`scripts/level/legacy_builder.gd` with the old keys only.

Tiles: `#` wall, `.` indoor floor, `+` doorway, `,` outdoor ground, `=` the fence, `P` player
spawn, `T` tool spawn, `M` monster spawn. Walkable: `. + , P T M`. Doorways are open (no door
leaves) and one tile wide; open rooms (nurse station, waiting room, cafeteria) have archways.

`level_info`, world metres, +Y up; positions are on the floor unless noted:

```gdscript
# kept from before
player_spawns: Array[Vector3]   # 4, in the break room (the current loop starts there;
                                # wave 2 moves the start to neutral.spawn_points)
tool_spawns, monster_spawns     # monster spawns: wing hallways only, never inside entrance_rect or the neutral area
table: Vector3                  # == tables[0].position, the first patient table; table_pos() still returns it
table_yaw: float                # the tables' long axis runs along X (0.0)
clock: Vector3                  # break room; clock_pos() unchanged (downed removed the Re-Gen Pod)
shelf, lectern: {position, yaw}; lectern_node
lights: [{tile, position, mode, node}]   # node's child OmniLight3D "Bulb"; street lamps and canopy lights are
                                         # included (mode 0) but are not in group "fixture" and never flicker
containers, loose_anchors       # see Containers; both carry wing and depth
rows, size, nav_region          # nav_region: one NavigationRegion3D over the whole map
# new
tables: [{position: Vector3, yaw: float, kind: "patient" | "player"}]   # 2 patient tables, then the player table, all in the OR
or_screen: {position: Vector3 (centre of the screen, on the OR wall, at its height), yaw (faces into the OR), size: Vector2 (2.2 x 1.3)}
phone: {position: Vector3 (the wall phone, at its height, on the break room wall), yaw (faces into the room)}
entrance: {position (just outside the main doors), yaw (faces out)}
entrance_rect: Rect2            # world XZ of the whole entrance building, walls included
ambulance: {position (by the canopy, where paramedics get out), yaw (faces the doors), vehicle: Vector3 (the parked ambulance)}
neutral: {spawn_points: [Vector3] (8, around the gold pile), shop: {position (the van's open rear), yaw (faces away from the van), vehicle},
          sell_bin: {position (the dumpster), yaw, front: Vector3 (where to stand)}, gold_pile: {position}}
neutral_rect: Rect2             # world XZ of the fenced neutral area
wings: [{id, rect: Rect2 (world XZ), depth: int, tile_rect: Rect2i}]   # depth 1 = shallowest; deeper = bigger area
rooms: [{id, kind, wing, depth, rect: Rect2 (world XZ, interior), tiles: Rect2i, doors: [Vector3]}]
zones: {grid, width, height, names}   # HospitalBuilder.zone_of(info, pos) -> wing id, "entrance", "neutral" or ""
```

- Room kinds: `or`, `scrub_room`, `break_room`, `locker_room`, `lobby` (wing `"entrance"`,
  depth 0) and `patient_room`, `supply_closet`, `pharmacy`, `nurse_station`, `waiting_room`,
  `restroom`, `office`, `lab`, `radiology`, `morgue`, `janitor_closet`, `cafeteria`. Anchors and
  containers outside rooms report `room_kind` `"corridor"` (wing hallways), `"entrance"` or
  `"neutral"`.
- Deeper wings are bigger (depth is ordered by area), darker (`MapGen.LIGHTS_WING`: fewer steady
  fixtures, more dead ones) and get more of the needed supply. The OR's fixtures are always on
  and brighter; entrance fixtures are mostly steady.
- Furniture is data (`gen.furniture`: kind, tile-space position, yaw, room), sized in
  `scripts/level/piece_defs.gd` and drawn by `scripts/level/piece_factory.gd` (Assets model or
  primitive) as MultiMeshes per 12-tile chunk. Pieces that `block` fill their tiles (the
  navigation mesh leaves them out). Other pieces only get a collider when they stand against a
  wall; a chair or plant in the open has none, so agents on the navigation mesh never snag.
  Wall corners have chamfered colliders.
- Monsters are placed only on wing hallways, but they still wander anywhere on the navigation
  mesh (`Monster.random_nav_point`). Keeping them out of the entrance or the neutral area is the
  loop's call (`zone_of` tells where a position is).
- Tests: `tools/mapcheck.gd` (hundreds of seeds: `MapGen.validate` plus builds with contract keys,
  navigation coverage, paths from the neutral area to the OR and every wing, every container and
  anchor in reach), `tools/spawncheck.gd`, and windowed screenshots with
  `godot --path . tools/hospitalshot.tscn --resolution 1280x720 -- --seed=N [--only=a,b]`.

### Pocket spaces (pockets worker, docs/POCKET_SPACES.md)

A map rolls 0-1 pocket space (`PocketPlan.CHANCE` 0.5; about 43% of seeds end up with one): **the Factory**
or **the Restaurant**, built far from the hospital (world tile origin `PocketSpaces.ORIGINS`: factory
(800, 0), restaurant (800, 500)) with 2-3 entrances into at least two different wings, deeper wings more
likely. Code in `scripts/level/pockets/`: `pocket_plan.gd` (generation), `stub.gd` (an entrance, its frame
and its pocket-side copy), `pocket_spaces.gd` (runtime, `game.pockets`), `pocket_common.gd`,
`factory.gd`, `restaurant.gd`.

```gdscript
# Generation (MapGen._attempt, before room kinds are chosen)
PocketPlan.plan(st, gens, defs, seed) / PocketPlan.release(gens)
PocketPlan.of(gen) -> {kind: "factory" | "restaurant", seed, stubs: [{id, wing, depth, zone, o: Vector2i, eu: Vector2i, ev: Vector2i, w, d, lights: [Vector2i]}]} or {}
PocketPlan.force_kind   # static: "" roll, "none", "factory", "restaurant" (tools, dev); force_entrances
PocketPlan.ZONE_STUB    # 10: the zone of stub tiles (HospitalBuilder.zone_of answers "")

# Runtime, every machine
game.pockets.build(gen, level_info, parent)   # after the hospital (doors: with each shift's wings)
game.pockets.build_kind(kind, level_info, parent, seed)   # no hospital entrances (dev room); nothing crosses
game.pockets.teardown()
game.pockets.active() -> bool; .pocket -> {kind, origin, rect (world XZ Rect2), root, spawn, wing, depth, layout, ...}
game.pockets.seams -> [{id, wing, depth, w, d, xh, xp (stub-local -> world frames), t (hospital copy -> pocket copy), t_inv, yaw,
                        link_h, link_p (NavigationLink3D ends), seam_h, seam_p, mouth, opening, link}]
game.pockets.space_of(pos) -> "" (hospital) | kind;  in_pocket(pos)
game.pockets.phantom_at(pos) -> [seam, to_pocket] or []    # standing in a stub's unwalked half
game.pockets.real_point(pos)       # a point in an unwalked half -> the same point in the other copy
game.pockets.steer_point(from, next)   # a path point past a seam link -> the same point on this side
game.pockets.mirror_noise(pos, loudness) -> [Vector3]      # host; game.emit_noise adds them
game.pockets.mirror_points(points) -> [Vector3]            # Perception: bodies inside a stub seen in the other copy
game.pockets.crossings -> [{what: "player"|"monster"|"item", id, seam, to_pocket, time}]   # this machine's moves
game.pockets.crossing_enabled      # tools only
```

- **An entrance** is a U-shaped hallway stub carved into one or two neighbouring room slots of a wing
  (stub-local tiles `u` 0..w-1 along the slot, `v` 0..d-1 away from the hallway; leg 1 at u 0..1 opens
  onto the hallway at v -1, leg 2 runs along the back, leg 3 at u w-2..w-1; `Stub.size_ok`: w >= 8 and
  `d - 2 - 4 / ((w - 4) / 2) >= 0.5`). The seam is the plane s = w / 2 across leg 2. The pocket copy is
  built from the same tiles in hospital coordinates under a Node3D with transform `t` (same vertices,
  UVs, materials, fixture seeds), on render layer `Stub.COPY_LAYER_BIT` (12), lit only by its own
  fixtures and copies of the hospital fixtures within reach of the stub (fixtures cast no shadows);
  pocket lights leave that layer out. Leg 3 opens into the pocket through its outer wall.
- **Crossing**: anything standing past the seam in its copy's unwalked half (hospital copy: s >= w/2;
  pocket copy: s < w/2) is moved through `t` / `t_inv`, keeping position relative to the stub,
  velocity and facing (players: `_yaw`, `bot_yaw`, `_knock`; monsters: `_target_*`, `_repath`; loose
  unfrozen items: transform and velocities). The local player and host bots move on their own
  machine; monsters and items on the host. A carried player and a dragged monster are re-pinned in the
  same frame. Remote players, monsters and items that jump more than 6 m between snapshots snap
  instead of lerping (`player.gd`, `monster.gd`, `world_item.gd`). The host accepts a client's position
  as always (no check).
- **Navigation**: the hospital's stub tiles past the seam are `blocked` (left out of its navigation
  mesh); the pocket bakes its own region (unwalked halves left out) and each seam has a bidirectional
  `NavigationLink3D` (travel cost about 1 m). `Monster.nav_move` maps the target with `real_point` and
  the next path point with `steer_point`, so a chase paths into the pocket, walks across the seam and
  continues; the test bots do the same.
- **level_info**: `pockets` = `{kind, rect, origin, spawn, wing, depth, seams: [{id, wing, depth, w, d,
  hospital, pocket, transform, mouth, opening, link}], nav_region}` (`{}` without a pocket); the pocket's
  `lights` (fixtures: node with a Bulb OmniLight3D), `containers`, `loose_anchors` (wing = the deepest
  connected wing, depth its depth; room kinds `factory_floor`, `factory_office`, `factory_catwalk`,
  `restaurant`, `restaurant_kitchen`) and `monster_spawns` are appended to the hospital's lists.
- **Air**: inside a pocket, away from its openings, `game.pockets` blends the environment's depth fog,
  volumetric fog density and ambient light toward `PocketSpaces.AIR[kind]` and back.
- **Mirrors**: players and monsters inside a stub are also drawn in the other copy (RenderingServer
  instances of their meshes, skeletons attached); `Perception.observed_any` checks the mirrored points
  too.
- Tests: `tools/mapcheck.gd` (every seed again with a pocket forced: plan, stub tiles, seams tile for tile
  both ways, pocket grid reachability; builds: navigation into the pocket and out through each seam,
  containers and anchors in reach), `tools/pockettest.tscn`, nettest `pockets`, `tools/gameshot.tscn --
  --pocket=factory|restaurant`, `tools/perfprobe.tscn -- --pockets`, devtest's pocket panel checks.

## Settings (settings worker, sweep 2)

`Settings` autoload (`scripts/settings.gd`, registered after `Audio`), persisted to
`user://settings.cfg` (section `settings`):

```gdscript
Settings.get_value(key)          # current value (defaults when unset)
Settings.set_value(key, v)       # clamps / validates, applies, emits, saves ~0.4 s later
signal changed(key: String, value)   # only when the value really changed
Settings.save_now()  Settings.reset_to_defaults()
Settings.use_path(p)  Settings.reload()   # test seams: point at a scratch file, re-read it
static func slider_to_db(v) -> float     # 0..1 slider to dB (squared amplitude, 0 = -80)
```

| Key | Type, range | Default | Applied by |
| --- | --- | --- | --- |
| `master_volume` | float 0..1 | 1.0 | Settings: `Master` bus |
| `music_volume` | float 0..1 | 1.0 | Settings -> `Audio.music_volume_db` (Audio drives the `Music` bus each frame) |
| `sfx_volume` | float 0..1 | 1.0 | Settings: `SFX` bus (`Ambience` sends into it) |
| `window_mode` | `"fullscreen"` (exclusive), `"borderless"`, `"windowed"` | `"windowed"` | Settings; skipped headless and when launched with a `.tscn` or window flags |
| `brightness` | float 0..1 | 0.5 | `main.gd` -> `Look.apply_brightness(root, v)` |
| `sensitivity` | float 0.2..3.0, multiplier | 1.0 | `player.gd` mouse look (`MOUSE_SENS * v`) |
| `fov` | float 60..100, vertical degrees | 78.0 | `player.gd` `apply_fov()`, local player camera only |
| `quality` | int 0..2 | 1 | `main.gd` `set_quality()`; migrated once from `prefs.cfg` `video/quality` |

- Anything new that should follow a setting reads `get_value()` when built and connects
  `changed`; do not write the config file yourself.
- Buses (`default_bus_layout.tres`): `Master`, `Hall` (reverb, -> Master), `Music` (-> Hall),
  `SFX` (-> Master), `Ambience` (-> SFX). New sounds go through `Audio.play()` (SFX bus); a
  player of your own must use bus `"SFX"` (or `"Music"`) so the volume settings reach it.
- `Look.apply_brightness(target, v)` bends the colour-grade ramp (a gamma on its input, keeping
  the shipped hue) and moves tonemap exposure by up to a quarter stop. 0.5 restores the shipped
  ramp and exposure 1.0 exactly. Code that replaces `adjustment_color_correction` or
  `tonemap_exposure` must re-apply brightness afterwards.
- `Player.apply_fov(deg)` sets the camera fov and CameraFX's `_base_fov` (the sprint kick adds on
  top) and moves the first-person `Hands` children and `HeldFirstPerson` so their x/y scale with
  `tan(fov/2)`. Anything new parented to the first-person camera should do the same (store its
  base position in meta `fov_base_pos`, or add it under `Hands`).
- `SettingsUI` (`scripts/settings_screen.gd`, a CanvasLayer at layer 6, child of Main):
  `open()`, `close()`, `is_open()`, `signal closed`. `Menu.chose_settings` opens it; while
  `game.paused` it shows its own "Settings" button under the HUD's PAUSED text. While open it
  eats keys and clicks except F2 / F3 / F11; Esc closes it (back to menu or pause).
- Tests: `tools/settingstest.tscn` (headless), `tools/settingsshot.tscn` (windowed screenshots to
  `tools/settings_shots/`, plus the mouse-look sensitivity check that needs a captured mouse).

## Dev room (dev worker, sweep 2 wave 1)

A secret level mode (`scripts/dev/**`). The session seed `SEED` (-4077, in
`scripts/dev/dev_room.gd`) *is* the dev room: `game.start_lobby` sets `game.dev_mode` from the
seed, so a client that joins builds the same room from the snapshot with no extra protocol.
The way in is deliberately not written down here.

Game API (host only; wave 3 `downed` changes what these do, not their signatures):

```gdscript
game.dev_mode: bool                      # every machine; true inside the dev room
game.dev: Node                           # scripts/dev/dev_room.gd, child "Dev" of Game, always present
game.damage_player(p, amount: int, source: String, knock := Vector3.ZERO)
    # every hurt goes here; monster_hit_player calls it. source: "monster:<kind>", "dev_gun:<name>"
game.knock_down_player(p, source: String, knock := Vector3.ZERO, seconds := 3.0)
    # downs the player at once (seconds is ignored); see "Downed players". The dev gun's secondary.
game.kill_player(p, source: String)      # dead until the next shift, downed or not; the dev gun's primary
game.kill_monster(m)                     # removes it for good; everyone sees it fall ("monster_killed" event)
game.knock_down_monster(m, dir := Vector3.ZERO, seconds := 4.0)   # Discharged stunned, Night Nurse calmed
```

Player fields added: `is_bot` (a dev bot or target dummy: a real Player the host simulates
through the `bot_*` seam, remote on clients, not in `Net.names`, negative id), `stun` (seconds
knocked down, no movement; a `"stun"` event plus the dev snapshot block), `noclip`.

- Bots live in `game.players` like everyone else. Code that iterates players must not assume
  every id is in `Net.peer_ids()` (the HUD party list uses the roster, so bots are not listed).
  `_sync_players` never removes an `is_bot` player.
- Snapshot key `"dv"` carries the dev state (`dev.net_state()` / `dev.apply_net_state()`), empty
  outside the dev room. Clients apply it before the player list so bot nodes exist.
- `game._event` passes kinds it does not know to `dev.on_event(kind, data)`.
- The room fills the level_info keys the game reads today (player/tool/monster spawns, table,
  table_yaw, shelf, lectern, lights, containers, nav_region) plus `dev_room: true`, `dev_gate`,
  `dummy_spots`. It has none of the wave 1 hospital keys (tables, or_screen, phone, entrance,
  neutral, wings): code using those must check for them.
- The room is always in `Phase.SHIFT` (no clock-in). A saved or lost patient clears the table
  a few seconds later (loop). The panel's "Phone call" calls `game.dev_phone_call()`; "Extra
  patient" and "Skip grace" call `game.dev_extra_patient()` / `game.dev_skip_grace()` (requests
  `phone`, `extra_patient`, `skip_grace`). "Put on the table" uses the first free patient table.
- `surgery_system.gd` lets an `is_bot` operator operate on the host with the minigame's
  `bot_input(t, skill)` (skill from the bot's meta `bot_skill`). Minigames must keep
  `bot_input` finishing their step.
- Interactables: `dev_disp_<item kind>` dispensers (endless stacks) and `dev_disp_dev_gun`.
- World changes from the panel or tests: `game.dev.request(action, args)`; the host applies,
  a client sends. Shots: `game.dev.fire(shooter, from, dir, "kill" | "knock")`.
- Sounds `dev_zap`, `dev_thump`, `dev_defib` from `tools/gen_audio_dev.mjs`.
- **Pocket spaces** (2026-09-14): request `pocket {kind: "factory" | "restaurant" | ""}` builds that space
  beside the room on every machine (`dv.pk`, `game.pockets.build_kind`); `dev.pocket_go(into)` moves the
  local player to its spawn and back (panel "Go there" / "Back to the room").
- **Night Nurse section** (2026-09-14): requests `nurse_ignore_watch {on}`, `nurse_walk {mode: "" |
  "follow" | "loop"}` (follow: the sender; loop: a 6 x 3.5 m rectangle round where the sender stands,
  long side along their facing, corners snapped to the navigation mesh) and `nurse_pace {i}`
  (`NURSE_PACES` 3.4 / 1.6 / 0.8 m/s); the panel's "Nurse in front" is `spawn_monster {night_nurse,
  front}`. Host fields `nurse_ignore_watch`, `nurse_walk`, `nurse_pace`, `nurse_who`, `nurse_loop`;
  the dv snapshot carries `nn: [ignore, walk, pace]`; `reset_state` clears them.
  `dev.nurse_settings() -> {ignore_watch, walk, who, loop, speed}` is what `Monster.dev_nurse()` hands
  the nurse brain (empty outside the dev room). Ignoring: `observed` stays false (so the report's `ob`
  and every client's clip keep running) and she does not stalk; follow stops at 2.5 m and walk modes
  never lunge or hit. The pace replaces her 3.4 m/s in every walk, hunting included.

## Inventory and money (inventory worker, sweep 2 wave 2)

Hands (`scripts/player.gd`; all host side except the reads):

```gdscript
Player.empty_slot() / Player.empty_slots()      # static: {kind:"",count:0} / C.CARRY_CAP of them
p.slot_free(i) -> bool                          # no stack and not a bulky second half
p.head_of(i) -> int / p.tail_of(head) -> int    # the stack a slot belongs to / a bulky stack's 2nd slot (-1)
p.selected_head() -> int / p.selected_stack()   # what G, the shelf, the sell bin act on
p.slot_for(kind) -> int / p.can_take(kind)      # bulky needs two free slots (bulky_pair())
p.take_into(kind, count, value := 0) -> int     # merge or place (both halves for bulky); -1 without room
p.clear_slot(i)                                 # empties a stack and its second half (pass either)
p.free_slot_count() / p.hands_empty() / p.holding(kind) / p.select_step(dir)
```

Anything that empties a slot must use `clear_slot` (or the host's `_fix_links()` tidies an orphaned
second half on the next tick). Code that spawns items out of hands must carry `s.v` into
`WorldItem.value`. Every hit, shove and knock-down still drops every stack through `_drop_hands`;
fragile loot of one cracks there instead (keeps `Game.LOOT_CRACK_KEEPS` of its value).

Items (`scripts/items.gd`): `Items.def(kind)` also answers loot kinds from
`scripts/economy/loot_table.gd` (kept out of `Items.ITEMS`, so the guide, the supply spawner and the
dev panel's supply lists do not list loot). New helpers: `is_loot`, `is_bulky`, `slots_needed`,
`stack_label(kind, count)`; `stacks()` now includes stackable loot.

Loot (`scripts/economy/`):

- `loot_table.gd`: `LOOT[kind]` `{name, short, value [min,max], tier 0..3, bulky, fragile, stack,
  batch, rooms {room_kind: weight, "*": any}, surfaces [...], containers {type: weight}}`, 21 kinds;
  `weight(kind, room_kind, depth)`, `roll_value(kind, depth, roll)` (+20% per depth).
- `loot_spawner.gd`: `plan(seed, shift, level_info, occupied) -> [{kind, count, value, container_id,
  slot, anchor, position?}]`, deterministic. Depth per location from the entry's `depth`, then a
  `level_info.rooms` or `level_info.wings` rect (tiles, or world metres when the rect is wider than
  the map in tiles, or `space: "world"`), else distance from the table. Safe rooms: `or`,
  `anteroom`, `clockin`, `break_room`, `entrance`, `lobby`, `neutral`, `outdoor`, `dev`.
- `game.spawn_loot()` (host) runs at clock-in (`game.clock_in()` and the `begin_shift()`
  shortcut), with the monsters; supplies come later, with each accepted patient.

Colour coding (`scripts/item_models.gd`): `ItemModels.make_tinted(kind, count, soft := false)`,
`apply_tint(node, kind, soft)`, `tint_material(kind, soft) -> Material` (teal for surgical, gold for
loot, null otherwise; one cached shader, applied as `material_overlay` on a model's 5 biggest
meshes). Use it for anything that shows an item in the world, in hands or on a shelf; minigames
keep the plain `make()`. `soft` is the fainter rim for first-person held stacks.

Money (host authoritative, replicated as `g.mn` / `g.gb`, survives `start_lobby`):

```gdscript
game.money: int                               # team money
game.gold_bars: int                           # bars bought this run
game.add_money(amount: int, reason: String)   # host; clamps at 0 unless reason starts with "debt:"
game.reset_money()                            # host; money and bars to 0 (game over; start_session calls it)
game.gold_bar_price() -> int                  # next bar: 100 + 5 * bars, rounded to $5
game.sell_selected(p) / game.buy_gold_bar(p) -> bool   # host; what the sell bin and shop call
game.economy                                  # scripts/economy/economy.gd, child "Economy"
game.economy.sell_bin / .shop / .pile         # nodes once placed (placed() true); positions helpers
game.economy.money_visible_for(p) -> bool     # HUD: near an economy spot, aiming at one, or just changed
```

Interactables `sell_bin` (sells the selected loot stack) and `shop` (buys one gold bar).
Placement, first match: `level_info.neutral {sell_bin, shop, gold_pile}` (attach: an aim box and a
sign around the level's own dumpster and van; the pile is lifted onto whatever is under
`gold_pile.position`), `level_info.economy` (same shape, built models; the dev room), else a
deterministic search for free floor around the time clock. Placement runs two physics frames after
`_add_landmarks`. The gold pile (`gold_pile.gd`) is a MultiMesh whose layout is a pure function of
the count and a height cap (indoors 2.6 m, then side columns). Sounds `economy_sell`,
`economy_buy`, `economy_bar` (`tools/gen_audio_economy.mjs`).

Dev room: `dev_disp_<loot kind>` cubbies (a rack on the south wall, `DispenserScript.create(kind,
true)`), `game.dev.request("money", {amount})` / `{reset: true}` (panel "Money" section), and
`level_info.economy` spots. Tests: `tools/inventorytest.tscn` (headless), `tools/inventoryshot.tscn`
(windowed shots to `tools/inventory_shots/`), nettest scenario `economy`, devtest inventory checks,
perfprobe `gold pile, 0 / 500 bars` and `--ab` rows `no item rims` / `loot hidden`.

## Shift loop and patients (loop worker, sweep 2 wave 2)

Cases (`scripts/game.gd`, host authoritative, replicated):

```gdscript
game.cases: Array          # each: {id, table (index into level_info.tables, -1 on the gurney),
                           #  patient_id ("bob"|"seal"|"player"), player_id (player cases), ailment_id,
                           #  step_index, flags, vitals, state ("incoming"|"on_table"|"stable"|"dead"),
                           #  optional (true for the extra patient)}
game.case_on_table(table_index) -> Dictionary   # any state but incoming; {} when free; the live dictionary
game.case_by_id(id) -> Dictionary
game.add_case(c) -> int         # host; defaults step 0, flags {}, vitals 100, state on_table with a table
                                # else incoming; -1 if that table holds a live case (a finished one is replaced)
game.finish_case(id, won)       # host; stable (stays on its table) or dead (flatlines, vitals 0)
game.remove_case(id)            # host
signal cases_changed            # every machine: added, removed, onto a table, step, state (not vitals)
game.case / game.vitals / game.patient_body   # aliases of the first non-player case
game.patient_tables: [{index, position, yaw}] # the kind "patient" tables
game.surgeries                  # one surgery system per patient table, same order
game.surgery                    # the one the local player operates at (or is blending back from), else the first case's
game.surgery_for_table(i) / body_for_table(i) / table_position(i) / table_yaw_of(i)
game.table_interact_id(i)       # "table" for the first patient table, "table_<index>" for the others
game.free_patient_table() -> int   # no case and no paramedics heading there, or -1
game.end_operations(p)          # host: p steps back from every table
game.spawn_supplies_for(c)      # host: the first case gets ItemSpawner.plan; later ones a shortfall top-up
```

- Vitals drain only while `on_table`. Player cases (`patient_id "player"`) get no PatientBody, no
  surgery system, no drain and no pay from this code: the `downed` worker owns them.
- Levels without `level_info.tables` (the dev room, the fallback ward, old tile maps) get the
  level's `table` plus a second table built beside it (`scripts/loop/tables.gd`, deterministic);
  `level_info.tables` is then filled with both and `tables_fallback` set.

The loop (`scripts/loop/shift_loop.gd`, `game.loop`, child "Loop"):

```gdscript
game.clock_in()                 # host: LOBBY -> SHIFT: loot, monsters, grace period (the clock's hold calls it)
game.begin_shift()              # host, tools: clock in and put the first patient straight on a table
game.finish_shift(text, secs)   # host: the paycheck screen (Phase.WON), then the next shift's lobby
game.game_over(text)            # host: Phase.LOST, then game.reset_money() and a new run (new seed, shift 1)
game._end_shift(won, text)      # tests: won = forced clock-out, else game over
game.dev_phone_call() / dev_extra_patient() / dev_skip_grace()
game.monster_may_wander_to(p) -> bool   # false inside the entrance building or the neutral area (zone_of)
loop.grace_left, call_kind ("first"|"extra"), call_state ("ringing"|"talking"), subtitle, first_called,
  crews {case id: {p, y, ph "in"|"hand"|"out", pt, ai, tb}}, pay_note     # replicated as g "lp.*"
loop.start_call(kind) / answer(p) / clock_out(force) / can_clock_out() / skip_grace()
loop.objective_text() / missing_supplies() / clock_prompt(p) / phone_prompt()
loop.force_first / force_extra = {patient_id, ailment_id}   # tests pin what the calls bring
loop.pay_for(case, shift) -> int   # stable 200 (+25/shift), extra stable 300 (+40/shift), dead -150
```

- Players start a run at `level_info.neutral.spawn_points` (else `player_spawns`): `game.spawn_points()`.
- Clock in, `GRACE_SECONDS` (60), then the phone rings. E on interactable `phone` answers (subtitles
  for everyone); after `AUTO_ANSWER_SECONDS` (8) the answering machine takes it. Taking the call
  adds the case (`incoming`) and spawns its supplies; `DISPATCH_DELAY` (3 s) later a crew leaves
  `level_info.ambulance` (else `entrance`, else the spawn farthest from the table), walks the
  navmesh to a free patient table, hands over (state `on_table`) and walks back.
- 45 to 150 s after the first patient is on a table the phone rings with the optional extra patient
  (a different patient); answering accepts, `EXTRA_DECLINE_SECONDS` (20) of ringing declines.
- The clock allows clocking out once the first call was taken and no case is incoming or on a
  table (a ringing extra call is declined by clocking out). Pay goes through `game.add_money`
  (a dead patient's penalty clamps at $0). Monsters are removed at clock-out.
- **Next shift: same hospital.** The seed stays for the whole run; `shift` goes up. At the next
  clock-in the items the spawners left and nobody touched are removed, containers close, and loot,
  monsters and (per case) supplies spawn fresh from `seed + shift`. Nobody is moved and hands are
  kept at the next lobby; the dead and late joiners get up at the start. Game over builds a new
  hospital (`seed + 7919`). Clients learn the phase from `_rpc_shift`/snapshots and move themselves.
- Game over: during a shift, `game.all_players_out()` (downed worker: every non-waiting player is
  downed or dead). Never in the dev room. At the next shift's lobby the dead and the downed get
  up at the start.
- The player table (downed worker): the stitches operation stays in
  `scripts/downed/player_surgery.gd`; the host mirrors it into `game.cases` every tick as a
  `patient_id "player"` case with `mirror: true`, `table = game.player_table_index()` (the "player"
  entry of `level_info.tables`, appended on fallback levels once the player table is placed),
  `player_id`, `ailment_id "stitches"`, `step_index`, `flags`, `vitals` (the bleed clock) and state
  `on_table` (`stable` once the step is done). It gets no PatientBody, drain, pay or clock-out
  rule from the loop; it exists so it replicates with the cases and the OR monitor lists it.
- The phone: on a level with `level_info.phone` at wall height the loop adds the aim target, a
  blinking lamp and a glow to the hospital's wall phone; otherwise it builds a desk phone on a side
  table near the clock. Sounds `loop_ring`, `loop_pickup`, `loop_hangup`, `loop_gurney`,
  `loop_siren`, `loop_clockout` (`tools/gen_audio_loop.mjs`).
- Tests: `tools/looptest.tscn` (headless, the whole loop), `tools/playtest.tscn` (the loop,
  `--extra`, `--skip-grace`), `tools/loopshot.tscn` (windowed shots to `tools/loop_shots/`),
  devtest's loop hooks, nettest `deliver`, `surgery`, `late_join`, `full_shift_lag`, `economy`
  (loot kept through a shift) and `two_patients`.

## Models (loot and paramedic models, sweep 2 integration)

`scripts/assets.gd` entries may now carry `pitch` / `roll` (degrees, applied before `yaw`),
`size` (longest side in metres) or `height` (metres) — either makes `spawn()` measure the model
once and put its base on the floor, centred — plus `hide` (mesh node names to skip) and `albedo`
(a replacement colour texture). New helpers: `Assets.fixup(key) -> Transform3D` (what `spawn()`
applies) and `Assets.measure(key, xf) -> AABB`. Keys: `item/<loot kind>` for 15 kinds,
`item/sample_tube`, `crew/paramedic_a`, `crew/paramedic_b`, `mat/xray_film`. Assets starts
threaded loads of every `item/*` and `crew/*` file in `_ready`.

`scripts/item_models.gd`:

```gdscript
ItemModels.asset_mesh(kind) -> ArrayMesh      # the kind's shared real-model mesh, or null (primitive)
ItemModels.asset_transform(kind) -> Transform3D   # what that mesh is drawn with (identity when merged)
ItemModels.merge_parts(parts, tri_budget) -> ArrayMesh  # [[Mesh, surface, Transform3D, Material]]:
                                              # one surface per material, decimated, compacted, LODs
ItemModels.primitives_only                    # static, tools only: build everything from primitives
```

`make()` / `make_tinted()` / `footprint()` keep their contracts; `footprint()` of a non-stacking
kind with a model is the model's measured size. A model stack is one `MeshInstance3D` per copy
sharing the mesh (the rim goes on it). `LootModels.asset_extras(kind) -> {copies, parts, recolour}`
adds details to a kind's merged model (economy visuals).

`scripts/loop/crew.gd`: the medics are `crew/paramedic_*` models animated by an `AnimationTree`
(idle/walk blend by speed, the back medic's arms from "holding-both"), with the capsule figures as
the fallback; the crew has an `AnimatableBody3D` "Blocker" on `C.L_WORLD` (mask 0) that anything
building a look-alike crew must remove (the warmup does). `CrewScript.shapes_only` (static, tools
only) forces the capsule medics. The fallback levels' desk phone (`phone.gd` `create(false)`) uses
the `desk_phone` loot model when it exists.

## OR screen and minimal HUD (orscreen worker, sweep 2 wave 3)

The OR wall monitor (`scripts/orscreen/`) is derived locally on every machine from state that is
already replicated (`game.cases` or `game.case` / `game.vitals`, `game.shelf`, the surgery
operator); it adds nothing to the snapshot.

```gdscript
game.or_screen                          # scripts/orscreen/or_screen.gd, child "ORScreen" of Game
game.or_screen.mounted() -> bool        # a monitor exists in the current level
game.or_screen.placement                # "level_info" | "wall" | "floating"
game.or_screen.screen_centre() / screen_normal()   # world; the glass faces screen_normal()
game.or_screen.model                    # the last model drawn (see below)
game.or_screen.refresh_now()            # rebuild and redraw at once
game.or_screen.set_enabled(on)          # hide it and stop refreshing (perf A/B)
game.or_screen.model_override = {...}   # test seam: draw this model instead of the game's
OrScreenModel.build(game) -> Dictionary # scripts/orscreen/or_screen_model.gd, pure
```

- Placement: every new `game.level` gets a monitor two physics frames later, at
  `level_info.or_screen` (centre of the glass on the wall, `yaw` facing -Z into the room, as the
  hospital builds it; the glass is laid onto the hospital's own `or_screen_mount` piece), else on
  the flattest wall facing the tables found by ray casts (the dev room), else floating near the
  table.
- Model: `{mode: "idle" | "cases", phase, shift, lobby, panels: [{id, table, patient_id,
  patient_name, ailment_id, ailment_name, code, state, vitals, level: "ok" | "low" | "critical",
  steps: [{label, item, item_name, state: "done" | "current" | "todo"}], current, supplies:
  [{kind, name, need, have, ok}], ready, operator, progress}]}`. Supplies are
  `Procedures.remaining_requirements` against the shared shelf, handed out to cases in order
  (tools are not used up). Cases come from `game.cases` (the `loop` contract in `docs/SWEEP2.md`)
  when that exists, else the legacy single case; player cases show the Player's name. The operator
  comes from `game.surgery_for_table(table)` when the game has it, else `game.surgery` for the
  first case.
- Cost: the SubViewport renders only on request, at 12 Hz within 7 m and 5 Hz beyond, and never
  while the glass is out of the live camera's view or past 22 m. Its OmniLight (`Glow`, energy
  0.16, green / amber / red from the worst case) re-tints at 4 Hz. Registered in `Warmup`.
- HUD (`scripts/hud.gd`): only the slot bar, crosshair + interact prompt + hold progress, the
  player's hearts (+ stamina while not full), messages and the dead banner, the money readout, the
  first-seconds controls line, the lobby host address and the pause / end overlays. `hud.drawn`
  lists the element ids the last frame drew. Anything new about the case, the steps or supplies
  belongs on the monitor, not the HUD.
- Surgery HUD (`scripts/surgery/surgery_hud.gd`): the operator sees one slim strip, step n/N and
  title, the patient's vitals as a number (`case.vitals` of the system's own case when it has
  one), the one-line hint and "Esc / E: step away". Gauges and the progress bar are gone;
  `cross_section` is still drawn above the strip when a minigame returns it. Spectators keep the
  small "X is operating" line.
- Work lamp: `SurgerySystem.make_work_lamp()` and the `LAMP_*` constants in
  `scripts/surgery/surgery_system.gd` (energy 0.5); the minigame lab uses the same function.
- Tests: `tools/orscreentest.tscn` (headless shift + synthetic cases),
  `tools/gameshot.tscn -- --only=orscreen [--tag=1600]` (shots 11-20),
  `tools/perfprobe.tscn -- --orscreen` (OR view and close-up with the monitor on and off) and the
  perfprobe `--ab` row `no OR screen`.

## Downed players (downed worker, sweep 2 wave 3)

0 HP downs a player; nothing a hit does kills. The Re-Gen Pod is gone (no `pod`, `pod_pos()`,
`C.POD_SECONDS`, `level_info.pod` or `regen_pod` piece). All host authoritative; the Player fields
ride in `report_full` (`dn bl cb ca ot ch`).

```gdscript
# Player (scripts/player.gd)
p.downed: bool            # alive but not standing: lies down, crawls (CRAWL_SPEED), no sprint, E only calls for help
p.bleed: float            # seconds left; every machine runs it (game.bleed_rate), the host's is the truth
p.carried_by: int         # carrier's peer id, 0 = nobody; the body is pinned to game.pinned_pose(p)
p.carrying: int           # carried player's peer id; carrier moves at CARRY_SPEED_K, cannot shove, drop or use things
p.on_table: bool          # lying on the player table, pinned there, looking up
p.carry_hold: float       # seconds this player has held E on a downed teammate (HUD "LIFTING")
p.downed_aim              # Area3D "DownedAim", interact_id "pl_<peer id>", on C.L_INTERACT only while lying free
p.refresh_downed_visuals() / p.look_up_from_table()

# Game (scripts/game.gd)
game.BLEED_SECONDS (300)  game.TABLE_BLEED_K (0.5)  game.CARRY_HOLD (1.0 s)  game.REVIVE_HP (2)
game.alive_players()      # standing players only (alive and not downed): monsters, footsteps, perception, holds
game.all_players_out() -> bool     # every player not waiting to join is downed or dead; fails the shift outside the dev room
game.down_player(p, source, knock := Vector3.ZERO)   # host; damage_player calls it at 0 HP
game.kill_player(p, source)        # host; "bleed" when the clock runs out
game.revive_player(p, source := "stitches")   # host; REVIVE_HP, standing beside the player table
game.can_pick_up(q, p, check_hands := true) -> bool
game.start_carry(q, p) / game.drop_carried(q) / game.place_on_player_table(q)   # host
game.carrier_pressed_interact(q, aim_id) / game.downed_call_out(p)             # host, from Player._consume_actions
game.player_table          # {position (floor), yaw, top}; {} until placed two physics frames after the level
game.player_table_top() -> Vector3 / game.player_table_yaw() -> float / game.pinned_pose(p) -> Transform3D
game.start_player_surgery(p)       # host: the stitches case on the player on the table
game.player_surgery        # scripts/downed/player_surgery.gd, child "PlayerSurgery" (case, patient(), surgery, operate_prompt(q))
game.surgery_camera() / surgery_wants_mouse() / surgery_local_exit()   # either table; main.gd and hud.gd use these
game.spawn_suture_kits()   # host, in begin_shift after the supplies: SUTURE_KITS_PER_SHIFT stacks of 1-2
game.downed_view           # scripts/downed/downed_view.gd: blood trails, the local vignette and bleed clock
```

- Damage: `damage_player` ends operations, drops hands, drops whoever the victim carries, and at 0 HP
  calls `down_player`. Shoving a carrier drops the carried player. Monsters never hit a downed player.
- Carrying: aim at a downed teammate (`pl_<id>`) with empty hands and hold E for `CARRY_HOLD`
  (simulated by the host from `wants_interact` + `aim_id`). E again puts them down in front (a
  reliable `placed` event tells the downed machine where, since it owns its position); E aimed at
  the `player_table` proxy lays them on it. The carried body rides the right shoulder; the carried
  player's camera hangs a metre behind that point.
- Player table: `level_info.tables` entry with `kind == "player"` (the hospital's), else a clear spot
  2.7-3.4 m from the OR table; a table model (`scripts/downed/player_table.gd`) is built only when
  nothing is under the spot. Aim proxy `player_table` (prompt "Place X on the table", or the stitches
  operation's prompt).
- Stitches: `Procedures.AILMENTS.stitches`, one step `{id: "stitch", item: "suture_kit", uses: 1,
  game: "stitches", site: "gash"}`, needing a kit on the shared shelf. The case
  `{patient_id: "player", player_id, ailment_id: "stitches", step_index, flags}` and the operation's
  net state ride in the global snapshot field `pt`. Its vitals are the patient's bleed clock
  (100 = five minutes); a botch costs `BOTCH_BLEED_SECONDS` (4) per point. The finished step revives
  the patient 1.2 s later. Replace with `game.add_case` in the integration wave.
- Player body (`scripts/downed/player_body.gd`, `create(peer_id, colour)`): lying along X, head toward
  -X, origin at the table top; site `gash`; `site_transform`, `has_site`, `site_section("gash") ->
  {half_len, half_gap}`, `set_bleeding`, `stir`, `set_vitals`, `apply_flags` (`stitched` shows the
  scar), `show_gash(on)` (the minigame hides the painted gash while it draws its own), plus
  `infection_start` (INF) and `make_severed_limb` (null) for the patient-body surface.
- Stitches minigame (`scripts/surgery/games/stitches.gd`): six stitches, each a click on the green ring
  outside one edge then on the ring across; amber = loose (closes less, oozes), red = torn skin
  (1.5) or a stab into the open wound (2.5). Net state `s h fq q c pu b bt be st p`. Self-test
  `--selftest=stitches`; the lab runs it on a player body with `--game=stitches`.
- Dev room: `game.dev.request("down_me", {id?})` (the panel's "Down me" and each bot row's "Down"),
  a carry order with `to: "table"` ("downed to table") lifts the nearest downed player and lays them
  on the player table, and the operate order stitches up whoever lies there first (stocking a kit).
  `dev_level` adds a player table south of the OR table.
- Sounds `downed_fall`, `downed_call`, `downed_lift`, `downed_stitch`, `downed_tug`
  (`tools/gen_audio_downed.mjs`).
- Tests: `tools/downedtest.tscn` (headless), `tools/downedshot.tscn` (windowed shots into
  `tools/downed_shots/`), nettest scenario `downed`, devtest downed checks.

## Combat (combat worker, sweep 3)

`scripts/combat/combat.gd`, `game.combat` (child "Combat" of Game, every machine). The design is
`docs/SWEEP3.md` "Combat"; this is what the code guarantees.

```gdscript
SAW_BREAK_CHANCE 0.12  SWING_COOLDOWN 0.8  SAW_REACH 2.0  SEDATE_SECONDS 75.0  JAB_COOLDOWN 1.0  JAB_REACH 1.8
DRAG_HOLD 1.0  DRAG_SPEED_K 0.55  DRAG_BEHIND 1.15  JAB_KNOCKOUT 8.0  NOISE_HIT 0.9  NOISE_SWING 0.3
game.combat.is_usable(kind) -> bool          # "bone_saw", "anesthetic"
game.combat.use(p)                           # host, the old use_count path: starts a jab / saw wind-up
game.combat.local_try_use(p) -> bool         # the clicking machine: starts the jab / saw wind-up (own cooldown)
game.combat.local_shove_begin(p) -> bool / local_shove_release(p)   # the shoving machine: Q or left mouse down / up
game.combat.action_of(p) -> {} or {k, ph, t, u, charge, c}   # every machine: the wind-up state the hands draw
game.combat.is_winding(p) -> bool            # winding up or charging: walk speed, no sprint, no slot change, no drop
game.combat.cancel_windup(p, why)            # host: game.damage_player, player_shoved (the victim), knock_out call it
game.combat.strike_shove(p, c)               # host: game.player_shoved(p, c) at the shove's strike
game.combat.monster_shoved(m, c)             # host, from game.player_shoved: a stunned capturable monster's window
game.combat.stun_pose(m, shaper, lying)      # Monster._update_visual hook: the stun window's pose
game.combat.jab_prompt(p) -> "" or "[Click] Jab it"   # Player._update_aim: holding anesthetic at a stunned monster
game.combat.windup                           # scripts/combat/windup.gd (constants and state, below)
game.combat.stun_window                      # scripts/combat/stun_window.gd
game.combat.find_target(p, reach, cone_deg) -> {node, kind: "monster"|"player", point, dist} or {}
game.combat.knock_out(q, seconds)            # host: the teammate jab (hands drop, stun + "stun" event)
game.combat.is_sedated(m) / can_sedate(m) / sedation_left(m)   # guarded monster API
game.combat.dragging(p) -> int               # monster id, -1 none (Player.dragging_monster, report key "dm")
game.combat.dragger_of(m) -> Player or null  # every machine
game.combat.monster_pin(m) -> Transform3D    # every machine, see below
game.combat.can_drag(q, m, check_hands := true) / start_drag(q, m) / drop_dragged(p)   # host
game.combat.dragger_pressed_interact(q, aim_id)   # host, from Player._consume_actions while dragging
game.combat.strap(q, table_index) -> case id # host
game.combat.table_index_for(interact_id) / strap_problem(table_index) -> "" or why not
game.combat.animate_held(p, delta, fp, tp)   # kept as a no-op (the hands animate themselves)
game.combat.last_result / swings_seen / rng / break_chance / anim_freeze / pose_at(p, k, ph, t, c) / stop_anim(p) / set_sedation_left(m, s)   # tests, tools
```

- **Saw** (host): a cone of 38 degrees around the aim from the eyes (yaw from `rotation.y`, pitch
  from `head.rotation.x`), the nearest monster or standing player within `SAW_REACH` plus its
  radius, with a clear line (`C.L_WORLD`). Monster: `take_hit(dir, 1, "saw:<name>")`; `"killed"` ->
  `game.kill_monster(m)` (pays nothing); `"immune"` -> `combat_clang`. Player:
  `game.damage_player(q, 1, "saw:<name>", knock)` unless invulnerable or in god mode. Every
  connecting hit (the Night Nurse included) rolls `breaks()`; a snap clears the saw's slot, plays
  `combat_snap` and says "X's bone saw snapped.". Noise 0.9 at the hit (kind "saw"), 0.3 through
  air ("swing").
- **Jab** (host): a 30 degree cone within `JAB_REACH`. A teammate: one vial, `knock_out(q, 8)`. A
  monster that is not capturable (the Night Nurse): nothing used, "The needle will not go in.".
  Already sedated: nothing. `can_sedate(m)`: one vial and `sedate(SEDATE_SECONDS)`. Otherwise
  nothing used, `m.alert_to(p)`, "It shrugged off the needle.".
- `use` is refused while downed, stunned, carrying or carried, dragging or operating. The host
  cooldown is 0.8 x the item's cooldown; the clicking machine enforces the full one.
- **Drag**: every monster gets an `Area3D` child "CombatAim" (interact_id `mo_<id>`, a 0.9 x 0.7
  x 2.1 box centred 0.35 m up, in the monster's own space), on `C.L_INTERACT` only while
  `is_sedated(m)` and nobody drags it. Hold E for `DRAG_HOLD` with empty hands (host-simulated like
  carrying; progress shows through `Player.carry_hold`). While dragging the player walks at
  `DRAG_SPEED_K`, cannot sprint, shove, use, drop or change slots, and `_update_aim` offers only
  `Strap the X to the table` on a free patient table (aim id = the table's interact id) or `Put
  the X down`. Hit (`damage_player`), shoved, knocked out, downed, dead or gone: the monster is let
  go where it lies. Waking while dragged (`is_sedated` false): dropped, turned to the dragger,
  `alert_to`, `game.monster_hit_player(m, q)`.
- **`monster_pin(m)`**: origin on the floor under the middle of the body, `DRAG_BEHIND` behind the
  dragger; basis = the dragger's yaw, so the pin's -Z points at the dragger and the body lies along
  Z, feet toward -Z, head toward +Z. Not dragged: the monster's own transform. A monster with a
  `dragged_by` field places itself there every frame on every machine; `start_drag`,
  `drop_dragged` and `strap` set and clear `m.dragged_by`, and combat clears a stale one.
- **Strap**: `strap_problem(ti)` is "" in `Phase.SHIFT` with no case on the table and no crew
  heading there. The case is exactly `game.add_case({table, patient_id: m.kind, ailment_id:
  "dissection", monster: true, flags: {sedation: lerp(0.35, 1.0, sedation_left / 75), snapped to
  0.01}})`; then `game.monsters.erase(id)`, `on_monster_removed(m)`, `m.queue_free()` (no death
  effect, no `monster_killed` event), `combat_strap` and "X strapped the Y to the table.".
- **Wind-ups** (hands sweep, `scripts/combat/windup.gd`, every machine): every shove, jab and saw
  swing goes WINDUP -> STRIKE -> RECOVER. `WINDUP_TIME` jab 0.35 s, saw 0.3 s; the shove charges
  while held: `SHOVE_MIN` 0.2 s (a tap), full at `SHOVE_FULL` 0.9 s, fires by itself at `SHOVE_MAX`
  1.5 s; charge `c` = (held - 0.2) / 0.7 clamped. `STRIKE_TIME` shove 0.16 / jab 0.18 / saw 0.22,
  `RECOVER_TIME` 0.36 / 0.32 / 0.36. The hit resolves on the host **at the strike** (`_swing`,
  `_jab`, `strike_shove`), so the target is checked then (a monster that got up during a jab's
  wind-up shrugs it off). Cooldowns (unchanged values) start at the strike, and at a cancel. While
  winding: walk speed, no sprint, no slot change, no drop. Hit, shoved, knocked out, downed, stunned,
  carried, carrying, dragging, operating or in Hive Eyes: the host cancels with no strike.
- **Shove** (`game.player_shoved(p, charge := -1.0)`): charge 0 (a tap) is the old shove (2 s stun);
  a charged shove stuns a capturable monster `lerp(2.0, 3.5, c)` s with `lerp(1.05, 1.9, c)` m of push
  (`Monster.shoved(dir, charge)`) and knocks a player back `lerp(11, 16, c)`; noise `0.6 + 0.25 c`.
  -1 is the instant shove the `Player.shove_count` counter still triggers (tests, old callers).
  Wind-ups emit noise 0.3 ("windup") and a charging shove 0.3..0.65 ("charge") every 0.4 s.
- **Network**: the owner starts the wind-up on the input and calls the reliable RPCs
  `Combat._rpc_windup(k, seq)` / `_rpc_release(seq, held)` (client -> host; a host-local player or bot
  calls `host_begin` / `host_release` directly). The host refuses (busy, cooling down, wrong item) with
  `cb_cancel`, else broadcasts `cb_windup {id, k, s}`; at the strike `cb_swing {id, k, s, c}`; a cancel
  `cb_cancel {id, s, cd}`. The shove's held seconds are capped to `min(claim, host-measured time
  between the two events + HOST_CHARGE_SLACK 0.3, SHOVE_MAX)`; a held shove the host never hears
  released fires at `SHOVE_MAX + 0.4`. Others show at least `MIN_SHOWN_WINDUP` (0.15 s) of a wind-up
  whose strike arrived in the same frame. `cb_stun {m, s}` starts a monster's stun window on every
  machine. `net_state()` (`g.cb`) is `{}` or `{s: [monster ids]}` (the fallback sedated set only).
  Drags ride in `Player.report_full` as `dm`. Nothing else crosses the wire (the carry camera is local).
- **Stun window** (`stun_window.gd`): from the host's shove to `s` seconds later: stagger pushed 1.7x
  for 0.3 s, then down (RigShaper `daze` 1: knees buckle, slumped, head hanging, arms dangling),
  `hands_dazed` every 1.25 s within 22 m, and for the last `RISE_WARNING` 0.6 s `rise` 0..1: it
  jerks upright with `hands_rise`. No HUD; holding anesthetic at a jabbable monster the crosshair
  prompt reads "[Click] Jab it" (`hud.gd` shows prompts that start with "[" as they are).
- Wind-up sounds (`tools/gen_audio_hands.mjs`): `hands_windup_01/_02` (quiet at the player for
  teammates), `hands_charge` (rising, stopped at the strike), `hands_full` (the charge maxed).
- Sounds (`tools/gen_audio_combat.mjs`): `combat_swing_01/_02`, `combat_jab_swish`,
  `combat_hit_01/_02`, `combat_clang`, `combat_snap`, `combat_jab`, `combat_needle_fail`,
  `combat_drag`, `combat_strap`.
- Tests: `tools/combattest.tscn` (headless, dev room; wind-up cases at the end),
  `tools/combatshot.tscn` (windowed shots to `tools/combat_shots/`), `tools/carrycamtest.tscn`,
  `tools/gameshot.tscn -- --only=hands`, nettest scenario `combat` (wind-ups seen before strikes,
  the capped charge).

## Player: hands, poses and the carry camera (hands worker, 2026-09-14)

```gdscript
ItemModels.grip(kind) -> {pos, fwd, up, style: "palm"|"fist", hands: 1|2, bundle}   # scripts/hands/grips.gd
Grips.grip_transform(kind) / transform_of(g) -> Transform3D   # the model in socket space
Grips.shown_count(kind, count)               # a batch shows at most `bundle` copies in a hand
p.hands                                      # scripts/hands/fp_hands.gd, node "Hands" under the camera (local)
p.hands.fov_k / pose_l / pose_r / arm_l / arm_r / held_changed(kind, count) / static dress(node)
HandsFP.HANDS_LAYER (1 << 18)                # hands and held first-person stacks; the flashlight skips it
p.body_hands                                 # scripts/hands/body_hands.gd: clips, pose overrides, hand sockets
p.body_hands.hand_r / hand_l                 # BoneAttachment3D on the arm bones
p.body_hands.set_active(on) / has_rig()
p.carry_cam                                  # scripts/camera/carry_camera.gd, local player only (else null)
p.carry_cam.active / blend / offset / arm_length / hides_hands() / aim_segment()
p.bot_charge                                 # test seam: true holds the shove, false lets go
Settings "carry_camera": "shoulder" (default) | "first_person"
```

- **Socket axes** (every hand, first and third person): origin in the palm, -Z the fingers, +Y out
  of the palm, +X the hand's right. A grip maps the model's `fwd` to -Z and `up` to +Y with `pos` in
  the palm. "palm" things lie on an open, palm-up hand; "fist" handles (saw, forceps, reflex hammer,
  thermometer, otoscope) sit in a closed hand, thumb up. `hands: 2` (bulky loot, the guide) sit
  between both palms. `HeldFirstPerson` (`Head/FX/Camera/HeldFirstPerson`) and `HeldThirdPerson`
  (`Body/HeldThirdPerson`) keep their paths: each frame they are moved onto the socket, and their
  child `Held` carries the grip transform (first person: two-handed things fit 0.22 m, big loot
  0.13 m; third person two-handed things 0.55 m).
- **First person**: right hand the torch (thumb up), left hand the selected stack; two-handed things
  take both hands and the torch tucks down at the right. Poses (camera space, `hand_poses.gd`) blend
  the wind-up / strike / recover of `combat.action_of`; walk bob, sway lagging the mouse, a 0.38 s
  lower-and-raise when the selected kind changes, lowered while sprinting, pulled back up to 0.17 m
  when a short ray fan (every 0.05 s) finds a wall within 0.62 m. x/y scale with `fov_k`
  (`Player.apply_fov`).
- **The arms seam**: `fp_arms.make_arm(side, colour) -> Node3D` is the only builder: origin at the palm
  socket, sleeve toward +Z, optional children `Rig/Fingers` (+`Mid`) and `Rig/Thumb` for `set_curl`.
  The human model's arms replace it there.
- **Third person, the rig seam**: `rig_map.gd` names the rig's torso, head and arm bones, the arms'
  rest directions and the hand socket offset on each arm bone (Kenney has no hand bones), and the pose
  table (arm directions in skeleton space, +Z forward, the body's right -X; torso pitch / yaw;
  weights): `hold`, `hold_both`, `carry`, `drag`, `saw_windup` / `saw_strike`, `jab_windup` /
  `jab_strike`, `shove_charge` / `shove_strike`. `body_poser.gd` (a SkeletonModifier3D after the
  AnimationPlayer) points the arms and leans the torso over the looped idle / walk / sprint clips.
  A new rig is an entry in `RigMap.RIGS`. A body without a matching rig (the capsule placeholder, a
  dev dummy) keeps `HeldThirdPerson` at `BodyHands.FIXED_ATTACH`. The local player's body only
  animates while the carry camera shows it. The jab shows a syringe in the hand (both views).
- **Carry camera**: while the local player carries a downed player or drags a monster (setting
  "shoulder"), `Head/FX` eases (0.35 s) to `CARRY_OFFSET` (-1.0, 0.45, 2.0) in the head's frame (over
  the left shoulder; the body rides the right) or `DRAG_OFFSET` (0.45, 1.0, 3.6) with a 0.45 rad
  downward look (the body lies behind). Sphere casts (r 0.16) from the head go up, out to the
  shoulder, then back: a wall beside moves it in over the head, a wall behind pulls it toward the
  head; shortening is instant, growing back 2.5 m/s, a teleport snaps. The first-person hands and held
  stack hide (the camera's cull mask drops `HANDS_LAYER`), the local body shows (no shadows) unless the
  camera is within 0.55 m of the head, the flashlight stays at the head pointed along the camera. The
  aim ray (`aim_segment`) runs along the camera's line from where it passes the head, reaching
  `C.INTERACT_RANGE` from the head, so nothing between the camera and the head is aimed at and the
  host's reach check is unchanged. Local only. Carrying bulky loot does not switch it on.

## Dissection (dissection worker, sweep 3)

Strapped monsters on the patient tables (`scripts/dissection/`, `game.dissection`). A monster case is
an ordinary `game.cases` entry: `{table, patient_id: "walk_in" | "discharged", ailment_id: "dissection",
monster: true, flags: {sedation}}` plus `doses` (re-doses given). The surgery systems operate it like
any patient; everything below is host authoritative.

```gdscript
# Procedures (scripts/procedures.gd)
PATIENTS.walk_in / .discharged        # monster: true (name, full_name, weight, blurbs.dissection)
AILMENTS.dissection                   # monster_only: true; steps
    # {id "open", "Saw open the skull", bone_saw, uses 0, game "saw", variant "skull", site "skull"}
    # {id "harvest", "Pull out the brain", forceps, uses 0, game "forceps", variant "brain", site "brain"}
Procedures.is_monster(patient_id) / is_monster_only(ailment_id)
Procedures.human_patients() -> ["bob", "seal"]    # roll(), the dev panel, the loop's extra call, the guide
Procedures.monster_patients() -> ["discharged", "walk_in"]
# roll() and patient_ailments() never return a monster or dissection (same results as before).

# game.dissection (scripts/dissection/dissection.gd), child "Dissection" of Game
owns_case(c) -> bool / owns_table(table) -> bool      # every machine
sedation(c) -> float                                    # host: precise; clients: replicated (hundredths)
static sedation_state(s) -> "under" | "stirring" | "awake"   # STIR 0.75, AWAKE 0.35
static dose_amount(n) -> float                          # DOSE * DOSE_FALLOFF^n = 0.6 * 0.6^n
static brain_kind(patient_id) -> "brain_walk_in" | "brain_discharged"
table_prompt(p, table) -> String                        # game._table_prompt hands monster tables here
table_used(p, table) -> bool                            # host, from game._proxy_used: true = it was a re-dose
redose(p, table) -> float                               # host: one vial from p's hands; returns the sedation added
on_case_finished(c, won)                                # host, from game.finish_case
spawn_brain(patient_id, quality, pos) -> Node           # host: game.brains.spawn_brain, else a plain loot item
dev_strap(kind, sedation := 1.0, table := -1) -> int    # host: tests and the dev panel (request "strap_monster")
set_sedation(case_id, s)                                # host, tests
last_brain: {kind, quality, pos, node}                  # tests
SEDATION_SECONDS 120, SAW_MULT 2.5, THRASH_BOTCH 1.5, THRASH_EVERY 3.0, SHRIEK_NOISE 0.7, REMOVE_AFTER 6.0
```

- **Sedation** falls from 1 to 0 in 120 s, 2.5x while the saw is held in the kerf. The host keeps the
  precise value and writes `flags.sedation` snapped to 0.05 (so the case field is not resent every
  tick); the global snapshot field `dx` = `{s: {"<case id>": hundredths}}` for every monster case on a
  table, and clients write it back into their case flags right after the cases apply, so the
  surgery system's stir code (`flags.sedation`) and the body read the same value everywhere.
- 0.35..0.75 the surgery system's existing stirs. Under 0.35 awake: the body thrashes against the
  straps (every machine, from the sedation), shrieks every 3.5-6.5 s (`emit_noise(table, 0.7,
  "shriek")`, event `dx_shriek`), and while someone operates `surgery_botch(1.5)` every 3 s.
- **Re-dose:** E on the table holding anesthetic (any hand; the selected stack first) re-doses instead
  of operating, also while someone else operates. Prompt: `Re-dose <name> (sedation 42%, +36%)`;
  otherwise `Operate: <step> (sedation 42%)` / `!<reason> (sedation 42%)`. Event `dx_dose`.
- **Brain condition** is the case's `vitals`: `_sim_shift` does not drain it, and the host clamps it
  so it never rises (the +8 of `surgery_step_done` is taken back). At 0 the case is lost ("The brain
  is ruined."). Winning the last step: `spawn_brain(kind, condition / 100, pos)` at the specimen tray
  beside the head (+0.12 m), event `dx_flatline`, the case becomes `stable` and is removed 6 s later
  (dead cases too). `ShiftLoop.pay_for` pays 0; monster cases never block clocking out.
- **Bodies** (`PatientBody.create` dispatches `Procedures.is_monster(id)` to
  `scripts/dissection/monster_builder.gd`; the node is a normal `PatientBody`): lying along X, head
  -X, sites `injection`, `skull`, `brain`, leather straps over chest/arms, hips/wrists, thighs, shins
  (sized for the 0.7 m OR table). Flags `skull_open` (the cap lifts off along the cut over 0.9 s and
  lies bone side up beside the head), `brain_removed` (empty cavity; the body flatlines), `sedation`.
  `site_section("skull")` = `{half_up, half_side, axis_depth, shape}`; `site_section("brain")` also
  carries `half_u`, `brain_radii`, `brain_seed`, `brain_y`, `tray` (site-local Vector3) and `table_up`.
  Body meta `dx_brain_hidden` (set by the brain step while it draws the moving brain). The head is
  always this file's own (it opens); the body is `make_lying(kind)` from `Monster` or
  `scripts/monsters/monster_model.gd` when the copy has its rig: scaled to the 2 m table (the
  Discharged 0.9), arms in at the sides (RigShaper cfg `lying_spread`), the rig's `Head` node hidden.
  The openable head sits at the rig's head bone, face up, wearing the body's own skin material and
  the walking look's face (`scripts/dissection/monster_rig_look.gd`: the Discharged's sealed, stitched
  sockets, brow and large ears; the Walk-In's filmed eyes, jowls, open mouth and fringe of hair);
  face pieces past the cut ride the cap. Fit constants (scale, head bone, straps) live in
  `RigLook.RIG`; `tools/dissectiontest` checks the head bone against them. Thrashing turns the rig's
  arm and leg bones (`strap_thrash.gd`, a SkeletonModifier3D after the shaper), heaves the body and
  pulls the straps over the lifting limbs taut. Without the rig: primitives (the Walk-In a greenish
  patient in a teal gown, the Discharged taller, grey, eyeless, large ears, an IV line taped on).
- **Minigames:** `saw.gd` variant `skull` (layers Scalp/Bone/Dura, no tourniquet, steady scalp bleed,
  finishes `{skull_open: true, cut_quality}`; the saw model is hidden until someone saws). `forceps.gd`
  variant `brain` hands every call to `scripts/dissection/brain_forceps.gd`: clamp each nerve at its
  ring and draw it in along itself (yanking tears: 2.0), take the brain, lift it straight out (scraping
  the bone: 1.5 per 0.5 s), carry it to the tray (dropping: 3.0); finishes `{brain_removed: true}`.
  Net state keys `x y j c k s g l bx bz st h r dr p`. Limb and gunshot behaviour and their self-test
  output are unchanged; `--selftest=saw` and `--selftest=forceps` also run the variants.
- OR screen: panels carry `monster` and `sedation`; the canvas tags the number "BRAIN", shows
  `SEDATION n%` (amber stirring, red and blinking AWAKE), and the status line says BRAIN HARVESTED /
  BRAIN RUINED.
- Sounds `dissection_shriek`, `dissection_strap` (creaks while thrashing, local), `dissection_snap`,
  `dissection_plop`, `dissection_crack`, `dissection_inject` (`tools/gen_audio_dissection.mjs`).
- Tests: `tools/dissectiontest.tscn` (headless; `-- --shots` windowed into `tools/dissection_shots/`),
  minigame self-tests, nettest scenario `dissection`.

## Networking (net worker, sweep 2)

`Net` autoload (`scripts/net.gd`):

```gdscript
Net.host(player_name, port = C.DEFAULT_PORT) -> String       # "" or an error; ENet, synchronous
Net.join(address, port = C.DEFAULT_PORT, player_name = "") -> String   # answers via joined_ok / join_failed
Net.host_steam(player_name = "") -> String   # friends-only lobby; answers via host_ready / host_failed
Net.join_steam(lobby_id, player_name = "") -> String         # answers via joined_ok / join_failed
Net.invite_friends() -> bool                 # Steam overlay invite dialog for the current lobby
Net.steam_available() -> bool                # extension loaded AND Steam client running AND init ok
Net.leave(); Net.is_host(); Net.my_id(); Net.peer_ids(); Net.name_for(id)
Net.names       # peer id -> display name (Steam personas on the Steam backend)
Net.local_name  # survives reset(); the name this machine introduces itself with
Net.backend     # "solo" | "enet" | "steam"
Net.bytes_sent / Net.bytes_received          # ENet wire bytes, for measurements
signal roster_changed, joined_ok, join_failed(reason), host_left, host_ready, host_failed(reason),
       invite_accepted(lobby_id)             # Steam invite / "Join game" / +connect_lobby
```

- Never reference a GodotSteam class or the `Steam` singleton directly outside `net.gd`: the
  extension may be missing, and a direct reference breaks parsing.
- Steam is not initialised in headless runs (tests); `--steam` forces it, `--no-steam` skips it.
- Lag simulation for a joining ENet client: `--net-lag=MS --net-jitter=MS --net-loss=0..1`, or
  `Net.set_lag_simulation()` before `join()`.

Replication (networking section of `scripts/game.gd`):

- Host -> each client, 20 Hz, unreliable, **replicated per field with acks** (netfix, sweep 2
  integration). The state is `g` (entity 0: global fields, with each table's surgery state
  flattened into `sg<table>.*` and `ms<table>.*`, the cases as `cs` (ids), `c.<id>` (the case
  without vitals) and `v.<id>` (its vitals), and the shift loop as `lp.*`), `pl`
  (Player.report_full per peer), `mo` (Monster.report), `ct` (open containers: id -> `{}`) and
  `it` (WorldItem.report); the `id` field of reports is stripped (the key says it).
  - The host tracks, per client and per field, the confirmed value and the value in flight, and
    sends only fields the client lacks. Lost messages (a later one acked 100 ms-newer without
    them, or no ack within srtt + 4 rttvar, 250 ms to 2 s, counted from the client's latest ack
    packet) make their fields unknown, so they go again with current values. Every message holds
    absolute values; the client keeps the newest sequence per field, so any subset in any order
    converges. There are no keyframes and no message depends on another.
  - Existence is field `@` (a hash of the entity's field names, -1 once removed); the client
    uses an entity only when it holds exactly those fields. When the field names change the host
    sends the whole entity; a field that left the report travels as `Game.NET_GONE` (null is an
    ordinary value). `g` is split into groups whose names change together (`""` fixed fields,
    `cs` cases, `lp` loop, `s<table>` surgery), each its own entity; a client keeps using a
    group's last whole copy while a newer one is incomplete.
  - **No message exceeds `Game.NET_MSG_BYTES` (1000 estimated; 1016 serialized seen)**: one datagram on ENet
    (MTU 1392) and one segment on Steam (SteamNetworkingSockets MTU about 1200; its 512 KB
    `MAX_STEAM_PACKET_SIZE` is only the reliable/segmented limit, and an unreliable message split
    into segments is lost if any segment is). Priority per tick: `g`, `pl`, `mo`, `ct`, `it`.
    Bursts (clock-in loot, late joiners) spread over ticks: at most `NET_TICK_BYTES` (4000) per
    client per tick and `NET_WINDOW_BYTES` (16000) unacknowledged, one message per tick while the
    window is full, one every 4 ticks while a client has been silent for 1.5 s. A single field
    bigger than a message still goes alone (fragmented): keep report fields small.
  - Clients ack in `_player_state([newest seq, 64-bit mask of the ones before], Player.report_state())`.
    Every 10 s a client re-applies its whole replica to its nodes locally (no bandwidth).
  - `game.net_counters`: host `{msgs, bytes, acked, lost, max_msg}` (max_msg with `net_measure`),
    client `{msgs, stale}`; nettest `--stats` prints them.
- **Reports must be quantized and must not share mutable data with the live object** (return
  copies of arrays and dictionaries), or unchanged things resend forever or changes go unseen.
  `apply_remote(d)` / `apply_remote_full(d)` always receive the whole merged report, never a
  partial one. A report may omit a field (WorldItem omits `p`/`q` inside a container).
- `Player.report_state() -> Array` (client -> host) is positional; see its comment.
- Anything new that must reach clients: add it to a report (continuous state) or send a reliable
  `_event` (one-off). Do not add new full-state RPCs.
- `game.waiting_peers` (peer id -> true, replicated): peers that joined mid-shift. They exist as
  not-alive Players, `all_players_out()` skips them, and `start_lobby` spawns them. Anything that
  counts or revives dead players must skip them.
- A peer leaving: its hands drop where it stood through `_drop_hands_in_place` (no breakage),
  `surgery.end()` pauses its operation with progress kept.

Tests: `godot --headless --path . --script tools/nettest_run.gd` runs every multi-process
scenario (`-- --only=a,b`, `--lag=MS --jitter=MS --loss=P`, `--only=bandwidth`). Add a scenario
for anything that changes what crosses the wire.

## Brains (brains worker, sweep 3)

`game.brains` (`scripts/brains/brains.gd`, child "Brains" of Game on every machine; parts in
`scripts/brains/`: `brain_model.gd`, `blender.gd`, `echo_view.gd`, `hive_view.gd`).

```gdscript
game.brains.spawn_brain(kind: String, quality: float, pos: Vector3) -> Node   # host: a WorldItem on
    # whatever is under pos; value = base * quality (min $1); spoil clock starts now; squelch sound
Brains.is_brain(kind) -> bool              # "brain_walk_in", "brain_discharged" (static)
Brains.spoil_factor(age_seconds) -> float  # 1.0 for 45 s, linear to 0.15 at 225 s, then 0.15 (static)
Brains.condition(factor) -> String         # "fresh" (>= 0.6), "spoiling" (>= 0.3), "rotten" (static)
Brains.base_value(kind) -> int             # 150 / 350 (loot_table.gd "value")
game.brains.current_value(stack_or_item) -> int   # a hand slot {kind, v, bt} or a WorldItem: v * factor
    # for brains (min $1), the plain value for any other kind
game.brains.factor_of(stack_or_item) / age_of(stack_or_item)
game.brains.points(peer_id, path) -> float # path "walk_in" | "discharged"; 0..3, steps of 0.25
game.brains.level(peer_id, path) -> int    # floor(points), 0..3
game.brains.best_path(peer_id) -> String   # more points wins, a tie is "discharged" (Echo), "" none
game.brains.add_points(peer_id, path, amount)   # host (the blender, dev, tests)
game.brains.ability(p)                     # host, from game.player_ability (R)
game.brains.on_reset()                     # host, from game.reset_money (game over, new session)
game.brains.blender                        # the placed blender node (interact_id "blender") or null
game.brains.blend_progress(peer_id) -> float    # 0..1 while that player holds E on the blender
game.brains.camera() -> Camera3D           # every machine: the Hive Eyes camera while the LOCAL
                                           # player looks through a Walk-In (main.gd renders it), else null
game.brains.local_hive_active() / local_exit()  # main.gd: Esc during Hive Eyes
game.brains.spawn_walk_in(pos) -> Node     # host (dev, tests): a Walk-In; a stand-in Discharged body
                                           # with kind "walk_in" while Monster.WALK_IN does not exist
game.brains.dev_request(sender, action, args)   # "br_spawn_brain" {kind, quality, age}, "br_levels"
                                           # {amount, id}, "br_reset", "br_walk_in" (dev_room forwards br_*)
```

- **Brain items.** Loot kinds `brain_walk_in` ($150) and `brain_discharged` ($350) in
  `loot_table.gd` with `brain: true`, fragile, not stackable, not bulky, no rooms / surfaces /
  containers (the loot spawner never picks them). The model is one merged mesh with the gold rim.
- **Spoil time `bt`** (world_time of the harvest): `WorldItem.bt` (default -1e6 = none; any value
  above -1e5 is a real clock, it may be negative early in a run), reported as `bt` (snapped 0.5);
  in a hand slot as `slots[i].bt`. Carried by `game.pickup_item`, `drop_selected`, `_drop_hands`
  (a violent drop cracks the brain like other fragile loot, the clock stays), `_drop_hands_in_place`
  and the dev room's `hand_over`. **Anything else that moves a stack between hands and the world
  must carry `bt` too.** The host stamps `bt = world_time` on any brain found without one (4 Hz).
- **The dumpster** is the existing sell bin (interact_id `sell_bin`, unchanged): its sign says
  DUMPSTER, its prompt `Sell X for $N at the dumpster` with the current value, `game.sell_selected`
  pays `current_value`. The HUD slot and the world item prompt show the current value (and the
  condition for brains).
- **Blender:** on a break-room counter top found with downward rays over `level_info.rooms` kind
  `break_room` (the free end nearest the time clock, backed toward the wall), else on a steel stand
  on free floor beside `level_info.economy.shop` (dev room), else near the clock. Placed two physics
  frames after a new `game.level`, same spot on every machine. Holding a brain selected: hold E
  (`interact_hold` 1.5 s; the host simulates it from `wants_interact` + `aim_id`, like the clock).
  Drinking: +1.0 fresh, +0.75 spoiling, +0.5 rotten to that path, capped at 3.0.
- **R:** in Hive Eyes, R ends it. Otherwise `best_path`; none: "Nothing happens." (at most once a
  second). Cooldowns: Echo 20 s from the shriek, Hive Eyes 12 s from when the view ends (R presses
  in the 0.5 s after a view ends are ignored). Not while downed; Hive Eyes not while carrying or
  operating. Scaling is literal: `12 + 6 * level` m and `2.5 + 0.75 * level` s for Echo, `20 + 10 *
  level` m and `5 + 2 * level` s for Hive Eyes, so a half point (level 0) already works at the base.
- **Echo** (host): `game.emit_noise(pos + 1.5 up, 1.2, "echo")`, event `br_echo {id, pos, r, s}`:
  everyone hears `brains_shriek` at pos (the shrieker hears it 2D); the shrieker's machine runs
  `echo_view.start`: a dark veil quad on the camera and at most 40 things / 150 mesh outlines
  (monsters red, other players white, surgical items teal, loot gold, containers dim) through walls
  (`depth_test_disabled`, `ignore_occlusion_culling`), lit as a 26 m/s wave passes. Freed when it ends.
- **Hive Eyes** (host): the nearest `kind == "walk_in"` monster within range (through walls, not
  `is_sedated()`); `Player.hive_view = true` (report key `hv`), `br.hv[peer] = [monster id, end
  world_time]`, event `br_hive {id, on}`. Ends on time, R / E / Esc, the monster leaving
  `game.monsters` (killed, strapped) or `is_sedated()`, and the player's hp dropping, being downed,
  stunned or carried. While `hive_view` the Player ignores movement, mouse look, aim, use, shove,
  drop and interact (E and R bump `ability_count`); remote copies droop the head and lean.
- **Replication:** `net_state()` = `{"p": {peer: [walk_in, discharged]}, "hv": {peer: [id, end]},
  "bh": {peer: progress}}` (copies, quantized; empty dictionaries when idle).
- Sounds `brains_squelch`, `brains_blend`, `brains_gulp`, `brains_shriek`, `brains_hive_in`,
  `brains_hive_out` (`tools/gen_audio_brains.mjs`).
- Tests: `tools/braintest.tscn` (headless, 71 checks), nettest scenario `brains`,
  `tools/brainshot.tscn` (windowed shots to `tools/brain_shots/`), `tools/perfprobe.tscn -- --brains`.

## Design decisions (locked)

- Each patient is Bob or the seal with one ailment (gunshot or amputation). Sweep 2: one patient
  per shift plus an optional extra one on the second table (see "Shift loop and patients").
- Items are always physical 3D models: in containers that visibly open, or loose. Aim + E.
- Consumables come in batches; a batch is one hand slot; stacks merge; each use consumes one;
  fragile stacks lose about a third when dropped, never all of it. Getting hit or shoved drops
  both hands.
- Containers stay open once opened; E toggles. Red herring items spawn.
- A softlock guard respawns supply far away if breakage makes the shift unwinnable.
- Each step is its own in-world minigame; botches cost vitals only. Underdosing makes the
  patient stir in later steps; a weak tourniquet makes the saw step bloody.
- The medical guide is a physical binder on a lectern, carryable, with item pages, procedure
  checklists and locked placeholder tabs.
- Monsters: The Discharged (blind, hunts by sound, rattling IV pole, shove stuns it) and
  The Night Nurse (moves only while no one is looking at it with light on it, shove does
  nothing, 2 hearts).
- Not in this sweep: networked physics beyond dropped items, the cart, two-person steps,
  voice chat, classes, progression, cosmetics.
