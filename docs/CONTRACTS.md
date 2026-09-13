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
  Surgical kinds: `anesthetic`, `gauze`, `forceps`, `tourniquet`, `bone_saw`. Plus `guide`.
- `Procedures` (`scripts/procedures.gd`): `PATIENTS` (`bob`, `seal`, with weight and limb
  radius), `AILMENTS` (`gunshot`, `amputation`) with steps `{id, label, item, uses, game,
  variant?, site}`, `roll(seed, shift)`, `requirements(ailment)`,
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

Game-side API the surgery system uses:

- `game.case` `{patient_id, ailment_id, step_index, flags}` (host authoritative, replicated)
- `game.patient_body` (the PatientBody on the table, or null)
- `game.shelf_count(kind)`, `game.is_host()`, `game.world_time`, `game.shift`, `game.players`
- `game.surgery_botch(amount: float, reason: String)` host: costs vitals, says why
- `game.surgery_step_done(result: Dictionary)` host: consumes the step's items from the shelf,
  merges `result` into `case.flags`, gives vitals back, advances or wins the shift
- `game.send_operator_report(report: Dictionary)` client operator -> host (the game routes it
  to `receive_operator_report` on the host; on the host it calls it directly)
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
clock, pod: Vector3             # break room; clock_pos() / pod_pos() unchanged
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
    # stand-in until wave 3: damage down to 1 HP plus p.stun seconds; replace the body, keep the call
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
  instead of starting a lobby. Wave 2's phone call: add `game.dev_phone_call()` and the panel's
  button calls it (until then `dev.phone_call_requested` is emitted).
- `surgery_system.gd` lets an `is_bot` operator operate on the host with the minigame's
  `bot_input(t, skill)` (skill from the bot's meta `bot_skill`). Minigames must keep
  `bot_input` finishing their step.
- Interactables: `dev_disp_<item kind>` dispensers (endless stacks) and `dev_disp_dev_gun`.
- World changes from the panel or tests: `game.dev.request(action, args)`; the host applies,
  a client sends. Shots: `game.dev.fire(shooter, from, dir, "kill" | "knock")`.
- Sounds `dev_zap`, `dev_thump`, `dev_defib` from `tools/gen_audio_dev.mjs`.

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
- `game.spawn_loot()` (host) runs in `begin_shift()` right after `_spawn_supplies()`. The loop
  worker may call it wherever the new flow spawns supplies.

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

- Host -> each client, 20 Hz, unreliable: acked deltas of a state made of `g` (global fields,
  with the surgery state flattened into `sg.*` and `ms.*`), `pl` (Player.report_full per peer),
  `mo` (Monster.report), `it` (WorldItem.report), `ct` (open containers only). Clients ack in
  `_player_state(ack, Player.report_state())`. Keyframes on demand and every 10 s.
- **Reports must be quantized and must not share mutable data with the live object** (return
  copies of arrays and dictionaries), or unchanged things resend forever or changes go unseen.
  `apply_remote(d)` / `apply_remote_full(d)` always receive the whole merged report, never a
  partial one. A report may omit a field (WorldItem omits `p`/`q` inside a container).
- `Player.report_state() -> Array` (client -> host) is positional; see its comment.
- Anything new that must reach clients: add it to a report (continuous state) or send a reliable
  `_event` (one-off). Do not add new full-state RPCs.
- `game.waiting_peers` (peer id -> true, replicated): peers that joined mid-shift. They exist as
  not-alive Players, the Re-Gen Pod ignores them, and `start_lobby` spawns them. Anything that
  counts or revives dead players must skip them.
- A peer leaving: its hands drop where it stood through `_drop_hands_in_place` (no breakage),
  `surgery.end()` pauses its operation with progress kept.

Tests: `godot --headless --path . --script tools/nettest_run.gd` runs every multi-process
scenario (`-- --only=a,b`, `--lag=MS --jitter=MS --loss=P`, `--only=bandwidth`). Add a scenario
for anything that changes what crosses the wire.

## Design decisions (locked)

- One patient (Bob or the seal) and one ailment (gunshot or amputation) per shift.
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
