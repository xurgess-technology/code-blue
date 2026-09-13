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
info["containers"]    = [{id, type, room_kind, node}]
info["loose_anchors"] = [{position: Vector3, yaw: float, surface: "counter"|"tray"|"gurney"|"floor", room_kind: String}]
info["shelf"]         = {position: Vector3, yaw: float}   # OR supply shelf, near the table
info["lectern"]       = {position: Vector3, yaw: float}   # in the clock-in room
```

## Item spawning (containers worker)

```gdscript
# scripts/item_spawner.gd
static func plan(seed: int, shift: int, ailment_id: String, info: Dictionary) -> Array
static func shortfall_plan(seed: int, need: Dictionary, have: Dictionary, info: Dictionary,
		occupied: Dictionary, avoid: Array) -> Array
# Each entry: {kind: String, count: int, container_id: String ("" when loose), slot: int, anchor: int}
# `occupied` is {"ct_id:slot": true, "anchor:<i>": true}; `avoid` is an Array[Vector3] to stay far from.
```

Rules: every consumable gets more than `Procedures.requirements()` in total, split across at least
two locations; every needed tool exists at least once; nothing needed spawns in the OR, its
anterooms or the clock-in room; at least one needed item is far from the table; items the
current ailment does not need also spawn as red herrings; spawn counts respect `Items` batch
sizes; deterministic from the seed. The game instantiates `WorldItem`s from the plan.

## World items (main session)

`scripts/world_item.gd`, a `RigidBody3D` on layer `C.L_PICKUP`, group `"interactable"`,
meta `interact_id` `"it_<n>"`. Fields: `item_id`, `kind`, `count`, `state` (`IN_CONTAINER`,
`LOOSE`, `ON_LECTERN`), `container_id`, `slot`. Host-simulated physics when dropped; clients
lerp to the snapshot transform. Picking up removes the node and fills a hand slot.

## Hands (main session)

`Player.slots` is an `Array` of two dictionaries `{kind: String, count: int}` (`kind` `""` when
empty), `Player.selected` is 0 or 1. Consumable stacks of the same kind merge. Host authoritative,
replicated in the snapshot.

## The OR supply shelf (main session)

`game.shelf` is a `Dictionary` kind -> count. Pressing E on the shelf places the selected stack.
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
