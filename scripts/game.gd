class_name Game
extends Node3D
## The world and the whole shift simulation.
##
## The host owns the truth: monsters, items, containers, the shelf, the case on the table,
## damage and phase changes. Every player owns their own surgeon's movement and aim and
## reports it. Clients mirror the host through a 20 Hz snapshot. Solo play is hosting with
## nobody connected.
##
## Level geometry is never networked: each peer builds it locally from the shared seed, so
## anything derived from the level (containers, their ids) matches on every machine.

enum Phase { MENU, LOBBY, SHIFT, WON, LOST }

const LightRoomsScript := preload("res://scripts/level/light_rooms.gd")
const SNAPSHOT_HZ := 20.0
const NOISE_MEMORY := 2.0
const SUPPLY_CHECK_SECONDS := 3.0

signal phase_changed(phase: int)
signal notice(text: String, seconds: float)
## loop (sweep 2): a case was added, removed, moved onto a table, advanced a step or finished.
## Not emitted for vitals changes. Every machine.
signal cases_changed

# ---- replicated state ----
var phase: int = Phase.MENU
var seed_value: int = 0
var shift: int = 1
var world_time: float = 0.0
var punch: float = 0.0
var end_timer: float = 0.0
## loop (sweep 2): every patient this shift, host authoritative and replicated. Each case is
##   {id, table (index into level_info.tables, -1 on the gurney), patient_id ("bob"|"seal"|
##    "player"), player_id (player cases), ailment_id, step_index, flags, vitals,
##    state ("incoming"|"on_table"|"stable"|"dead"), optional (the extra patient)}
## Change it through add_case / finish_case / remove_case (host).
var cases: Array = []
## Alias of the first patient case (not a "player" case), {} when there is none. Reading returns
## the live dictionary; assigning replaces that case's patient, ailment, step and flags (or puts
## a new case on the first patient table), and assigning {} removes it. Kept for code written
## against the single-patient game.
var case: Dictionary:
	get:
		return _alias_case()
	set(value):
		_set_alias_case(value)
## Alias of the first patient case's vitals (100 when there is none).
var vitals: float:
	get:
		var c := _alias_case()
		return float(c.get("vitals", 100.0)) if not c.is_empty() else 100.0
	set(value):
		var c := _alias_case()
		if not c.is_empty():
			c["vitals"] = value
## The OR supply shelf: item kind -> count.
var shelf: Dictionary = {}
## Team money in dollars (inventory, sweep 2). Host authoritative, replicated, survives shifts;
## change it through add_money() and reset_money().
var money: int = 0
## SWEEP 4A HOOK (pharmacy, chunk 3): a patient/monster/OR blip note from a thrown placebo pill,
## for the OR screen's green blip (scripts/orscreen/or_screen_model.gd). Host authoritative,
## replicated as g "pn" (table index -> world_time it landed); a panel shows the note for a few
## seconds after. Vitals and sedation never change.
var pill_notes: Dictionary = {}

# ---- local ----
var level: Node3D = null
var level_info: Dictionary = {}
var players: Dictionary = {}      # peer id -> Player
var monsters: Dictionary = {}     # monster id -> Monster
## SWEEP 4A HOOK (database terminal, chunk 4): THIS machine's player's own database, kind ->
## DbRecord (sighted / scanned / harvested). Every player has their own: the host decides when a
## player sights, scans or harvests something (mark_db) and tells that player's machine, which saves
## it (DatabaseStore). Loaded from disk in _ready(); survives a wipe (game.reset_money) and a reload.
const DbRecordScript := preload("res://scripts/database/db_record.gd")
const DatabaseStoreScript := preload("res://scripts/database/database_store.gd")
var database: Dictionary = {}
var _scan_progress: Dictionary = {}   # peer id -> 0..1
var _scan_target: Dictionary = {}     # peer id -> scan target id (monster id, or a scan prop's negative id)
## Scannable things that are not monsters (the waiting room's Night Nurse): nodes with `kind`,
## `height` and a negative `scan_id`, a collider on C.L_SCAN. They add and remove themselves.
var scan_props: Array = []
## Terminal redesign: the break room projector (the wall terminal) is on. Host authoritative, "pj" in
## the snapshot; E on the projector toggles it.
var projector_on := false
## Terminal redesign, chunks 3 and 4: the break room screen everyone shares (who is signed in, the
## page on it, clicks from every machine). scripts/database/wall_session.gd.
var wall: Node = null
## Room-bound lighting (scripts/level/light_rooms.gd): nodes that joined the level this frame, placed
## on their area's render bits once their transforms are set.
var _light_queue: Array = []
var world_items: Dictionary = {}  # item id -> WorldItem
## loop: the PatientBody on the first patient case's table, or null.
var patient_body: Node3D:
	get:
		var c := _alias_case()
		return body_for_table(int(c.get("table", -1))) if not c.is_empty() else null
	set(_value):
		pass
## loop: one surgery system per patient table (scripts/surgery/surgery_system.gd), in the order of
## `patient_tables`. `surgery` is whichever the local player is operating at (or its camera is
## still blending back from), else the first patient case's table's, else the first.
var surgeries: Array = []
var surgery: Node:
	get:
		return _surgery_view()
	set(_value):
		pass
## loop: the patient tables: [{index (into level_info.tables), position, yaw}].
var patient_tables: Array = []
## loop: bot operators (tests) use this skill on every table; < 0 means a human plays.
var surgery_bot_skill: float = -1.0
## loop: the shift loop (scripts/loop/shift_loop.gd), child "Loop": grace, phone, paramedics, pay.
var loop: Node = null
## Patient exits: the dead on (and off) the tables, carried to the furnace (scripts/loop/corpses.gd).
const CorpsesScript := preload("res://scripts/loop/corpses.gd")
var corpses: Node = null
var shelf_node: Node3D = null
var message: String = ""
var message_timer: float = 0.0
var danger: float = 0.0
var spectating: int = 0
var paused: bool = false
## DEV HOOK: dev mode for this session, on every machine (the pharmacy fax's secret order,
## DEV_CODE placebo pills). The F1 panel works anywhere and the hidden dev room is built. Replicated.
var dev_tools: bool = false
const DEV_CODE := 3141592653
var _new_run_pending := false
## DEV HOOK: the dev room controller (scripts/dev/dev_room.gd), idle outside the dev room.
var dev: Node = null

var _entities: Node3D
var _snap_accum: float = 0.0
var _next_monster_id: int = 0
var _next_item_id: int = 0
var _rng := RandomNumberGenerator.new()
var _noises: Array = []
var _footstep_acc: Dictionary = {}
var _supply_timer: float = 0.0
var _botch_say_timer: float = 0.0
var _complication_timer: float = 0.0
var _next_case_id: int = 1
var _bodies: Dictionary = {}          # table index -> {key, fk, dead, node}
var _cases_sig: String = ""
var _shift_item_ids: Dictionary = {}  # host: items the spawners put in the hospital this run

const PlayerScene := preload("res://scripts/player.gd")
const MonsterScript := preload("res://scripts/monster.gd")
const WorldItemScript := preload("res://scripts/world_item.gd")
const ShelfScript := preload("res://scripts/supply_shelf.gd")
const BodyScript := preload("res://scripts/patient_body.gd")
const SpawnerScript := preload("res://scripts/item_spawner.gd")
const SurgeryScript := preload("res://scripts/surgery/surgery_system.gd")
const DevRoomScript := preload("res://scripts/dev/dev_room.gd")
const EconomyScript := preload("res://scripts/economy/economy.gd")
# SWEEP 4A HOOK (pharmacy, chunk 3): PillLines is a class_name (scripts/economy/pill_lines.gd),
# used directly below.
const LootSpawnerScript := preload("res://scripts/economy/loot_spawner.gd")
const LoopScript := preload("res://scripts/loop/shift_loop.gd")
const TablesScript := preload("res://scripts/loop/tables.gd")
const HospitalZones := preload("res://scripts/hospital_builder.gd")
## A fragile piece of loot that gets dropped violently keeps this share of its value.
const LOOT_CRACK_KEEPS := 0.55

## The pharmacy window and the crematorium furnace in the world (scripts/economy/economy.gd),
## child "Economy". SWEEP 4A HOOK (pharmacy, chunk 3): gold bars, the sell bin and the shop are
## gone; buying is the pharmacy, selling is throwing into the furnace.
var economy: Node = null
## ORSCREEN HOOK: the OR wall monitor (scripts/orscreen/or_screen.gd), child "ORScreen".
const OrScreenScript := preload("res://scripts/orscreen/or_screen.gd")
var or_screen: Node = null

## Downed players (sweep 2 wave 3; docs/CONTRACTS.md "Downed players").
const PlayerSurgeryScript := preload("res://scripts/downed/player_surgery.gd")
const DownedViewScript := preload("res://scripts/downed/downed_view.gd")
const PlayerTableScript := preload("res://scripts/downed/player_table.gd")
## Seconds a downed player takes to bleed out (then dead until the next shift).
const BLEED_SECONDS := 300.0
## Lying on the player table slows the bleeding to this share.
const TABLE_BLEED_K := 0.5
## Hold E this long on a downed teammate to pick them up.
const CARRY_HOLD := 1.0
## What a stitched-up player gets back.
const REVIVE_HP := 2
const CALL_COOLDOWN := 4.0
const SUTURE_KITS_PER_SHIFT := 3
## scripts/downed/player_surgery.gd, child "PlayerSurgery": the stitches operation.
var player_surgery: Node = null
## scripts/downed/downed_view.gd, child "DownedView": blood trails and the downed overlay.
var downed_view: Node = null
## The player table: {position: Vector3 (floor), yaw: float, top: float (table top height)}.
var player_table: Dictionary = {}
var _call_at: Dictionary = {}   # peer id -> world_time of their last call for help

# SWEEP 3 HOOK (docs/SWEEP3.md): children created in _ready on every machine.
const CombatScript := preload("res://scripts/combat/combat.gd")
const DissectionScript := preload("res://scripts/dissection/dissection.gd")
const BrainsScript := preload("res://scripts/brains/brains.gd")
var combat: Node = null       # bone saw swings, anesthetic jabs, dragging and strapping monsters
var dissection: Node = null   # monster cases on the patient tables: sedation, re-dosing, the brain
var brains: Node = null       # brain spoilage, the blender, per-player upgrades, Echo and Hive Eyes
# POCKETS HOOK: pocket spaces (the Factory, the Restaurant), their seams and crossings.
const PocketSpacesScript := preload("res://scripts/level/pockets/pocket_spaces.gd")
var pockets: Node = null

# DOORS HOOK: every door of the level, and the wings behind the loading gates rebuilt each shift.
const DoorsScript := preload("res://scripts/doors/doors.gd")
const WingLoaderScript := preload("res://scripts/level/wing_loader.gd")
var doors: Node = null         # scripts/doors/doors.gd, child "Doors"
var wing_loader: Node = null   # scripts/level/wing_loader.gd, child "WingLoader"
## Host: someone clocked in while the wings were still being rebuilt; clock-in happens when ready.
var clock_in_pending := false


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)   # room-bound lighting
	_entities = Node3D.new()
	_entities.name = "Entities"
	add_child(_entities)
	_ensure_surgeries(1)
	# SWEEP 4A HOOK (database terminal, chunk 4): loaded once per process, before anything can
	# mark a record. Harmless for a client: it never reads its own copy (the terminal fetches
	# the host's live database over the wire), only the host's file on disk matters.
	DatabaseStoreScript.load_into(database)
	loop = LoopScript.new()
	loop.name = "Loop"
	add_child(loop)
	loop.setup(self)
	# Patient exits: bodies carried to the furnace (scripts/loop/corpses.gd).
	corpses = CorpsesScript.new()
	corpses.name = "Corpses"
	add_child(corpses)
	corpses.setup(self)
	# SWEEP 4A HOOK (scanner): the local scan hologram, beam, completion ring and banner.
	var scan_fx: Node = preload("res://scripts/scan_fx.gd").new()
	scan_fx.name = "ScanFx"
	add_child(scan_fx)
	scan_fx.setup(self)
	wall = preload("res://scripts/database/wall_session.gd").new()
	wall.name = "WallSession"
	add_child(wall)
	wall.setup(self)
	# DEV HOOK: the dev room lives on every machine at the same path so its RPCs line up.
	dev = DevRoomScript.new()
	dev.name = "Dev"
	add_child(dev)
	dev.setup(self)
	economy = EconomyScript.new()
	economy.name = "Economy"
	add_child(economy)
	economy.setup(self)
	# downed: the player table's operation and the downed visuals, at the same path everywhere.
	player_surgery = PlayerSurgeryScript.new()
	player_surgery.name = "PlayerSurgery"
	add_child(player_surgery)
	player_surgery.setup(self)
	downed_view = DownedViewScript.new()
	downed_view.name = "DownedView"
	add_child(downed_view)
	downed_view.setup(self)
	# ORSCREEN HOOK: the OR wall monitor; it mounts itself on every new level (scripts/orscreen).
	or_screen = OrScreenScript.new()
	or_screen.name = "ORScreen"
	add_child(or_screen)
	or_screen.setup(self)
	# SWEEP 3 HOOK: fighting and capturing monsters, dissection on the patient tables, brains and
	# the abilities they teach. Same path on every machine.
	combat = CombatScript.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(self)
	dissection = DissectionScript.new()
	dissection.name = "Dissection"
	add_child(dissection)
	dissection.setup(self)
	brains = BrainsScript.new()
	brains.name = "Brains"
	add_child(brains)
	brains.setup(self)
	# POCKETS HOOK: after Entities, so crossings see this frame's movement. Same path everywhere.
	pockets = PocketSpacesScript.new()
	pockets.name = "Pockets"
	add_child(pockets)
	pockets.setup(self)
	# DOORS HOOK: same path on every machine.
	doors = DoorsScript.new()
	doors.name = "Doors"
	add_child(doors)
	doors.setup(self)
	wing_loader = WingLoaderScript.new()
	wing_loader.name = "WingLoader"
	add_child(wing_loader)
	wing_loader.setup(self)
	wing_loader.extra_builders.append(pockets)   # POCKETS HOOK: the pocket is built and torn down with the wings
	Net.roster_changed.connect(_on_roster_changed)
	Net.joined_ok.connect(_net_client_forget)  # net: a new connection starts a new replica
	Net.host_left.connect(func(): end_session("The host left the game."))


func is_host() -> bool:
	return Net.is_host()


func local_player() -> Node:
	return players.get(Net.my_id())


## Whose eyes we are looking through: yours, or a teammate's while you are dead.
func viewed_player() -> Node:
	var me := local_player()
	if me != null and me.alive:
		return me
	if players.has(spectating) and players[spectating].alive:
		return players[spectating]
	for p in players.values():
		if p.alive:
			return p
	return me


# =========================================================================
# session lifecycle
# =========================================================================

func start_session(first_seed: int) -> void:
	shift = 1
	spectating = 0
	reset_money()  # a new run starts broke; clients get the host's value in the snapshot
	start_lobby(first_seed, 1)


func end_session(reason: String) -> void:
	_discard_prebuilt()
	_clear_case()
	loop.reset()
	_clear_items()
	_clear_monsters()
	_clear_level()
	for p in players.values():
		p.queue_free()
	players.clear()
	dev.reset_state()  # DEV HOOK: bots are gone with the players; time scale back to 1
	dev_tools = false   # DEV HOOK: dev mode is for this session only
	phase = Phase.MENU
	phase_changed.emit(phase)
	if not reason.is_empty():
		notice.emit(reason, 6.0)


## Build the hospital for a run and put everyone at the start (the neutral area outside, or the
## clock-in room on levels without one). loop: the hospital is kept for the whole run; later
## shifts go through _to_next_shift() instead, and only a new run (or a joining client) builds.
func start_lobby(new_seed: int, new_shift: int) -> void:
	seed_value = new_seed
	shift = new_shift
	_rng.seed = hash(str(new_seed) + "|" + str(new_shift))
	_clear_case()
	loop.reset()
	_clear_items()
	_clear_monsters()
	clock_in_pending = false   # DOORS HOOK
	_build_level(new_seed)
	punch = 0.0
	end_timer = 0.0
	world_time = 0.0
	_noises.clear()
	# net: a new hospital invalidates every snapshot baseline; late joiners get to play now.
	waiting_peers.clear()
	if is_host():
		_net_reset_history()
	else:
		_net_client_reset()
	_set_phase(Phase.LOBBY)
	_sync_players()
	for p in players.values():
		_respawn_at_start(p)
	# First lobby of the session: build and draw one of everything behind a short cover so
	# nothing hitches the first time it appears later.
	Warmup.run(self)
	if is_host() and Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


## Host: the time clock. The shift's hospital fills up (loot, monsters; supplies come with each
## accepted patient) and the grace period starts; the phone rings when it runs out.
func clock_in() -> void:
	if not is_host() or phase != Phase.LOBBY:
		return
	# DOORS HOOK: the wings behind the gates are still being rebuilt: clock in once they are ready
	# (the gates' lamps blink amber meanwhile).
	if not wing_loader.wings_ready or pockets.busy:   # POCKETS HOOK: and the pocket built with them
		if not clock_in_pending:
			clock_in_pending = true
			say("Clocked in. The wing doors are unlocking...", 3.0)
		return
	clock_in_pending = false
	_populate_shift_world()
	_set_phase(Phase.SHIFT)
	loop.on_clock_in()
	_sound("punch")
	if Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


## Host: a shortcut for tools and tests written against the old game: clock in and put this
## shift's first patient straight onto the first patient table, with no grace, call or paramedics.
func begin_shift() -> void:
	if not is_host():
		return
	wing_loader.finish_now()   # DOORS HOOK: tools cannot wait for the wings
	pockets.finish_now()   # POCKETS HOOK: nor for the pocket
	clock_in_pending = false
	if phase == Phase.LOBBY:
		_populate_shift_world()
		_set_phase(Phase.SHIFT)
	loop.on_clock_in()
	loop.skip_to_first_patient_on_table()
	_sound("punch")
	var c := _alias_case()
	if not c.is_empty():
		var pt := Procedures.patient(c.patient_id)
		var ail := Procedures.ailment(c.ailment_id)
		say("Incoming: %s. %s. %s" % [pt.full_name, ail.name, Procedures.blurb(c.patient_id, c.ailment_id)], 8.0)
	if Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


## Host: fresh loot and monsters for a new shift in the run's hospital. What the spawners left in
## the hospital last shift and nobody touched goes away, and every container closes again.
func _populate_shift_world() -> void:
	_clear_case()
	for id in _shift_item_ids.keys():
		var it = world_items.get(id)
		if it != null and is_instance_valid(it):
			it.queue_free()
			world_items.erase(id)
	_shift_item_ids.clear()
	for n in get_tree().get_nodes_in_group("container"):
		if n.has_method("is_open") and n.is_open():
			n.set_open(false, false)
	spawn_suture_kits()  # downed: every shift has suture kits for the player table
	spawn_loot()
	_spawn_monsters()


func _set_phase(p: int) -> void:
	if phase == p:
		return
	if not is_host() and p == Phase.LOBBY and (phase == Phase.WON or phase == Phase.SHIFT or phase == Phase.LOST):
		# loop: a client reaching the next shift's lobby in the same hospital. If I was dead or
		# waiting to join, I get up at the start (I own my position; the host revives me too).
		var me := local_player()
		if me != null and (not me.alive or me.downed or waiting_peers.has(me.peer_id)):
			_respawn_at_start(me)
		loop.reset()
	phase = p
	phase_changed.emit(p)


## Legacy entry point kept for tests: `won` clocks the team out (pay as usual, then the next
## shift's lobby), otherwise it is a team failure (game over).
func _end_shift(won: bool, text: String) -> void:
	if not is_host():
		return
	if won:
		loop.clock_out(true)
	else:
		game_over(text)


## Host: the team clocked out. A short paycheck screen, then the next shift's lobby in the same
## hospital: nobody is moved, hands are kept, monsters are gone.
func finish_shift(text: String, seconds: float) -> void:
	if not is_host():
		return
	_clear_monsters()
	punch = 0.0
	_set_phase(Phase.WON)
	end_timer = seconds
	Audio.sting("saved")
	say(text, seconds)
	if Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


## Host: everyone is down or dead during a shift. Game over: after the screen, money resets and a
## new run starts in a new hospital.
func game_over(text: String) -> void:
	if not is_host() or phase == Phase.LOST:
		return
	for c in cases:
		if String(c.state) == "on_table" or String(c.state) == "incoming":
			c.state = "dead"
	_apply_cases_locally()
	loop.on_game_over()
	punch = 0.0
	_set_phase(Phase.LOST)
	end_timer = loop.GAME_OVER_SECONDS
	Audio.sting("flatline")
	say(text, end_timer)
	if Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


## Host: from the paycheck screen to the next shift's lobby, same hospital. The dead and the late
## joiners get up at the start; the living stay where they are with what they carry.
func _to_next_shift() -> void:
	shift += 1
	_clear_case()
	loop.reset()
	punch = 0.0
	end_timer = 0.0
	for p in players.values():
		if not p.alive or p.downed or waiting_peers.has(p.peer_id):
			_respawn_at_start(p)   # the dead, the downed (downed worker) and late joiners
	waiting_peers.clear()
	_set_phase(Phase.LOBBY)
	# DOORS HOOK: the wings behind the locked gates are rebuilt for this shift (anyone still inside is
	# walked out to the entrance hall first). Clock-in waits until they are ready.
	clock_in_pending = false
	wing_loader.regenerate(maxi(shift, int(wing_loader.generation) + 1))
	if Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


## Host (dev panel "Phone call"): an incoming patient right now, paramedics already on the way.
func dev_phone_call() -> void:
	loop.dev_phone_call()


## Host (dev panel "Extra patient"): the optional extra call rings now (in the dev room, which has
## no phone, the extra patient is accepted and wheeled to the other table).
func dev_extra_patient() -> void:
	loop.dev_extra_patient()


## Host (dev panel "Skip grace"): the grace period ends now and the phone rings.
func dev_skip_grace() -> void:
	loop.skip_grace()


## Client: the host started a new hospital. The build has to happen now (the snapshots that follow
## are for it), so the screen can't draw before it; it comes up right after and hides the pop into
## the new level for a moment instead.
func _client_rebuild_cover() -> void:
	Loading.begin("rebuild", "NEW HOSPITAL...")
	Loading.end.call_deferred("rebuild")


## DEV HOOK: dev mode is on in this session (the pharmacy's secret order).
func dev_on() -> bool:
	return dev_tools


## Host: turn the session's dev tools on or off for everyone. Off also drops every toggle, bot and
## dummy (dev.reset_state); the dev room's geometry stays until the session ends.
func set_dev_tools(on: bool, p: Node = null) -> void:
	if not is_host() or on == dev_tools:
		return
	dev_tools = on
	if not on:
		dev.reset_state()
	var who: String = p.player_name if p != null else "Someone"
	say(("%s turned on DEV MODE. F1 opens the dev panel." % who) if on else ("%s turned off DEV MODE." % who), 4.0)
	dev.on_dev_tools(on)


## Host: after game over, a new run: broke, shift 1, a new hospital. The loading screen goes up and
## draws first; the game-over tick keeps calling this while it waits, hence the guard.
func _new_run() -> void:
	if _new_run_pending:
		return
	_new_run_pending = true
	Loading.begin("new_run", "NEW HOSPITAL...")
	await Loading.drawn()
	var new_seed := seed_value + 7919
	await prebuild_level(new_seed, 1)
	_new_run_pending = false
	if phase == Phase.LOST and is_host():
		reset_money()
		start_lobby(new_seed, 1)
	else:
		_discard_prebuilt()
	Loading.end("new_run")


func say(text: String, seconds: float = 3.0) -> void:
	message = text
	message_timer = seconds
	notice.emit(text, seconds)
	if is_host():
		_broadcast("say", {"text": text, "secs": seconds})


## A message only one player sees.
func tell(p: Node, text: String, seconds: float = 2.5) -> void:
	if p == null:
		return
	if p.is_local:
		message = text
		message_timer = seconds
		notice.emit(text, seconds)
	elif Net.active and is_host():
		_event.rpc_id(p.peer_id, "say", {"text": text, "secs": seconds})


## Tell the other machines about a one-off thing. Solo has nobody to tell.
func _broadcast(kind: String, data: Dictionary) -> void:
	if Net.active and is_host():
		_event.rpc(kind, data)


func _sound(cue: String, at = null) -> void:
	Audio.play(cue, at)
	_broadcast("sound", {"cue": cue, "at": at})


# =========================================================================
# level
# =========================================================================

const MAPGEN_PATH := "res://scripts/mapgen.gd"
const BUILDER_PATH := "res://scripts/hospital_builder.gd"
## A hospital built ahead of start_lobby by prebuild_level: {seed, shift, wing_gen, level, info}.
var _prebuilt := {}


## Build the hospital for (seed, shift) without blocking frames, so the loading screen keeps
## animating: map generation, mesh data and the navigation bake on a worker thread, then the nodes
## a few milliseconds per frame. The next start_lobby for the same seed and shift uses the result
## instead of building it again.
func prebuild_level(for_seed: int, for_shift: int) -> void:
	_discard_prebuilt()
	if not ResourceLoader.exists(MAPGEN_PATH) or not ResourceLoader.exists(BUILDER_PATH):
		return
	var MapGenScript: GDScript = load(MAPGEN_PATH)
	var BuilderScript: GDScript = load(BUILDER_PATH)
	# The same wing generation _build_level will ask the wing loader for, without consuming it.
	var wing_gen: int = wing_loader.next_generation if wing_loader.next_generation > 0 else for_shift
	BuilderScript.warm_parts()   # the thread reads the furniture mesh cache
	var job := {}
	var task := WorkerThreadPool.add_task(func():
		var gen: Dictionary = MapGenScript.generate(for_seed, MapGenScript.wing_seed_for(for_seed, wing_gen))
		job["gen"] = gen
		if gen.has("furniture"):
			job["prepared"] = BuilderScript.prepare_level(gen)
	, false, "level")
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if not job.has("prepared"):
		return   # an old-style map: start_lobby builds it the old way
	var info := {}
	var t0 := Time.get_ticks_msec()
	for step in BuilderScript.assemble_steps(job.gen, info, job.prepared):
		step.call()
		if Time.get_ticks_msec() - t0 >= PREBUILD_FRAME_MS:
			await get_tree().process_frame
			t0 = Time.get_ticks_msec()
	_prebuilt = {"seed": for_seed, "shift": for_shift, "wing_gen": wing_gen, "level": job.prepared.root, "info": info}


## Main-thread work per frame while prebuilding, milliseconds.
const PREBUILD_FRAME_MS := 12


func _discard_prebuilt() -> void:
	if not _prebuilt.is_empty() and is_instance_valid(_prebuilt.level):
		(_prebuilt.level as Node).free()
	_prebuilt = {}


func _build_level(for_seed: int) -> void:
	_clear_level()
	level_info = {}
	var gen: Dictionary = {}
	var mapgen_path := MAPGEN_PATH
	var builder_path := BUILDER_PATH
	if ResourceLoader.exists(mapgen_path) and ResourceLoader.exists(builder_path):
		var MapGenScript: GDScript = load(mapgen_path)
		var BuilderScript: GDScript = load(builder_path)
		# DOORS HOOK: the run's entrance building with this shift's wings (a joining client: the host's).
		var wing_gen: int = wing_loader.generation_for_build(shift)
		if not _prebuilt.is_empty() and int(_prebuilt.seed) == for_seed and int(_prebuilt.shift) == shift \
				and int(_prebuilt.wing_gen) == wing_gen:
			level = _prebuilt.level   # built behind the loading screen
			level_info = _prebuilt.info
			_prebuilt = {}
		else:
			_discard_prebuilt()
			gen = MapGenScript.generate(for_seed, MapGenScript.wing_seed_for(for_seed, wing_gen))
			level = BuilderScript.build(gen, level_info)
		level_info["wing_gen"] = wing_gen
	# A level missing its landmarks is worse than no level; fall back rather than ship a broken shift.
	if level == null or not _level_info_usable():
		if level != null:
			push_warning("Generated level for seed %d was incomplete; using the fallback ward." % for_seed)
			level.queue_free()
		level_info = {}
		var FallbackScript: GDScript = load("res://scripts/fallback_level.gd")
		level = FallbackScript.build(level_info)
	level.name = "Level"
	add_child(level)
	_attach_light_flicker(level)
	_add_occluders()
	_add_landmarks()
	# DOORS HOOK: the level's doors and the wings' generation.
	doors.clear()
	doors.register(level_info.get("door_nodes", []))
	wing_loader.on_level_built(level_info)
	pockets.finish_now()   # POCKETS HOOK: a whole level (a loading screen) does not wait frames for its pocket
	dev.on_level_built()   # DEV HOOK: the supply closet's locked door; the hidden room again if dev mode is on


func _level_info_usable() -> bool:
	return level_info.get("player_spawns", []).size() >= 1 \
		and level_info.get("tool_spawns", []).size() >= Items.SURGICAL.size() \
		and level_info.get("monster_spawns", []).size() >= 1 \
		and level_info.has("table") and level_info.has("clock")


## Ceiling fixtures flicker, buzz and die. The behaviour lives in the look pass;
## here we just hand each one its controller.
func _attach_light_flicker(root: Node) -> void:
	var path := "res://scripts/light_flicker.gd"
	if not ResourceLoader.exists(path):
		return
	var Flicker: GDScript = load(path)
	for node in root.find_children("*", "Light3D", true, false):
		if not node.is_in_group("fixture"):
			continue
		if not node.has_meta("seed"):
			node.set_meta("seed", hash(str(seed_value) + str(node.get_path())))
		# A hospital's worth of fixtures is too many to light at once on a laptop.
		# Anything well past the fog's reach contributes nothing you can see.
		node.distance_fade_enabled = true
		node.distance_fade_begin = 16.0
		node.distance_fade_length = 6.0
		node.add_child(Flicker.new())


## Walls, as a occluder mesh. Indoors this is the single biggest performance win:
## without it the renderer draws the entire hospital from inside one corridor.
func _add_occluders() -> void:
	var rows: PackedStringArray = level_info.get("rows", PackedStringArray())
	if rows.is_empty() or level_info.get("occluders_built", false):   # DOORS HOOK: the hospital builds its own per part
		return
	var h := rows.size()
	var w: int = rows[0].length()
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for ty in h:
		for tx in w:
			if rows[ty][tx] != "#":
				continue
			for d in dirs:
				var nx: int = tx + d.x
				var ny: int = ty + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				if rows[ny][nx] == "#":
					continue  # interior face, never visible
				# The quad on this tile's boundary facing the open neighbour.
				var cx := (tx + 0.5) * C.TILE
				var cz := (ty + 0.5) * C.TILE
				var half := C.TILE * 0.5
				var ox: float = d.x * half
				var oz: float = d.y * half
				var ax: float = half if d.x == 0 else 0.0
				var az: float = half if d.y == 0 else 0.0
				var base := verts.size()
				verts.append(Vector3(cx + ox - ax, 0.0, cz + oz - az))
				verts.append(Vector3(cx + ox + ax, 0.0, cz + oz + az))
				verts.append(Vector3(cx + ox + ax, C.WALL_H, cz + oz + az))
				verts.append(Vector3(cx + ox - ax, C.WALL_H, cz + oz - az))
				# Two triangles, both windings: an occluder is not lit, so facing does not matter,
				# and doubling them keeps the rasteriser from missing a wall seen from behind.
				for t in [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]:
					idx.append(base + t)
	if verts.is_empty():
		return
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var node := OccluderInstance3D.new()
	node.name = "WallOccluders"
	node.occluder = occ
	level.add_child(node)


func _clear_level() -> void:
	if pockets != null:
		pockets.teardown()   # POCKETS HOOK
	if level != null and is_instance_valid(level):
		level.queue_free()
	level = null
	shelf_node = null
	patient_tables = []
	player_table = {}
	if downed_view != null:
		downed_view.reset()


## Where players start a run and get up after dying: the neutral area outside when the level has
## one (loop), else the level's player spawns.
func spawn_points() -> Array:
	var neutral: Dictionary = level_info.get("neutral", {})
	var spots: Array = neutral.get("spawn_points", [])
	if not spots.is_empty():
		return spots
	return level_info.get("player_spawns", [Vector3.ZERO])


## The first patient table (level_info.table).
func table_pos() -> Vector3:
	return level_info.get("table", Vector3.ZERO)


# ---- tables (loop, sweep 2) ----

## Position of a table by its index into level_info.tables (the first patient table for -1).
func table_position(index: int) -> Vector3:
	for t in patient_tables:
		if int(t.index) == index:
			return t.position
	var all: Array = level_info.get("tables", [])
	if index >= 0 and index < all.size():
		return all[index].get("position", table_pos())
	return table_pos()


func table_yaw_of(index: int) -> float:
	for t in patient_tables:
		if int(t.index) == index:
			return float(t.yaw)
	return _table_yaw()


## The interact_id of a patient table's aim proxy: "table" for the first, "table_<index>" after.
func table_interact_id(index: int) -> String:
	if patient_tables.is_empty() or int(patient_tables[0].index) == index:
		return "table"
	return "table_%d" % index


## The index of the first patient table nobody lies on or is being wheeled to, or -1.
func free_patient_table() -> int:
	for t in patient_tables:
		if case_on_table(int(t.index)).is_empty() and not loop.table_reserved(int(t.index)):
			return int(t.index)
	return -1


func surgery_for_table(index: int) -> Node:
	for i in patient_tables.size():
		if int(patient_tables[i].index) == index and i < surgeries.size():
			return surgeries[i]
	return null


func body_for_table(index: int) -> Node3D:
	var e: Dictionary = _bodies.get(index, {})
	var n = e.get("node")
	return n if n != null and is_instance_valid(n) else null


func _surgery_view() -> Node:
	for s in surgeries:
		if s.camera() != null:
			return s
	var c := _alias_case()
	if not c.is_empty():
		var s := surgery_for_table(int(c.get("table", -1)))
		if s != null:
			return s
	return surgeries[0] if not surgeries.is_empty() else null


## Host: `p` stops operating at every table (hit, shoved, gone), the player table included.
func end_operations(p: Node) -> void:
	for s in surgeries:
		s.end(p)
	if player_surgery != null:
		player_surgery.end(p)


func _ensure_surgeries(n: int) -> void:
	while surgeries.size() < n:
		var s: Node = SurgeryScript.new()
		s.name = "Surgery" if surgeries.is_empty() else "Surgery%d" % surgeries.size()
		add_child(s)
		s.setup(self)
		surgeries.append(s)
	for i in surgeries.size():
		surgeries[i].table_index = int(patient_tables[i].index) if i < patient_tables.size() else -1


## The patient tables: level_info.tables (kind "patient") when the level has them; otherwise the
## level's one table plus a second one this places beside it (level_info.tables is then filled in
## with both, and `tables_fallback` set).
func _setup_tables() -> void:
	patient_tables = []
	var all: Array = level_info.get("tables", [])
	if all.is_empty():
		all = [{"position": table_pos(), "yaw": _table_yaw(), "kind": "patient"}]
		level_info["tables"] = all
	var n_patient := 0
	for t in all:
		if String(t.get("kind", "patient")) == "patient":
			n_patient += 1
	if n_patient < 2:
		# A level with one patient table (the dev room, the fallback ward, old maps) gets a second.
		level_info["tables_fallback"] = true
		var second: Dictionary = TablesScript.place_second(self, level, table_pos(), _table_yaw(), level_info)
		if not second.is_empty():
			all.append(second)
	for i in all.size():
		if String(all[i].get("kind", "patient")) == "patient":
			patient_tables.append({"index": i, "position": all[i].get("position", table_pos()), "yaw": float(all[i].get("yaw", 0.0))})
	_ensure_surgeries(maxi(1, patient_tables.size()))


func clock_pos() -> Vector3:
	return level_info.get("clock", Vector3.ZERO)


## The OR supply shelf and the aimable spots for the time clock, the table and the player table.
func _add_landmarks() -> void:
	var sinfo: Dictionary = level_info.get("shelf", {})
	var spos: Vector3 = sinfo.get("position", table_pos() + Vector3(2.2, 0.0, 1.4))
	shelf_node = ShelfScript.create()
	level.add_child(shelf_node)
	shelf_node.global_position = spos
	shelf_node.rotation.y = float(sinfo.get("yaw", 0.0))
	shelf_node.show_stock(shelf)

	# loop: the patient tables (a second one beside the first on levels with only one) and the
	# break-room phone, before the economy looks for free floor.
	_setup_tables()
	loop.on_level_built(level, level_info)

	# pharmacy (chunk 3): the pharmacy window and the furnace (placed once physics has the level).
	economy.on_level_built(level, level_info)

	_add_proxy("clock", clock_pos() + Vector3.UP * 1.1, 0.7, C.PUNCH_SECONDS,
		func(p): return loop.clock_prompt(p))
	for t in patient_tables:
		var ti := int(t.index)
		_add_proxy(table_interact_id(ti), (t.position as Vector3) + Vector3.UP * 1.1, 1.2, 0.0,
			func(p): return _table_prompt(p, ti))
	_add_player_table()  # downed: the OR's player table
	# Terminal redesign: E on the projector hung across the break room switches it on and off.
	var wt := wall_terminal()
	if wt != null:
		wt.set_on(projector_on)
		_add_proxy("projector", wt.projector_position(), 0.45, 0.0,
			func(_p): return "Turn the projector off" if projector_on else "Turn the projector on")


class Proxy extends Area3D:
	var hold: float = 0.0
	var prompt_fn: Callable
	func interact_prompt(p) -> String: return prompt_fn.call(p)
	func interact_hold() -> float: return hold
	func interact(p) -> void:
		var g = get_tree().get_first_node_in_group("game")
		if g != null:
			g._proxy_used(get_meta("interact_id"), p)


func _add_proxy(id: String, pos: Vector3, radius: float, hold: float, prompt_fn: Callable) -> void:
	var a := Proxy.new()
	a.name = "Aim_%s" % id
	a.hold = hold
	a.prompt_fn = prompt_fn
	a.collision_layer = C.L_INTERACT
	a.collision_mask = 0
	a.monitoring = false
	a.add_to_group("interactable")
	a.set_meta("interact_id", id)
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = radius
	cs.shape = sph
	a.add_child(cs)
	level.add_child(a)
	a.global_position = pos


func _table_prompt(p, table_index: int) -> String:
	if phase != Phase.SHIFT:
		return ""
	if downed_any_table and p != null:
		if p.carrying != 0 and not corpses.is_body(p.carrying):
			return _downed_place_prompt(p, table_index)
		if int(player_table.get("index", -1)) == table_index:
			return player_surgery.operate_prompt(p)
	var c := case_on_table(table_index)
	if c.is_empty() or String(c.get("patient_id", "")) == "player":
		return ""
	# Patient exits: a body waiting for the furnace (a patient or a dissected monster).
	if p != null and corpses.is_corpse(c):
		return corpses.lift_prompt(p, c)
	if dissection.owns_case(c):
		return dissection.table_prompt(p, table_index)   # SWEEP 3 HOOK (dissection): re-dose / sedation
	var pname: String = Procedures.patient(String(c.patient_id)).get("name", "The patient")
	if String(c.state) == "stable":
		return "!%s is stable." % pname
	if String(c.state) == "dead":
		return "!%s did not make it." % pname
	var step := Procedures.step(c.ailment_id, int(c.step_index))
	var sys := surgery_for_table(table_index)
	if step.is_empty() or sys == null:
		return ""
	var why: String = sys.can_begin(p)
	if why != "":
		return "!" + why
	return "Operate: %s" % step.label


## Room-bound lighting: every mesh and light that joins the level (built with it, or added later, like
## the economy's props, the OR monitors, the phone) is put on its area's bits at the end of the frame.
func _on_node_added(n: Node) -> void:
	if not (n is VisualInstance3D) or level == null or not is_instance_valid(level) or not level.is_ancestor_of(n):
		return
	if _light_queue.is_empty():
		_flush_light_queue.call_deferred()
	_light_queue.append(n)


func _flush_light_queue() -> void:
	var grid: Dictionary = level_info.get("light_grid", {})
	var queue := _light_queue
	_light_queue = []
	if grid.is_empty():
		return
	for n in queue:
		if not is_instance_valid(n) or not (n as Node).is_inside_tree() or _light_skip(n):
			continue
		if n is Light3D:
			if not (n is DirectionalLight3D):
				(n as Light3D).light_cull_mask = ((n as Light3D).light_cull_mask & ~LightRoomsScript.ALL) \
						| LightRoomsScript.light_mask(grid, (n as Node3D).global_position) | LightRoomsScript.DYNAMIC
		elif (n as VisualInstance3D).layers == LightRoomsScript.DYNAMIC and not (n is Decal) and not (n is ReflectionProbe):
			(n as VisualInstance3D).layers = LightRoomsScript.mask_at(grid, (n as Node3D).global_position)


## Things that move (marked "light_dynamic"), a wing set still loading ("light_pending", the wing
## loader places those itself) and anything inside a SubViewport keep their own layers.
static func _light_skip(n: Node) -> bool:
	var p := n
	while p != null:
		if p.has_meta("light_dynamic") or p.has_meta("light_pending") or p is SubViewport:
			return true
		p = p.get_parent()
	return false


## The level's wall terminal (the break room projector and its screen), or null.
func wall_terminal() -> Node3D:
	var sb = level_info.get("lectern_node")
	if sb == null or not is_instance_valid(sb):
		return null
	for c in (sb as Node).get_children():
		if c.is_in_group("wall_terminal"):
			return c
	return null


func _set_projector(value: bool) -> void:
	projector_on = value
	var wt := wall_terminal()
	if wt != null:
		wt.set_on(value)


func _proxy_used(id: String, p: Node) -> void:
	if id == "projector":
		if is_host():
			_set_projector(not projector_on)
			var wt := wall_terminal()
			if wt != null:
				_sound("click", wt.projector_position())
		return
	if id == "player_table":
		_player_table_used(p)   # downed
		return
	if not id.begins_with("table") or phase != Phase.SHIFT:
		return
	for t in patient_tables:
		if table_interact_id(int(t.index)) != id:
			continue
		if downed_any_table and int(player_table.get("index", -1)) == int(t.index):
			player_surgery.begin(p)   # the downed teammate lying on this table
			return
		if corpses.is_corpse(case_on_table(int(t.index))):
			return   # patient exits: a body is lifted with a hold (_tick_carry_holds), a tap does nothing
		if dissection.table_used(p, int(t.index)):
			return   # SWEEP 3 HOOK (dissection): anesthetic in hand re-doses a strapped monster
		var sys := surgery_for_table(int(t.index))
		if sys == null:
			return
		var why: String = sys.can_begin(p)
		if why == "":
			sys.begin(p)
		else:
			tell(p, why)
		return


func find_interactable(id: String) -> Node:
	if id == "":
		return null
	for n in get_tree().get_nodes_in_group("interactable"):
		if n.has_meta("interact_id") and n.get_meta("interact_id") == id:
			return n
	return null


# =========================================================================
# players
# =========================================================================

func _on_roster_changed() -> void:
	if phase != Phase.MENU:
		_sync_players()


## One Player node per peer in the roster; spawn points are keyed by peer id so
## every machine puts everyone in the same place without talking about it.
func _sync_players() -> void:
	var ids := Net.peer_ids()
	for id in ids:
		if players.has(id):
			continue
		var p: CharacterBody3D = PlayerScene.new_player(id, Net.name_for(id), id == Net.my_id())
		players[id] = p
		_entities.add_child(p)
		_respawn_at_start(p)
		# net: joining mid-shift means watching until the next lobby.
		if is_host() and phase != Phase.LOBBY:
			_hold_until_next_shift(p)
			say("%s joined. They clock in at the next shift." % Net.name_for(id), 3.0)
		elif not is_host() and (_cl_state.get("pl", {}) as Dictionary).has(id):
			_pl_applied[id] = p.get_instance_id()
			p.apply_remote_full(_cl_state.pl[id])
	for id in players.keys():
		if not ids.has(id) and not players[id].is_bot:  # DEV HOOK: bots are not in the Net roster
			var gone: Node = players[id]
			if is_host():
				# net: a leaver's supplies land where they stood; an operation pauses for someone else.
				var dropped := _drop_hands_in_place(gone)
				end_operations(gone)
				_release_downed_links(gone)  # downed: whoever they carried lands; their carrier lets go
				_repl.erase(id)   # net: its replication record
				waiting_peers.erase(id)
				if phase == Phase.SHIFT:
					say("%s left the shift.%s" % [gone.player_name, " What they carried is on the floor." if dropped else ""], 3.0)
			gone.queue_free()
			players.erase(id)


func _respawn_at_start(p: Node) -> void:
	var spots := spawn_points()
	var idx: int = maxi(0, Net.peer_ids().find(p.peer_id))
	p.teleport(spots[idx % spots.size()])
	p.revive_full()


## Players on their feet: alive and not downed. Monsters, footsteps, perception and holds only
## consider these (monsters ignore downed players; see "Downed players" in docs/CONTRACTS.md).
func alive_players() -> Array:
	var out := []
	for p in players.values():
		if p.alive and not p.downed:
			out.append(p)
	return out


# =========================================================================
# interaction (host)
# =========================================================================

## Called by a Player on the host whenever its interact counter moved.
func player_pressed_interact(p: Node, target_id: String) -> void:
	if not is_host() or not p.alive:
		return
	var node := find_interactable(target_id)
	if node == null or not _within_reach(p, node):
		return
	if node.interact_hold() > 0.0:
		return  # holds are simulated every frame (the clock, picking up a downed teammate)
	if node.interact_prompt(p).begins_with("!") or node.interact_prompt(p) == "":
		return
	node.interact(p)


func _within_reach(p: Node, node: Node) -> bool:
	var eye: Vector3 = p.head.global_position
	var target: Vector3 = node.global_position if node is Node3D else eye
	return eye.distance_to(target) <= C.INTERACT_RANGE + 1.2


func _holding_aim(id: String) -> bool:
	for p in alive_players():
		if p.wants_interact and p.aim_id == id:
			var node := find_interactable(id)
			if node != null and _within_reach(p, node):
				return true
	return false


# =========================================================================
# items, hands and the shelf (host)
# =========================================================================

func _spawn_item(kind: String, count: int, xf: Transform3D, state: int, ct_id := "", slot := 0, anchor := -1) -> Node:
	var it: WorldItem = WorldItemScript.new_item(_next_item_id, kind, count)
	_next_item_id += 1
	it.container_id = ct_id
	it.slot = slot
	it.anchor = anchor
	world_items[it.item_id] = it
	_entities.add_child(it)
	it.place(xf, state)
	return it


func _clear_items() -> void:
	for it in world_items.values():
		if is_instance_valid(it):
			it.queue_free()
	world_items.clear()
	_shift_item_ids.clear()
	_next_item_id = 0


## Host: the supplies for the first patient case (legacy name).
func _spawn_supplies() -> void:
	var c := _alias_case()
	if not c.is_empty():
		spawn_supplies_for(c)


## Host (loop): supplies for a newly accepted case. The shift's first case gets the spawner's full
## plan; a later one tops the hospital up so everything every live case still needs exists again,
## plus that case's own requirements on top (the same guard the softlock check uses).
func spawn_supplies_for(c: Dictionary) -> void:
	if not is_host() or c.is_empty() or String(c.get("patient_id", "")) == "player":
		return
	var others := 0
	for o in cases:
		if int(o.id) != int(c.get("id", -1)) and String(o.get("patient_id", "")) != "player":
			others += 1
	if others == 0:
		for e in SpawnerScript.plan(seed_value, shift, String(c.ailment_id), level_info):
			_spawn_from_plan(e)
		return
	var need := _live_requirements()
	for kind in Procedures.requirements(String(c.ailment_id)).keys():
		need[kind] = int(need.get(kind, 0)) + int(Procedures.requirements(String(c.ailment_id))[kind])
	var have := {}
	for kind in need.keys():
		have[kind] = supply_count(kind)
	var plan: Array = SpawnerScript.shortfall_plan(seed_value + 7907 * int(c.get("id", 1)) + shift * 97, need, have,
		level_info, _occupied_spots(), _avoid_points())
	for e in plan:
		_spawn_from_plan(e)


## What every live patient case (incoming or on a table) still needs, summed: kind -> count.
func _live_requirements() -> Dictionary:
	var need := {}
	for c in cases:
		var st := String(c.get("state", ""))
		if (st != "incoming" and st != "on_table") or String(c.get("patient_id", "")) == "player":
			continue
		var r := Procedures.remaining_requirements(String(c.ailment_id), int(c.step_index))
		for kind in r.keys():
			if Items.is_consumable(kind):
				need[kind] = int(need.get(kind, 0)) + int(r[kind])
			else:
				need[kind] = maxi(int(need.get(kind, 0)), int(r[kind]))
	return need


func _occupied_spots() -> Dictionary:
	var occupied := {}
	for it in world_items.values():
		if it.state == WorldItem.State.IN_CONTAINER:
			occupied["%s:%d" % [it.container_id, it.slot]] = true
		elif it.anchor >= 0:
			occupied["anchor:%d" % it.anchor] = true
	return occupied


func _avoid_points() -> Array:
	var avoid := []
	for p in players.values():
		avoid.append(p.global_position)
	for t in patient_tables:
		avoid.append(t.position)
	if patient_tables.is_empty():
		avoid.append(table_pos())
	return avoid


func _spawn_from_plan(e: Dictionary) -> Node:
	var it := _spawn_from_plan_inner(e)
	if it != null:
		_shift_item_ids[it.item_id] = true  # loop: cleared from the hospital at the next clock-in
	return it


func _spawn_from_plan_inner(e: Dictionary) -> Node:
	var anchors: Array = level_info.get("loose_anchors", [])
	var ct_id: String = String(e.get("container_id", ""))
	if ct_id != "":
		var ct := find_interactable(ct_id)
		if ct != null and ct.has_method("slot_transform"):
			var slot_i := int(e.get("slot", 0))
			return _spawn_item(e.kind, int(e.count), ct.slot_transform(slot_i), WorldItem.State.IN_CONTAINER, ct_id, slot_i)
	var anchor_i := int(e.get("anchor", -1))
	if anchor_i >= 0 and anchor_i < anchors.size():
		var a: Dictionary = anchors[anchor_i]
		var xf := Transform3D(Basis(Vector3.UP, float(a.get("yaw", 0.0))), a.position)
		return _spawn_item(e.kind, int(e.count), xf, WorldItem.State.LOOSE, "", 0, anchor_i)
	# inventory: a plan entry may carry its own floor position (loot on levels without anchors).
	if e.has("position"):
		var p: Vector3 = e.position
		return _spawn_item(e.kind, int(e.count), Transform3D(Basis(Vector3.UP, float(e.get("yaw", 0.0))), _floor_at(p)), WorldItem.State.LOOSE)
	# No container or anchor: drop it on the floor at a spawn point well away from the OR.
	var spots: Array = level_info.get("tool_spawns", [])
	var pos: Vector3 = spots[_rng.randi_range(0, spots.size() - 1)] if spots.size() > 0 else table_pos() + Vector3(4, 0, 0)
	return _spawn_item(e.kind, int(e.count), Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), _floor_at(pos)), WorldItem.State.LOOSE)


func pickup_item(p: Node, it: Node) -> void:
	if not is_host() or not is_instance_valid(it) or not world_items.has(it.item_id):
		return
	var i: int = p.take_into(it.kind, it.count, int(it.value))
	if i < 0:
		tell(p, "That needs two free hands." if Items.is_bulky(it.kind) else "Your hands are full.")
		return
	p.selected = i
	if float(it.bt) > -100000.0:
		p.slots[i]["bt"] = float(it.bt)   # SWEEP 3 HOOK (brains): the spoil clock travels with it
	var pos: Vector3 = it.global_position
	mark_db(String(it.kind), "sighted", p)   # wall terminal: an item this player has held shows in their database
	world_items.erase(it.item_id)
	it.queue_free()
	_sound("pickup", pos)
	emit_noise(pos, 0.15, "pickup")


## SWEEP 4A HOOK (pharmacy, chunk 3): a tap (charge ~0) still sets the selected stack down
## gently, same as before. Holding the drop key charges a real throw: the host runs the physics
## (toss()) and the item replicates like any other drop. A charged placebo pill is special: only
## one pill leaves the bottle (the rest stays in hand) and it is tracked for a mid-air hit.
const THROW_MIN_SPEED := 1.2
const THROW_MAX_SPEED := 11.0
const THROW_MIN_UP := 0.6
const THROW_MAX_UP := 2.6


func drop_selected(p: Node, charge: float = 0.0) -> void:
	if not is_host():
		return
	var head: int = p.selected_head()
	var s: Dictionary = p.slots[head]
	if s.kind == "":
		return
	charge = clampf(charge, 0.0, 1.0)
	var fwd: Vector3 = -p.camera.global_transform.basis.z
	var from := Transform3D(p.global_basis, p.head.global_position + fwd * 0.5 + Vector3.DOWN * 0.3)
	var speed: float = lerpf(THROW_MIN_SPEED, THROW_MAX_SPEED, charge)
	var up: float = lerpf(THROW_MIN_UP, THROW_MAX_UP, charge)
	var vel: Vector3 = fwd * speed + Vector3.UP * up + (p.velocity as Vector3) * 0.5
	# Placebo pills (3e): a charged throw fires a single pill and leaves the rest of the bottle in
	# hand; a tap drops the whole bottle like any other item.
	if String(s.kind) == "placebo_pills" and charge > 0.02 and int(s.count) > 0:
		var it := _spawn_item("placebo_pills", 1, from, WorldItem.State.LOOSE)
		it.value = 0
		it.set_meta("pill_thrown", true)
		it.set_meta("pill_thrower", p.peer_id)
		it.set_meta("pill_spawn_t", world_time)
		it.toss(from, vel)
		var left: int = int(s.count) - 1
		if left <= 0:
			p.clear_slot(head)
		else:
			p.slots[head].count = left
		_sound("thud", from.origin)
		return
	var it := _spawn_item(s.kind, s.count, from, WorldItem.State.LOOSE)
	it.value = int(s.get("v", 0))
	it.bt = float(s.get("bt", -1000000.0))   # SWEEP 3 HOOK (brains)
	it.toss(from, vel)
	p.clear_slot(head)
	_sound("thud", from.origin)
	emit_noise(from.origin, 0.4, "drop")


## Hit, shoved or gone: every hand lets go and fragile stacks lose some of their contents
## (fragile loot of one cracks and loses value instead).
func _drop_hands(p: Node, violent: bool) -> void:
	var broke := false
	var cracked := ""
	for i in p.slots.size():
		var s: Dictionary = p.slots[i]
		if s.kind == "":
			continue
		var n: int = s.count
		var v: int = int(s.get("v", 0))
		if violent:
			var survivors := Items.survivors_after_drop(s.kind, n)
			if Items.is_loot(s.kind):
				if survivors < n:
					v = roundi(float(v) * float(survivors) / float(maxi(1, n)))
				elif Items.is_fragile(s.kind) and v > 0:
					v = maxi(1, roundi(float(v) * LOOT_CRACK_KEEPS))
					cracked = Items.display_name(s.kind)
			broke = broke or survivors < n
			n = survivors
		var dir := Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)).normalized()
		var from := Transform3D(Basis(), p.global_position + Vector3.UP * 1.1 + dir * 0.3)
		var it := _spawn_item(s.kind, n, from, WorldItem.State.LOOSE)
		it.value = v
		it.bt = float(s.get("bt", -1000000.0))   # SWEEP 3 HOOK (brains)
		it.toss(from, dir * randf_range(2.0, 3.5) + Vector3.UP * 2.0)
		p.clear_slot(i)
		emit_noise(from.origin, 0.4, "drop")
	if broke or cracked != "":
		_sound("items_glass", p.global_position)
		emit_noise(p.global_position, 0.9, "glass")
	if broke:
		say("%s dropped the vials. Some of them smashed." % p.player_name, 3.0)
	elif cracked != "":
		say("%s dropped the %s. It cracked: worth less now." % [p.player_name, cracked.to_lower()], 3.0)


func shelf_place(p: Node) -> void:
	if not is_host():
		return
	var head: int = p.selected_head()
	var s: Dictionary = p.slots[head]
	if s.kind == "" or not Items.is_surgical(s.kind):
		return
	shelf[s.kind] = int(shelf.get(s.kind, 0)) + int(s.count)
	p.clear_slot(head)
	if shelf_node != null:
		shelf_node.show_stock(shelf)
		_sound("items_clink", shelf_node.global_position)
	say("%s put %s on the supply shelf." % [p.player_name, Items.display_name(s.kind)], 3.0)


func shelf_count(kind: String) -> int:
	return int(shelf.get(kind, 0))


## Everything of a kind that still exists anywhere: shelf, hands, floors and containers.
func supply_count(kind: String) -> int:
	var n := shelf_count(kind)
	for it in world_items.values():
		if it.kind == kind:
			n += it.count
	for p in players.values():
		for s in p.slots:
			if s.kind == kind:
				n += int(s.count)
	return n


## If breakage ever leaves the shift unwinnable, quietly put more supply somewhere far away.
func _check_supply() -> void:
	var need := _live_requirements()   # loop: every live case at once, the shelf is shared
	if need.is_empty():
		return
	var have := {}
	var short := false
	for kind in need.keys():
		have[kind] = supply_count(kind)
		if int(have[kind]) < int(need[kind]):
			short = true
	if not short:
		return
	var plan: Array = SpawnerScript.shortfall_plan(seed_value + shift * 97 + int(world_time), need, have, level_info, _occupied_spots(), _avoid_points())
	for e in plan:
		_spawn_from_plan(e)


# =========================================================================
# loot, money, the sell bin and the shop (inventory, sweep 2)
# =========================================================================

## Host: scatter sellable loot after the supplies (scripts/economy/loot_spawner.gd). Deterministic
## from the seed and shift; never on a spot a supply already took.
func spawn_loot() -> void:
	if not is_host():
		return
	var plan: Array = LootSpawnerScript.plan(seed_value, shift, level_info, _occupied_spots())
	for e in plan:
		var it := _spawn_from_plan(e)
		if it != null:
			it.value = int(e.get("value", 0))


## Host: change the team's money. Later systems call this too (patient pay, penalties); a
## negative amount can take money below zero only if `reason` starts with "debt:".
func add_money(amount: int, reason: String) -> void:
	if not is_host() or amount == 0:
		return
	money += amount
	if money < 0 and not reason.begins_with("debt:"):
		money = 0
	economy.on_money_changed(amount, reason)


## Host: game over. Money goes back to nothing.
func reset_money() -> void:
	if not is_host():
		return
	money = 0
	if economy != null:
		economy.on_reset()
	if brains != null:
		brains.on_reset()   # SWEEP 3 HOOK: absorbed brains go with the money


## SWEEP 4A HOOK (pharmacy, chunk 3): the flat price of one bottle of placebo pills. Never
## climbs, unlike the old gold bar (there is nothing else to buy yet).
const PILL_PRICE := 15
const PILL_COUNT := 10


## Hub rebuild, chunk 3: what the pharmacy's fax order form offers, in order. Placebo pills are all
## it stocks today; a new entry here shows up on the form. `count` and `price` are per set; the form
## orders 1 to PHARMACY_MAX_QTY sets of each.
const PHARMACY_MAX_QTY := 99
const PHARMACY_CATALOG := [
	{"kind": "placebo_pills", "name": "Placebo pills", "count": PILL_COUNT, "price": PILL_PRICE},
]


## Host: buy one bottle of placebo pills (tests, and the older callers): a one-item fax order.
func buy_pills(p: Node) -> bool:
	return order_pharmacy(p, ["placebo_pills"])


## Host: a faxed pharmacy order. `order` is {catalog kind: sets} (or an Array of kinds, one set each).
## False (and a message) without the money. Nothing appears in hand: the page prints behind the bars,
## the Night Nurse fetches the order and the pickup drawer slides out with it (economy_props.gd runs
## that timeline on every machine; only the host spawns the items, one stack per line).
func order_pharmacy(p: Node, order: Variant) -> bool:
	if not is_host():
		return false
	var sets := {}
	if order is Array:
		for k in order:
			sets[String(k)] = 1
	elif order is Dictionary:
		sets = order
	# DEV HOOK: the secret order. No money, no delivery: dev mode for everyone in the session.
	if int(sets.get("placebo_pills", 0)) == DEV_CODE:
		set_dev_tools(true, p)
		return true
	if economy == null or economy.pharmacy == null or not is_instance_valid(economy.pharmacy):
		return false
	var items: Array = []
	var total := 0
	for e in PHARMACY_CATALOG:
		var qty := clampi(int(sets.get(String(e.kind), 0)), 0, PHARMACY_MAX_QTY)
		if qty > 0:
			items.append({"kind": String(e.kind), "count": int(e.count) * qty})
			total += int(e.price) * qty
	if items.is_empty():
		return false
	if money < total:
		tell(p, "That order comes to $%d. The team has $%d." % [total, money])
		return false
	add_money(-total, "pharmacy:fax")
	say("%s faxed the pharmacy an order ($%d)." % [p.player_name if p != null else "Someone", total], 2.5)
	economy.pharmacy.queue_order(items)
	_broadcast("pharmacy_order", {"items": items})
	return true


## SWEEP 4A HOOK (pharmacy, chunk 3): the crematorium furnace (scripts/economy/furnace.gd) calls
## this once a thrown item lands in the fire. Sellable (loot, brains) pays out; anything else
## (surgical tools, the guide, pill bottles) is not sellable and the furnace bounces it back out
## instead of calling this. Placebo pills ARE sellable, for exactly $0 (3e).
func furnace_sell(kind: String, count: int, value: int, at: Vector3) -> void:
	if not is_host():
		return
	add_money(value, "furnace:%s" % kind)
	_sound("economy_sell", at)
	if value > 0:
		say("%s went into the furnace for $%d." % [Items.stack_label(kind, count), value], 2.5)


## SWEEP 4A HOOK (pharmacy, chunk 3): whether the furnace can sell a stack at all. Loot (including
## brains) and placebo pills are sellable; everything else (surgical tools, the guide) bounces
## back out unsold.
func furnace_can_sell(kind: String) -> bool:
	return Items.is_loot(kind) or kind == "placebo_pills"


## SWEEP 4A HOOK (pharmacy, chunk 3): what a stack is worth burned. Brains pay what they are worth
## now (spoilage); placebo pills always burn for $0; other loot pays its carried value.
func furnace_value(kind: String, s: Dictionary) -> int:
	if kind == "placebo_pills":
		return 0
	if brains != null and brains.is_brain(kind):
		return maxi(0, int(brains.current_value(s)))
	return maxi(0, int(s.get("v", 0)))


func _floor_at(p: Vector3) -> Vector3:
	return _surface_below(p + Vector3.UP * 1.5, p + Vector3.DOWN)


func _surface_below(from: Vector3, fallback: Vector3) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 4.0)
	q.collision_mask = C.L_WORLD
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if not hit.is_empty() else fallback


# =========================================================================
# the case on the table
# =========================================================================

## The case lying on a table (any state but incoming), {} when the table is free. Returns the live
## dictionary (host edits stick).
func case_on_table(table_index: int) -> Dictionary:
	if table_index < 0:
		return {}
	for c in cases:
		if int(c.get("table", -1)) == table_index and String(c.get("state", "")) != "incoming":
			return c
	return {}


func case_by_id(id: int) -> Dictionary:
	for c in cases:
		if int(c.get("id", -1)) == id:
			return c
	return {}


## Host: add a case; returns its id (-1 when refused: not the host, or the table holds a live case).
## A finished case (stable or dead) still lying on the requested table is removed first.
## Missing fields default: step 0, no flags, vitals 100, state "on_table" with a table else
## "incoming".
func add_case(c: Dictionary) -> int:
	if not is_host():
		return -1
	var table := int(c.get("table", -1))
	if table >= 0:
		var there := case_on_table(table)
		if not there.is_empty():
			if String(there.state) == "on_table":
				return -1
			cases.erase(there)
	var nc := {}
	for k in c.keys():
		nc[k] = c[k]
	nc["id"] = _next_case_id
	_next_case_id += 1
	nc["table"] = table
	nc["patient_id"] = String(c.get("patient_id", "bob"))
	nc["ailment_id"] = String(c.get("ailment_id", "gunshot"))
	nc["step_index"] = int(c.get("step_index", 0))
	nc["flags"] = (c.get("flags", {}) as Dictionary).duplicate(true)
	nc["vitals"] = float(c.get("vitals", 100.0))
	nc["state"] = String(c.get("state", "on_table" if table >= 0 else "incoming"))
	if c.has("player_id"):
		nc["player_id"] = int(c.player_id)
	cases.append(nc)
	_apply_cases_locally()
	return int(nc.id)


## Host: a case is over. Won: stable (stays on its table until the shift ends). Lost: dead.
func finish_case(id: int, won: bool) -> void:
	if not is_host():
		return
	var c := case_by_id(id)
	if c.is_empty() or String(c.state) == "stable" or String(c.state) == "dead":
		return
	c.state = "stable" if won else "dead"
	if not won:
		c.vitals = 0.0
	var operated_by := 0
	for s in surgeries:
		if int(s.table_index) == int(c.get("table", -2)) and s.operator_peer() != 0:
			operated_by = s.operator_peer()
	for s in surgeries:
		if int(s.table_index) == int(c.get("table", -2)):
			s.end_current()
	_apply_cases_locally()
	if dissection.owns_case(c):
		# SWEEP 3 HOOK (dissection): a strapped monster: the brain is handed over (or ruined) with its
		# own wording and no paycheck sting; the case clears itself a few seconds later.
		dissection.on_case_finished(c, won)
		loop.on_case_finished(c)
		return
	var pname: String = Procedures.patient(String(c.patient_id)).get("name", "The patient")
	if String(c.patient_id) == "player":
		pname = "The patient"
	var at := table_position(int(c.table)) if int(c.table) >= 0 else table_pos()
	if won:
		_sound("step_done", at)
		Audio.sting("saved")
		_broadcast("sting", {"cue": "saved"})
		say("%s is stable." % pname, 5.0)
	else:
		_sound("flatline", at)
		Audio.sting("flatline")
		_broadcast("sting", {"cue": "flatline"})
		say("%s flatlined." % pname, 5.0)
	if won and String(c.patient_id) != "player":
		loop.walkers.schedule(c, operated_by)   # patient exits: up off the table, thanks, out the doors
	loop.on_case_finished(c)


## Host: take a case out of the shift entirely.
func remove_case(id: int) -> void:
	if not is_host():
		return
	var c := case_by_id(id)
	if c.is_empty():
		return
	cases.erase(c)
	_apply_cases_locally()


## Index of the player table in level_info.tables, or -1. Levels without one in the data (the
## fallback second-table levels) get the downed worker's placed player table appended once it exists.
func player_table_index() -> int:
	if downed_any_table:
		return int(player_table.get("index", -1))
	var all: Array = level_info.get("tables", [])
	for i in all.size():
		if String(all[i].get("kind", "")) == "player":
			return i
	if bool(level_info.get("tables_fallback", false)) and not player_table.is_empty():
		all.append({"position": player_table.position, "yaw": float(player_table.get("yaw", 0.0)), "kind": "player"})
		return all.size() - 1
	return -1


## Host (loop + downed): the stitches operation on the player table runs in
## scripts/downed/player_surgery.gd; this mirrors it into `cases` as a `patient_id "player"` case
## (`mirror: true`) so it replicates with the others and the OR monitor lists it. The mirror is
## read-only: player_surgery stays the authority for the operation itself.
func _sync_player_case() -> void:
	var pc: Dictionary = player_surgery.case if player_surgery != null else {}
	var mirror := {}
	for c in cases:
		if bool(c.get("mirror", false)):
			mirror = c
			break
	if pc.is_empty():
		if not mirror.is_empty():
			cases.erase(mirror)
			_apply_cases_locally()
		return
	if mirror.is_empty():
		mirror = {"id": _next_case_id, "mirror": true, "patient_id": "player", "state": "on_table"}
		_next_case_id += 1
		cases.append(mirror)
	mirror["table"] = player_table_index()
	mirror["player_id"] = int(pc.get("player_id", 0))
	mirror["ailment_id"] = String(pc.get("ailment_id", "stitches"))
	mirror["step_index"] = int(pc.get("step_index", 0))
	mirror["flags"] = (pc.get("flags", {}) as Dictionary).duplicate(true)
	mirror["vitals"] = snappedf(float(player_surgery.vitals), 0.1)
	mirror["state"] = "stable" if Procedures.step(String(mirror.ailment_id), int(mirror.step_index)).is_empty() else "on_table"
	_apply_cases_locally()


func _alias_case() -> Dictionary:
	for c in cases:
		# Sweep 3 integration: a strapped monster is never "the patient" the legacy alias means.
		if String(c.get("patient_id", "")) != "player" and not bool(c.get("monster", false)):
			return c
	return {}


func _set_alias_case(v: Dictionary) -> void:
	var cur := _alias_case()
	if v.is_empty():
		if not cur.is_empty():
			cases.erase(cur)
		return
	if cur.is_empty():
		var t: int = int(patient_tables[0].index) if not patient_tables.is_empty() else 0
		var nc := v.duplicate(true)
		nc["id"] = _next_case_id
		_next_case_id += 1
		nc["table"] = int(v.get("table", t))
		nc["vitals"] = float(v.get("vitals", 100.0))
		nc["state"] = String(v.get("state", "on_table"))
		nc["step_index"] = int(v.get("step_index", 0))
		nc["flags"] = (v.get("flags", {}) as Dictionary).duplicate(true)
		cases.append(nc)
		return
	for k in v.keys():
		if k != "id":
			cur[k] = v[k]
	if not v.has("state"):
		cur["state"] = "on_table" if int(cur.get("table", -1)) >= 0 else "incoming"


## Build or update the patient bodies on the tables and the surgery systems to match `cases`.
## Runs on every machine; idempotent. (Old name kept: code all over calls it after editing `case`.)
func _apply_case_locally() -> void:
	_apply_cases_locally()


func _apply_cases_locally() -> void:
	var want := {}   # table index -> case
	for c in cases:
		var st := String(c.get("state", ""))
		if int(c.get("table", -1)) >= 0 and st != "incoming" and String(c.get("patient_id", "")) != "player":
			want[int(c.table)] = c
	for t in _bodies.keys():
		if not want.has(t):
			_free_body(t)
	for t in want.keys():
		var c: Dictionary = want[t]
		var key := "%d|%s|%s" % [int(c.get("id", 0)), c.patient_id, c.ailment_id]
		var e: Dictionary = _bodies.get(t, {})
		if String(e.get("key", "")) != key:
			_free_body(t)
			var pos := table_position(t)
			var top := _surface_below(pos + Vector3.UP * 3.0, pos + Vector3.UP * 0.95)
			var body: Node3D = BodyScript.create(String(c.patient_id))
			_entities.add_child(body)
			body.global_position = top
			body.rotation.y = table_yaw_of(t)
			if body.has_method("set_ailment"):
				body.set_ailment(String(c.ailment_id))
			e = {"key": key, "fk": "", "dead": false, "node": body}
			_bodies[t] = e
			var sys := surgery_for_table(t)
			if sys != null:
				sys.start_case(String(c.patient_id), String(c.ailment_id))
		var node = e.get("node")
		var fk := str(c.get("flags", {})) + str(c.get("step_index", 0))
		if fk != String(e.get("fk", "")) and node != null and is_instance_valid(node):
			e["fk"] = fk
			if node.has_method("apply_flags"):
				node.apply_flags(c.get("flags", {}))
		if String(c.state) == "dead" and not bool(e.get("dead", false)) and node != null and is_instance_valid(node):
			e["dead"] = true
			if node.has_method("flatline"):
				node.flatline()
	var sig := ""
	for c in cases:
		sig += "%d:%d:%s:%d:%s|" % [int(c.get("id", 0)), int(c.get("table", -1)), String(c.get("state", "")), int(c.get("step_index", 0)), String(c.get("ailment_id", ""))]
	if sig != _cases_sig:
		_cases_sig = sig
		cases_changed.emit()


func _free_body(t: int) -> void:
	var e: Dictionary = _bodies.get(t, {})
	var n = e.get("node")
	if n != null and is_instance_valid(n):
		n.queue_free()
	_bodies.erase(t)
	var sys := surgery_for_table(t)
	if sys != null:
		sys.clear_case()


## The operating table's long axis runs along world X unless the level says otherwise.
func _table_yaw() -> float:
	return float(level_info.get("table_yaw", 0.0))


func _clear_case() -> void:
	cases.clear()
	shelf = {}
	_apply_cases_locally()
	if player_surgery != null:
		player_surgery.reset()   # downed: nobody on the player table either
	_call_at.clear()
	if shelf_node != null and is_instance_valid(shelf_node):
		shelf_node.show_stock(shelf)


## The case a surgery report or call is about: the one on `table_index`, or the first patient
## case for -1.
func _case_for(table_index: int) -> Dictionary:
	return _alias_case() if table_index < 0 else case_on_table(table_index)


## Host: a surgery mistake. Costs vitals and nothing else. `table_index` -1 means the first
## patient case (the old single-table call).
func surgery_botch(amount: float, reason: String, table_index: int = -1) -> void:
	if not is_host() or phase != Phase.SHIFT:
		return
	var c := _case_for(table_index)
	if c.is_empty() or String(c.state) != "on_table":
		return
	c.vitals = float(c.vitals) - amount
	if reason != "" and _botch_say_timer <= 0.0:
		_botch_say_timer = 2.0
		say(reason, 1.8)
	if amount >= 0.5 and _complication_timer <= 0.0:
		_complication_timer = 1.2
		_sound("complication", table_position(int(c.table)))


## Host: the current step of a table's case is finished. Uses up its supplies, remembers its
## result, moves on; the last step makes the patient stable. `operator_peer` is whoever's report
## finished the step: the step's item can come off the shelf or straight out of their hands
## (can_begin() already accepted either), shelf first so a held item is only spent when the
## shared shelf falls short.
func surgery_step_done(result: Dictionary, table_index: int = -1, operator_peer: int = 0) -> void:
	if not is_host() or phase != Phase.SHIFT:
		return
	var c := _case_for(table_index)
	if c.is_empty() or String(c.state) != "on_table":
		return
	var step := Procedures.step(c.ailment_id, int(c.step_index))
	if step.is_empty():
		return
	var uses := int(step.uses)
	if uses > 0:
		var from_shelf: int = mini(shelf_count(step.item), uses)
		shelf[step.item] = maxi(0, shelf_count(step.item) - from_shelf)
		var remaining := uses - from_shelf
		if remaining > 0 and operator_peer != 0:
			var p = players.get(operator_peer)
			if p != null and p.has_method("consume_hand"):
				p.consume_hand(String(step.item), remaining)
	var flags: Dictionary = c.get("flags", {})
	flags.merge(result, true)
	c.flags = flags
	c.step_index = int(c.step_index) + 1
	c.vitals = minf(100.0, float(c.vitals) + 8.0)
	if shelf_node != null:
		shelf_node.show_stock(shelf)
	_apply_cases_locally()
	var next := Procedures.step(c.ailment_id, int(c.step_index))
	if next.is_empty():
		finish_case(int(c.id), true)
	else:
		_sound("step_done", table_position(int(c.table)))
		say("Done: %s. Next: %s (%s)." % [step.label, next.label, Items.display_name(next.item)], 4.0)


## Client operator -> host. On the host itself it goes straight to the surgery system. Reports
## carry "tb", the table index of the surgery system that sent them.
func send_operator_report(report: Dictionary) -> void:
	if is_host():
		_route_operator_report(Net.my_id(), report)
	elif Net.active:
		if report.has("botches") or report.has("finished") or report.has("exit") or report.has("reliable"):
			_rpc_operator_report_reliable.rpc_id(Net.HOST_ID, report)
		else:
			_rpc_operator_report.rpc_id(Net.HOST_ID, report)


func _route_operator_report(peer_id: int, report: Dictionary) -> void:
	var sys: Node = surgery_for_table(int(report.get("tb", -1))) if report.has("tb") else null
	if sys == null and not surgeries.is_empty():
		sys = surgeries[0]
	if sys != null:
		sys.receive_operator_report(peer_id, report)


## Terminal redesign, chunk 4: a guest's click, sign-in or database for the break room screen.
@rpc("any_peer", "reliable", "call_remote")
func _rpc_wall(kind: String, data: Dictionary) -> void:
	if is_host():
		wall.on_rpc(multiplayer.get_remote_sender_id(), kind, data)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_operator_report(report: Dictionary) -> void:
	if is_host():
		_route_operator_report(multiplayer.get_remote_sender_id(), report)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_operator_report_reliable(report: Dictionary) -> void:
	if is_host():
		_route_operator_report(multiplayer.get_remote_sender_id(), report)


# =========================================================================
# noise and perception (host)
# =========================================================================

func emit_noise(pos: Vector3, loudness: float, kind: String) -> void:
	if not is_host():
		return
	_noises.append({"pos": pos, "loudness": loudness, "kind": kind, "time": world_time})
	# POCKETS HOOK: sound carries through seams (the same noise in the other copy of a nearby stub).
	if pockets != null:
		for p in pockets.mirror_noise(pos, loudness):
			_noises.append({"pos": p, "loudness": loudness, "kind": kind, "time": world_time, "mirrored": true})


func recent_noises(max_age: float = 1.5) -> Array:
	var out := []
	for n in _noises:
		if world_time - float(n.time) <= max_age:
			out.append(n)
	return out


func _tick_noise(delta: float) -> void:
	var cut := world_time - NOISE_MEMORY
	while not _noises.is_empty() and float(_noises[0].time) < cut:
		_noises.pop_front()
	for p in alive_players():
		# SWEEP 4A HOOK (controls): a crouching player's footsteps make no sound and no noise event
		# at all (not just quieter): the Discharged can't hear a crouching player walk.
		if not p.moving or bool(p.get("crouching")):
			_footstep_acc[p.peer_id] = 0.0
			continue
		var acc: float = float(_footstep_acc.get(p.peer_id, 0.0)) + delta
		var interval := 0.3 if p.sprinting else 0.5
		if acc >= interval:
			acc = 0.0
			emit_noise(p.global_position, 0.8 if p.sprinting else 0.25, "footstep")
		_footstep_acc[p.peer_id] = acc


## Any living surgeon's flashlight shining on this point.
func point_is_lit(p: Vector3) -> bool:
	for pl in players.values():
		if pl.alive and pl.lights_point(p):
			return true
	return false


# =========================================================================
# monsters
# =========================================================================

func _spawn_monsters() -> void:
	_clear_monsters(true)
	if dev_on() and dev.monsters_off:
		return   # DEV HOOK: the panel's "No monsters"
	var roster: Array = MonsterScript.roster(shift, players.size())
	var spots: Array = level_info.get("monster_spawns", []).duplicate()
	_shuffle(spots, _rng)
	# SWEEP 3 HOOK (monsters): Walk-Ins go in groups near the start of each wing (Monster.walk_in_spots).
	var others: Array = roster.filter(func(k): return k != MonsterScript.WALK_IN)
	for i in others.size():
		var pos: Vector3 = spots[i % maxi(1, spots.size())] if spots.size() > 0 else Vector3.ZERO
		_add_monster(others[i], pos)
	var walk_ins: Array[Vector3] = MonsterScript.walk_in_spots(level_info, roster.size() - others.size(), _rng, get_world_3d().direct_space_state)
	for pos in walk_ins:
		_add_monster(MonsterScript.WALK_IN, pos)


## loop: may a wandering monster pick this point? Not inside the entrance building or the neutral
## area outside (HospitalBuilder.zone_of); noise and chases still lead them anywhere.
func monster_may_wander_to(p: Vector3) -> bool:
	if not level_info.has("zones"):
		return true
	var zone := HospitalZones.zone_of(level_info, p)
	return zone != "entrance" and zone != "neutral"


func _add_monster(kind: String, pos: Vector3) -> Node:
	var m: CharacterBody3D = MonsterScript.new_monster(_next_monster_id, kind, pos)
	monsters[_next_monster_id] = m
	_next_monster_id += 1
	_entities.add_child(m)
	return m


## `keep_dev_room`: the monsters in the hidden dev room's pen stay (a new shift's monsters coming in).
func _clear_monsters(keep_dev_room := false) -> void:
	if combat != null:
		combat.on_monsters_cleared()   # SWEEP 3 HOOK: nobody is dragging a monster any more
	var kept := {}
	for id in monsters.keys():
		var m = monsters[id]
		if keep_dev_room and is_instance_valid(m) and dev.in_room(m.global_position):
			kept[id] = m
			continue
		if is_instance_valid(m):
			m.queue_free()
	monsters.clear()
	monsters.merge(kept)
	if kept.is_empty():
		_next_monster_id = 0


# =========================================================================
# frame
# =========================================================================

func _physics_process(delta: float) -> void:
	if phase == Phase.MENU:
		return
	if paused and Net.solo:
		return
	world_time += delta
	message_timer = maxf(0.0, message_timer - delta)
	_botch_say_timer = maxf(0.0, _botch_say_timer - delta)
	_complication_timer = maxf(0.0, _complication_timer - delta)

	if is_host():
		_simulate(delta)
	for s in surgeries:
		s.physics_tick(delta)
	player_surgery.physics_tick(delta)  # downed
	for t in _bodies.keys():
		var body := body_for_table(int(t))
		if body == null:
			continue
		var c := case_on_table(int(t))
		if body.has_method("set_vitals"):
			body.set_vitals(float(c.get("vitals", 100.0)))
		if body.has_method("set_sedation"):
			body.set_sedation(float(c.get("flags", {}).get("sedation", 0.0)))
	loop.physics_tick(delta)
	# SWEEP 3 HOOK: every machine; each system does its host-only work behind is_host().
	combat.physics_tick(delta)
	dissection.physics_tick(delta)
	brains.physics_tick(delta)
	doors.physics_tick(delta)   # DOORS HOOK: every machine; the host decides, clients animate

	_update_danger()
	_net_tick(delta)


## SWEEP 4A HOOK (scanner): this species' record, created on first touch.
func db_record(kind: String) -> DbRecord:
	if not database.has(kind):
		database[kind] = DbRecordScript.new(kind)
	return database[kind]


## Host: player `p` sighted / scanned / harvested `kind` ("sighted" / "scanned" / "harvested"). It
## lands in that player's own database: the host's own player's straight away, a guest's by an event
## to their machine (which saves it). `p` null: every player in the game (a harvest off the table is
## the team's). Bots have no database.
func mark_db(kind: String, field: String, p: Node = null) -> void:
	if not is_host():
		return
	var who: Array = [p] if p != null else players.values()
	for q in who:
		if q == null or not is_instance_valid(q) or bool(q.get("is_bot")):
			continue
		if bool(q.is_local):
			mark_own_db(kind, field)
		elif Net.active and multiplayer.get_peers().has(int(q.peer_id)):
			_event.rpc_id(int(q.peer_id), "db_update", {"kind": kind, "field": field})


## Every machine: set a field in this machine's player's own database, saving on the first flip.
func mark_own_db(kind: String, field: String) -> void:
	var rec := db_record(kind)
	if not bool(rec.get(field)):
		rec.set(field, true)
		DatabaseStoreScript.save(database)
		if wall != null:
			wall.own_db_changed()   # signed in on the break room screen: it shows the change


## A scan target by id: a monster (id >= 0) or a scan prop (negative id), null when gone.
func scan_target_node(id: int) -> Node3D:
	if id >= 0:
		var m = monsters.get(id)
		return m if m != null and is_instance_valid(m) else null
	for sp in scan_props:
		if is_instance_valid(sp) and int(sp.scan_id) == id:
			return sp
	return null


func _scan_targets() -> Array:
	var out: Array = []
	for m in monsters.values():
		if m != null and is_instance_valid(m):
			out.append(m)
	for sp in scan_props:
		if is_instance_valid(sp):
			out.append(sp)
	return out


static func _scan_id_of(t: Node) -> int:
	return int(t.monster_id) if "monster_id" in t else int(t.scan_id)


## Host: is `p` aiming at `m`, in scan range, with a clear shot (a straight raycast from the
## camera: if a wall is in the way, the ray hits the wall first, not the monster)?
func _scan_aim(p: Node, m: Node) -> bool:
	if p == null or m == null or not is_instance_valid(m) or p.camera == null:
		return false
	var from: Vector3 = p.camera.global_position
	var dir: Vector3 = -p.camera.global_transform.basis.z
	# HANDS HOOK: the shoulder camera is local-only and not replicated, so this only ever
	# straightens the ray for the host's own local player (carry_cam is null on the host for
	# everyone else) -- the same correction Player._update_scan_progress applies locally.
	if "carry_cam" in p and p.carry_cam != null and p.carry_cam.active:
		var seg: Array = p.carry_cam.aim_segment(C.SCAN_RANGE)
		from = seg[0]
		dir = ((seg[1] as Vector3) - from).normalized()
	var to_m: Vector3 = (m.global_position as Vector3) + Vector3.UP * 1.0
	if from.distance_to(to_m) > C.SCAN_RANGE:
		return false
	var hit: Dictionary = Player.scan_ray(get_world_3d().direct_space_state, from, from + dir * C.SCAN_RANGE, [p.get_rid()])
	if hit.is_empty():
		return false
	var col = hit.get("collider")
	return col == m or (col is Node and (col as Node).get_parent() == m)   # a scan prop's body is its child


## Host: hold R aiming at a monster (in range, in sight) to scan it; breaking either resets
## progress. A completed scan marks the species scanned; the scanner's own machine shows it (scan_fx.gd).
## Also tracks "sighted": a monster within scan range and visible (aimed at is not required) to
## any living player, regardless of whether anyone is scanning.
func _tick_scan(delta: float) -> void:
	var targets := _scan_targets()
	for m in targets:
		for p in alive_players():
			if p.camera != null and p.camera.global_position.distance_to(m.global_position) <= C.SCAN_RANGE \
					and Perception.in_view(p, m.global_position) and _scan_aim(p, m):
				mark_db(String(m.kind), "sighted", p)   # each player's own database
	for p in alive_players():
		var peer: int = p.peer_id
		var target: Node = null
		if bool(p.get("scan_holding")):
			var cur: Node3D = scan_target_node(int(_scan_target.get(peer, -1))) if int(_scan_target.get(peer, -1)) != -1 else null
			target = cur if cur != null and _scan_aim(p, cur) else null
			if target == null:
				for m in targets:
					if _scan_aim(p, m):
						target = m
						break
		if target == null:
			_scan_progress[peer] = 0.0
			_scan_target[peer] = -1
			continue
		_scan_target[peer] = _scan_id_of(target)
		var prog: float = float(_scan_progress.get(peer, 0.0)) + delta / C.SCAN_SECONDS
		if prog >= 1.0:
			_scan_progress[peer] = 0.0
			mark_db(String(target.kind), "scanned", p)
		else:
			_scan_progress[peer] = prog


func _simulate(delta: float) -> void:
	_tick_noise(delta)
	_tick_scan(delta)   # SWEEP 4A HOOK (scanner)
	var pop: int = player_surgery.operator_peer()   # downed: operating on the player table counts too
	for p in players.values():
		p.operating = pop != 0 and p.peer_id == pop
	for s in surgeries:
		var op: int = s.operator_peer()
		if op != 0 and players.has(op):
			players[op].operating = true
	if phase != Phase.MENU:
		_tick_downed(delta)
		_tick_carry_holds(delta)
		_sync_player_case()   # loop: the player table's operation as a "player" case
	match phase:
		Phase.LOBBY:
			_sim_lobby(delta)
		Phase.SHIFT:
			_sim_shift(delta)
		Phase.WON, Phase.LOST:
			end_timer -= delta
			if end_timer <= 0.0:
				if phase == Phase.WON:
					_to_next_shift()
				else:
					_new_run()


func _sim_lobby(delta: float) -> void:
	if clock_in_pending and wing_loader.wings_ready and not pockets.busy:   # POCKETS HOOK
		clock_in()   # DOORS HOOK: the wings finished while the team waited at the clock
		return
	if _holding_aim("clock"):
		punch = minf(1.0, punch + delta / C.PUNCH_SECONDS)
		if punch >= 1.0:
			punch = 0.0
			clock_in()
	else:
		punch = maxf(0.0, punch - delta * 1.5)


func _sim_shift(delta: float) -> void:
	# Every patient on a table is always dying.
	var drain: float = C.VITALS_DRAIN_SECONDS * pow(0.85, shift - 1)
	for c in cases.duplicate():
		if String(c.get("state", "")) != "on_table" or String(c.get("patient_id", "")) == "player":
			continue
		if dissection.owns_case(c):
			continue   # SWEEP 3 HOOK: a strapped monster's vitals are its brain's condition (no drain)
		c.vitals = float(c.vitals) - delta * 100.0 / drain
		if float(c.vitals) <= 0.0:
			c.vitals = 0.0
			finish_case(int(c.id), false)

	_supply_timer -= delta
	if _supply_timer <= 0.0:
		_supply_timer = SUPPLY_CHECK_SECONDS
		_check_supply()

	# loop: the time clock ends the shift once every accepted patient is stable or dead.
	if loop.can_clock_out() and _holding_aim("clock"):
		punch = minf(1.0, punch + delta / C.PUNCH_SECONDS)
		if punch >= 1.0:
			punch = 0.0
			loop.clock_out(false)
			return
	else:
		punch = maxf(0.0, punch - delta * 1.5)

	# downed + loop: nobody left standing (every player downed or dead) is game over.
	if not (dev_tools and dev.no_game_over) and all_players_out():
		game_over("Everyone is down. The night shift is over.")


func _scatter_spot(from: Vector3) -> Vector3:
	for i in 24:
		var a := randf() * TAU
		var r := randf_range(1.0, 2.6)
		var candidate := from + Vector3(cos(a) * r, 0.0, sin(a) * r)
		if _point_is_clear(candidate):
			return candidate
	return from


func _point_is_clear(p: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.3
	q.shape = shape
	q.transform = Transform3D(Basis(), p + Vector3.UP * 0.4)
	q.collision_mask = C.L_WORLD
	return space.intersect_shape(q, 1).is_empty()


func _update_danger() -> void:
	var view := viewed_player()
	if view == null or phase != Phase.SHIFT:
		danger = 0.0
	else:
		var nearest := 999.0
		for m in monsters.values():
			if m.has_method("is_sedated") and m.is_sedated():
				continue   # sweep 3: an out-cold monster is no danger
			nearest = minf(nearest, m.global_position.distance_to(view.global_position))
		danger = clampf(1.0 - nearest / 14.0, 0.0, 1.0)
	Audio.heartbeat(danger)
	var hunting := false
	for m in monsters.values():
		if m.state == MonsterScript.State.CHASE:
			hunting = true
			break
	var operating := false
	for p in players.values():
		if p.operating:
			operating = true
			break
	var level_intensity := 0.0
	if phase == Phase.SHIFT:
		level_intensity = 2.0 if operating else (1.0 if hunting else minf(0.6, danger))
	Audio.set_music_intensity(level_intensity)


# =========================================================================
# damage
# =========================================================================

## Host only. A monster connected with a surgeon.
func monster_hit_player(m: Node, p: Node) -> void:
	if not is_host() or not p.alive or p.downed or p.invuln > 0.0:
		return
	if dev_on() and dev.is_god(p):
		return  # DEV HOOK: god mode
	var knock: Vector3 = (p.global_position - m.global_position).normalized() * m.knockback
	damage_player(p, m.damage, "monster:%s" % m.kind, knock)
	m.recoil_after_hit()


## Host only. Every hurt a player takes goes through here (monsters, the dev gun). `source` is
## free text for logs and messages ("monster:discharged", "dev_gun:<name>").
## Reaching 0 HP downs the player (down_player); nothing a hit does kills outright.
func damage_player(p: Node, amount: int, source: String, knock: Vector3 = Vector3.ZERO) -> void:
	if not is_host() or p == null or not is_instance_valid(p) or not p.alive or p.downed or amount <= 0:
		return
	p.take_hit(amount, knock)
	if combat != null and combat.has_method("cancel_windup"):
		combat.cancel_windup(p, "hit")   # HANDS HOOK: a hit cancels a wind-up with no strike
	_broadcast("hit", {"id": p.peer_id, "hp": p.hp, "knock": knock})
	Audio.play("hurt", p.global_position)
	_end_operations(p)
	_drop_hands(p, true)
	if p.carrying != 0:
		drop_carried(p)   # downed: getting hit drops whoever you carry
	combat.drop_dragged(p)   # SWEEP 3 HOOK (combat): and the monster you drag
	if p.hp <= 0:
		down_player(p, source, knock)


## Host only. Down a player at once, whatever their HP (the dev gun's secondary fire).
## `seconds` is ignored (kept from the dev room's stand-in signature).
func knock_down_player(p: Node, source: String, knock: Vector3 = Vector3.ZERO, _seconds: float = 3.0) -> void:
	if not is_host() or p == null or not is_instance_valid(p) or not p.alive or p.downed:
		return
	p.hp = 0
	p.apply_knock(knock)
	_broadcast("hit", {"id": p.peer_id, "hp": 0, "knock": knock})
	Audio.play("hurt", p.global_position)
	_end_operations(p)
	_drop_hands(p, true)
	down_player(p, source, knock)


## Host only. Remove a monster for good (the dev gun). Everyone sees it fall.
func kill_monster(m: Node) -> void:
	if not is_host() or m == null or not is_instance_valid(m) or not monsters.has(m.monster_id):
		return
	monsters.erase(m.monster_id)
	if combat != null:
		combat.on_monster_removed(m)   # SWEEP 3 HOOK
	var data := {"kind": m.kind, "pos": m.global_position, "y": m.rotation.y}
	m.queue_free()
	dev.monster_died_fx(data)
	_broadcast("monster_killed", data)


## Host only. Put a monster out of action for a while without killing it.
func knock_down_monster(m: Node, dir: Vector3 = Vector3.ZERO, seconds: float = 4.0) -> void:
	if not is_host() or m == null or not is_instance_valid(m):
		return
	m.shoved(dir)
	m.lunge_t = 0.0
	if m.brain != null and "timer" in m.brain and MonsterScript.is_capturable(m.kind):   # SWEEP 3 HOOK (monsters): the Walk-In too
		m.brain.timer = seconds   # the Discharged's shove stun, lengthened
	else:
		m.calm = maxf(m.calm, seconds)   # the Night Nurse ignores shoves: make it stand down
	_sound("thud", m.global_position)


# =========================================================================
# downed players, carrying and the player table (sweep 2 wave 3)
# =========================================================================
#
# 0 HP downs a player (never kills). Downed: alive but not standing, lying on the floor, crawling,
# bleeding out over BLEED_SECONDS, then dead until the next shift. Teammates hold E on them to carry
# them over the shoulder to the OR's player table, where the `stitches` step (a suture kit on the
# shelf) revives them with REVIVE_HP. Monsters ignore downed players. Everyone down or dead fails
# the shift (all_players_out). All host authoritative; state rides in Player.report_full.

## Host: end whatever operation p is doing, on either table.
func _end_operations(p: Node) -> void:
	end_operations(p)   # loop: every patient table and the player table


## True when nobody is left on their feet: every player (not waiting to join) is downed or dead.
func all_players_out() -> bool:
	var any := false
	for p in players.values():
		if waiting_peers.has(p.peer_id):
			continue
		any = true
		if p.alive and not p.downed:
			return false
	return any


## Host: p is down (0 HP). They keep living for BLEED_SECONDS unless someone stitches them up.
func down_player(p: Node, source: String, _knock: Vector3 = Vector3.ZERO) -> void:
	if not is_host() or p == null or not is_instance_valid(p) or not p.alive or p.downed:
		return
	if p.carrying != 0:
		drop_carried(p)
	p.hp = 0
	p.downed = true
	p.bleed = BLEED_SECONDS
	p.stun = 0.0
	p.carry_hold = 0.0
	p.operating = false
	_end_operations(p)
	_drop_hands(p, true)
	p.refresh_downed_visuals()
	_sound("downed_fall", p.global_position)
	if source.begins_with("dev_gun"):
		say("%s knocked %s down." % [source.get_slice(":", 1), p.player_name], 3.0)
	elif players.size() > 1:
		say("%s is down! Carry them to the OR table and stitch them up." % p.player_name, 4.0)
	else:
		say("You are down. Nobody is coming.", 4.0)


## Host: dead until the next shift (bled out, or the dev gun's primary fire).
func kill_player(p: Node, source: String) -> void:
	if not is_host() or p == null or not is_instance_valid(p) or not p.alive:
		return
	_release_downed_links(p)
	_end_operations(p)
	_drop_hands(p, true)
	p.hp = 0
	p.alive = false
	p.dead_time = 0.0
	p.operating = false
	p._clear_downed()
	p._set_visible_alive(false)
	p.refresh_downed_visuals()
	_broadcast("hit", {"id": p.peer_id, "hp": 0, "knock": Vector3.ZERO})
	_sound("flatline", p.global_position)
	if source.begins_with("dev_gun"):
		say("%s was deleted by %s." % [p.player_name, source.get_slice(":", 1)], 3.0)
	elif source == "bleed":
		say("%s bled out. They are back next shift." % p.player_name, 4.0)
	else:
		say("%s is dead." % p.player_name, 3.0)


## Host: a downed player is back on their feet with REVIVE_HP, standing beside the player table.
func revive_player(p: Node, _source: String = "stitches") -> void:
	if not is_host() or p == null or not is_instance_valid(p) or not p.alive or not p.downed:
		return
	var from: Vector3 = p.global_position
	if p.on_table and not player_table.is_empty():
		var b := Basis(Vector3.UP, player_table_yaw())
		from = (player_table.position as Vector3) + b * Vector3(0.0, 0.0, 1.1)
	_release_downed_links(p)
	var spot := _scatter_spot(from)
	p.teleport(spot)
	p.revive(REVIVE_HP)
	p.refresh_downed_visuals()
	_broadcast("revive", {"id": p.peer_id, "pos": spot, "hp": REVIVE_HP})
	_sound("revive", spot)
	say("%s is stitched up and back on their feet." % p.player_name, 4.0)


## Host: undo carrying and the table around p (it is dying, leaving, or getting up).
func _release_downed_links(p: Node) -> void:
	if p.carrying != 0:
		drop_carried(p)
	if p.carried_by != 0:
		var c = players.get(p.carried_by)
		if c != null and c.carrying == p.peer_id:
			drop_carried(c)
		p.carried_by = 0
	if p.on_table:
		p.on_table = false
		if player_surgery.patient() == p:
			player_surgery.clear()
		p.refresh_downed_visuals()


## How fast p's bleed clock runs (every machine): slower lying on the table.
func bleed_rate(p: Node) -> float:
	return TABLE_BLEED_K if p.on_table else 1.0


## Host: bleeding out.
func _tick_downed(_delta: float) -> void:
	for p in players.values():
		if not p.alive or not p.downed or p.bleed > 0.0:
			continue
		if dev_on() and dev.is_god(p):
			p.bleed = BLEED_SECONDS   # DEV HOOK: god mode never bleeds out
			continue
		kill_player(p, "bleed")


## Whether q may pick p up right now (hands aside when check_hands is false).
func can_pick_up(q: Node, p: Node, check_hands: bool = true) -> bool:
	if q == null or p == null or q == p or phase != Phase.SHIFT:
		return false
	if not q.alive or q.downed or q.carrying != 0 or q.carried_by != 0:
		return false
	if combat != null and combat.dragging(q) >= 0:
		return false   # SWEEP 3 HOOK (combat): hands full of monster
	if not p.alive or not p.downed or p.carried_by != 0 or p.on_table:
		return false
	return not check_hands or q.hands_empty()


## Host: holding E on a downed teammate picks them up after CARRY_HOLD seconds.
func _tick_carry_holds(delta: float) -> void:
	for q in players.values():
		var target = null
		if q.wants_interact and q.aim_id.begins_with("pl_"):
			target = players.get(int(q.aim_id.substr(3)))
		# Patient exits: holding E on a body (on a table or on the floor) lifts it the same way.
		if target == null and q.wants_interact:
			var body: Dictionary = corpses.aimed_body(q.aim_id)
			var aim_node: Node = find_interactable(q.aim_id) if not body.is_empty() else null
			if not body.is_empty() and corpses.can_lift(q, body) and (aim_node == null or _within_reach(q, aim_node)):
				q.carry_hold += delta
				if q.carry_hold >= CARRY_HOLD:
					q.carry_hold = 0.0
					corpses.lift(q, int(body.id))
				continue
		if target != null and can_pick_up(q, target) and _within_reach(q, target.downed_aim):
			q.carry_hold += delta
			if q.carry_hold >= CARRY_HOLD:
				q.carry_hold = 0.0
				start_carry(q, target)
		else:
			q.carry_hold = 0.0


## Host: q hoists p over the shoulder.
func start_carry(q: Node, p: Node) -> void:
	if not is_host() or not can_pick_up(q, p):
		return
	q.carrying = p.peer_id
	p.carried_by = q.peer_id
	_end_operations(q)
	q.refresh_downed_visuals()
	p.refresh_downed_visuals()
	_sound("downed_lift", q.global_position)
	say("%s picked up %s." % [q.player_name, p.player_name], 2.5)


## Host: q puts down whoever they carry, on the floor in front of them.
func drop_carried(q: Node) -> void:
	if not is_host() or q == null:
		return
	if corpses.is_body(q.carrying):
		corpses.put_down(q)   # patient exits: a body goes down on the floor
		return
	var p = players.get(q.carrying)
	q.carrying = 0
	q.refresh_downed_visuals()
	if p == null or p.carried_by != q.peer_id:
		return
	p.carried_by = 0
	var fwd: Vector3 = -q.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var spot: Vector3 = q.global_position + fwd * 0.8
	if not _point_is_clear(spot):
		spot = q.global_position
	spot = _floor_at(spot)
	p.teleport(spot)
	p.refresh_downed_visuals()
	_sound("thud", spot)
	# The downed player's machine owns its position: tell it where it landed.
	_broadcast("placed", {"id": p.peer_id, "pos": spot})


## Host: a carrier pressed E. On the player table it lays them there, anywhere else it puts them down.
func carrier_pressed_interact(q: Node, aim: String) -> void:
	if not is_host() or q.carrying == 0:
		return
	if corpses.is_body(q.carrying):
		corpses.carrier_pressed(q, aim)   # patient exits: into the furnace, or down on the floor
		return
	if aim == "player_table":
		var node := find_interactable("player_table")
		if node != null and _within_reach(q, node) and player_table_prompt(q).begins_with("Place"):
			place_on_player_table(q)
			return
	if downed_any_table and aim.begins_with("table"):
		for t in patient_tables:
			var ti := int(t.index)
			if table_interact_id(ti) != aim:
				continue
			var node := find_interactable(aim)
			if node != null and _within_reach(q, node) and _downed_place_prompt(q, ti).begins_with("Place"):
				place_on_player_table(q, ti)
				return
	drop_carried(q)


## Host: a downed player bangs on the floor for help (teammates hear it; monsters do not care).
func downed_call_out(p: Node) -> void:
	if not is_host() or not p.downed:
		return
	if world_time - float(_call_at.get(p.peer_id, -99.0)) < CALL_COOLDOWN:
		return
	_call_at[p.peer_id] = world_time
	_sound("downed_call", p.global_position)
	for q in players.values():
		if q != p and q.alive and not q.downed:
			tell(q, "%s is calling for help." % p.player_name, 2.5)


## Host: put a few suture kits around the hospital (containers where they belong, else the floor).
func spawn_suture_kits() -> void:
	if not is_host():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|suture|%d" % [seed_value, shift])
	var used := {}
	for it in world_items.values():
		if it.state == WorldItem.State.IN_CONTAINER:
			used["%s:%d" % [it.container_id, it.slot]] = true
		elif it.anchor >= 0:
			used["anchor:%d" % it.anchor] = true
	var locs: Array = []
	for loc in SpawnerScript._locations(level_info):
		if SpawnerScript._legal("suture_kit", loc, used):
			locs.append(loc)
	var units := {}
	for i in SUTURE_KITS_PER_SHIFT:
		var count := rng.randi_range(1, 2)
		var pick := {}
		for tries in 12:
			if locs.is_empty():
				break
			var loc: Dictionary = locs[rng.randi_range(0, locs.size() - 1)]
			if not units.has(loc.unit):
				pick = loc
				break
		if pick.is_empty():
			_spawn_from_plan({"kind": "suture_kit", "count": count, "container_id": "", "slot": 0, "anchor": -1})
			continue
		units[pick.unit] = true
		locs.erase(pick)
		_spawn_from_plan(SpawnerScript._entry("suture_kit", count, pick))


# ---- the player table ----

## Find (or build) the player table: level_info.tables' "player" entry, else a spot beside the OR
## table. Needs the level's collision in the physics space, so it lands two physics frames later
## (the same on every machine: the level is identical).
func _add_player_table() -> void:
	player_table = {}
	# Hub rebuild, chunk 2: a level whose tables are all patient tables (the hub's three) has no
	# player table of its own: a downed teammate goes on whichever patient table is free, and
	# `player_table` names that table only while they lie on it (set_downed_table).
	downed_any_table = false
	var has_player_table := false
	for t in level_info.get("tables", []):
		if t is Dictionary and String(t.get("kind", "")) == "player":
			has_player_table = true
	if not has_player_table and not bool(level_info.get("tables_fallback", false)) and patient_tables.size() >= 3:
		downed_any_table = true
		return
	_place_player_table.call_deferred(level)


## Hub rebuild, chunk 2: true when a downed teammate is laid on any free patient table instead of
## a player table of the level's own.
var downed_any_table := false
## The top of an OR table above its floor position (piece_defs "or_table").
const OR_TABLE_TOP := 0.945


## Every machine (player_surgery.apply_locally): which patient table the downed teammate lies on,
## -1 for none. Only on levels where downed players use any free table.
func set_downed_table(index: int) -> void:
	if not downed_any_table:
		return
	if index < 0:
		player_table = {}
		return
	var pos := table_position(index)
	player_table = {"position": pos, "yaw": table_yaw_of(index), "top": pos.y + OR_TABLE_TOP, "index": index}


## What aiming at patient table `ti` offers a carrier: lay the teammate there when it is free.
func _downed_place_prompt(q: Node, ti: int) -> String:
	var who = players.get(q.carrying)
	if not case_on_table(ti).is_empty() or loop.table_reserved(ti):
		return "!The table is taken."
	if not player_table.is_empty():
		return "!Someone is already on a table."
	return "Place %s on the table" % (who.player_name if who != null else "them")


func _place_player_table(for_level: Node) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if level != for_level or level == null or not is_instance_valid(level):
		return
	var pos := Vector3.INF
	var yaw := _table_yaw()
	for t in level_info.get("tables", []):
		if t is Dictionary and String(t.get("kind", "")) == "player":
			pos = t.get("position", Vector3.ZERO)
			yaw = float(t.get("yaw", 0.0))
			break
	if pos == Vector3.INF:
		pos = _fallback_player_table_spot(yaw)
	# A level that already has a table there keeps it; otherwise build one.
	var top_hit := _surface_below(pos + Vector3.UP * 2.0, pos)
	var top_y: float = top_hit.y
	if top_hit.y - pos.y < 0.5 or top_hit.y - pos.y > 1.4:
		var model := PlayerTableScript.make()
		level.add_child(model)
		model.global_position = pos
		model.rotation.y = yaw
		top_y = pos.y + PlayerTableScript.TOP_Y
	player_table = {"position": pos, "yaw": yaw, "top": top_y}
	_add_proxy("player_table", Vector3(pos.x, top_y + 0.3, pos.z), 0.95, 0.0,
		func(q): return player_table_prompt(q))


func _fallback_player_table_spot(yaw: float) -> Vector3:
	var t := table_pos()
	var b := Basis(Vector3.UP, yaw)
	var shelf_pos: Vector3 = level_info.get("shelf", {}).get("position", t + Vector3(2.2, 0.0, 1.4))
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.3, 0.8, 1.1)
	q.shape = box
	q.collision_mask = C.L_WORLD
	for off in [Vector3(0, 0, 2.7), Vector3(0, 0, -2.7), Vector3(0, 0, 3.4), Vector3(0, 0, -3.4),
			Vector3(3.2, 0, 0), Vector3(-3.2, 0, 0), Vector3(2.8, 0, 2.6), Vector3(-2.8, 0, 2.6),
			Vector3(2.8, 0, -2.6), Vector3(-2.8, 0, -2.6)]:
		var c: Vector3 = t + b * off
		if Vector2(c.x - shelf_pos.x, c.z - shelf_pos.z).length() < 1.6:
			continue
		q.transform = Transform3D(b, c + Vector3.UP * 0.55)
		if space.intersect_shape(q, 1).is_empty():
			return c
	return t + b * Vector3(0, 0, 2.7)


func player_table_top() -> Vector3:
	if player_table.is_empty():
		return table_pos() + Vector3(0.0, 0.95, 2.7)
	var pos: Vector3 = player_table.position
	return Vector3(pos.x, float(player_table.top), pos.z)


func player_table_yaw() -> float:
	return float(player_table.get("yaw", _table_yaw()))


## What aiming at the player table offers q: lay down who you carry, or operate on who lies there.
func player_table_prompt(q: Node) -> String:
	if player_table.is_empty() or phase != Phase.SHIFT or q == null or not q.alive or q.downed:
		return ""
	if q.carrying != 0:
		var p = players.get(q.carrying)
		for other in players.values():
			if other.on_table:
				return "!The table is taken."
		return "Place %s on the table" % (p.player_name if p != null else "them")
	return player_surgery.operate_prompt(q)


func _player_table_used(q: Node) -> void:
	if q.carrying != 0:
		carrier_pressed_interact(q, "player_table")
	else:
		player_surgery.begin(q)


## Host: the carrier lays their downed teammate on the player table; the stitches case starts.
func place_on_player_table(q: Node, table_index := -1) -> void:
	if not is_host():
		return
	var p = players.get(q.carrying)
	q.carrying = 0
	q.refresh_downed_visuals()
	if p == null or p.carried_by != q.peer_id:
		return
	p.carried_by = 0
	p.on_table = true
	# The case first: on the hub it names the table, which pinned_pose reads through player_table.
	player_surgery.start(p, table_index)
	p.teleport(pinned_pose(p).origin)
	if p.is_local or p.is_bot:
		p.look_up_from_table()
	p.refresh_downed_visuals()
	_sound("thud", player_table_top())
	say("%s is on the table. A suture kit on the shelf, then stitch them up." % p.player_name, 4.0)


## Host: the stitches operation on the player on the table (docs/SWEEP2.md: the integration wave
## rewires this onto game.add_case / game.cases).
func start_player_surgery(p: Node) -> void:
	if not is_host() or p == null or not p.on_table:
		return
	player_surgery.start(p)


## Where a carried or tabled player's body goes (every machine, every frame).
func pinned_pose(p: Node) -> Transform3D:
	if p.on_table:
		var b := Basis(Vector3.UP, player_table_yaw())
		return Transform3D(b, player_table_top() + b * Vector3(-0.8, 0.0, 0.0))
	if p.carried_by != 0:
		var c = players.get(p.carried_by)
		if c != null and is_instance_valid(c):
			var cb := Basis(Vector3.UP, c.rotation.y)
			return Transform3D(cb, c.global_position + cb * Vector3(0.55, 1.3, 0.0))
	return p.global_transform


## One camera and mouse decision for both surgeries (main.gd reads these).
func surgery_camera() -> Camera3D:
	var cam: Camera3D = surgery.camera() if surgery != null else null
	if cam == null and player_surgery != null:
		cam = player_surgery.surgery.camera()
	return cam


func surgery_wants_mouse() -> bool:
	return (surgery != null and surgery.wants_mouse()) or (player_surgery != null and player_surgery.surgery.wants_mouse())


func surgery_local_exit() -> void:
	if surgery != null and surgery.wants_mouse():
		surgery.local_operator_exit()
	if player_surgery != null and player_surgery.surgery.wants_mouse():
		player_surgery.surgery.local_operator_exit()


## Host only. A shove lands. HANDS HOOK: `charge` 0..1 from the wind-up (scripts/combat/windup.gd:
## a tap is 0, a full charge 1: longer stun, more knockback); -1 is the instant shove of the old
## `shove_count` seam (tests and the playtest bot).
func player_shoved(p: Node, charge: float = -1.0) -> void:
	if not is_host():
		return
	_sound("shove", p.global_position)
	emit_noise(p.global_position, 0.6 + 0.25 * maxf(charge, 0.0), "shove")
	var forward: Vector3 = -p.global_transform.basis.z
	for m in monsters.values():
		if not _in_shove_cone(p, m.global_position, forward):
			continue
		m.shoved(forward, charge)
		_sound("thud", m.global_position)
		if combat != null and combat.has_method("monster_shoved"):
			combat.monster_shoved(m, charge)   # HANDS HOOK: the stun window every machine shows
	for q in players.values():
		if q == p or not q.alive or q.downed or not _in_shove_cone(p, q.global_position, forward):
			continue
		var knock := forward * lerpf(11.0, 16.0, maxf(charge, 0.0)) + Vector3.UP * 2.0
		q.apply_knock(knock)
		_broadcast("shoved", {"id": q.peer_id, "knock": knock})
		if combat != null and combat.has_method("cancel_windup"):
			combat.cancel_windup(q, "shoved")   # HANDS HOOK
		_end_operations(q)
		if combat.dragging(q) >= 0:
			combat.drop_dragged(q)   # SWEEP 3 HOOK (combat): a shoved dragger lets go
			say("%s shoved %s off the monster." % [p.player_name, q.player_name], 3.0)
		elif q.carrying != 0:
			var carried = players.get(q.carrying)
			var what: String = corpses.carried_label(q) if corpses.is_body(q.carrying) else (carried.player_name if carried != null else "someone")
			drop_carried(q)
			say("%s shoved %s, who dropped %s." % [p.player_name, q.player_name, what], 3.0)
		elif q.hands_empty():
			say("%s shoved %s. Very professional." % [p.player_name, q.player_name], 3.0)
		else:
			_drop_hands(q, true)
			say("%s shoved %s. Supplies everywhere." % [p.player_name, q.player_name], 3.0)


## SWEEP 3 HOOK, host: the player pressed left mouse with a usable item in hand.
## SWEEP 4A HOOK (pharmacy, chunk 3): a held bottle of placebo pills swallows one instead of
## routing to combat (it has no windup, no charge, nothing to strike).
func player_used(p: Node) -> void:
	if not is_host():
		return
	if String(p.selected_stack().kind) == "placebo_pills":
		eat_pill(p)
		return
	if combat != null:
		combat.use(p)


## Host: take one pill from the held bottle. Nothing mechanical; the local line and warm effect
## are the same reaction a thrown pill gives, minus the miss chance.
func eat_pill(p: Node) -> void:
	if not is_host() or p == null:
		return
	var head: int = p.selected_head()
	var s: Dictionary = p.slots[head]
	if String(s.kind) != "placebo_pills" or int(s.count) <= 0:
		return
	var left: int = int(s.count) - 1
	if left <= 0:
		p.clear_slot(head)
	else:
		p.slots[head].count = left
	_pill_hit_player(p, p)


# ---------------------------------------------------------------------------
# SWEEP 4A HOOK (pharmacy, chunk 3): placebo pill hit resolution. Host authoritative; who a
# thrown pill hits (or that it missed) is decided here and replicated over `_event` so every
# machine shows the right thing. The warm effect and the personal line are local presentation on
# the affected player's own machine; the floating quote and the OR blip are for everyone nearby.
const PILL_HIT_RADIUS := 0.85


## Host, called every physics frame by an in-flight thrown pill (world_item.gd) while it has not
## yet settled. True once resolved: the caller (world_item.gd) frees the projectile.
func pill_check_hit(it: Node) -> bool:
	if not is_host():
		return false
	var pos: Vector3 = it.global_position
	var thrower: int = int(it.get_meta("pill_thrower", 0))
	var airborne: float = world_time - float(it.get_meta("pill_spawn_t", world_time))
	for p in players.values():
		if p == null or not is_instance_valid(p) or not p.alive or p.downed:
			continue
		if p.peer_id == thrower and airborne < 0.2:
			continue   # a beat of grace so it does not hit its own thrower's hand on release
		if pos.distance_to(p.global_position + Vector3.UP * 1.0) <= PILL_HIT_RADIUS:
			_pill_hit_player(players.get(thrower), p)
			return true
	for i in patient_tables.size():
		var c := case_on_table(i)
		if c.is_empty() or String(c.get("state", "")) == "incoming":
			continue
		var at: Vector3 = table_position(i) + Vector3.UP * 0.6
		if pos.distance_to(at) <= PILL_HIT_RADIUS:
			_pill_hit_case(i, c, at)
			return true
	for m in monsters.values():
		if m != null and is_instance_valid(m) and pos.distance_to(m.global_position + Vector3.UP * 0.9) <= PILL_HIT_RADIUS:
			_pill_hit_creature(m.global_position)
			return true
	return false


## A player (self or a teammate): the line and the warm effect show only on their own machine.
func _pill_hit_player(_thrower, target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	var line := PillLines.pick(target.peer_id)
	if target.is_local:
		message = line
		message_timer = 2.5
		notice.emit(line, 2.5)
		target.add_warm()
	elif Net.active:
		_event.rpc_id(target.peer_id, "pill_player", {"line": line})


## A patient (or player) on a table: the line floats over them in quotes for everyone nearby; an
## OR-table patient's monitor also gets a green blip. Vitals and sedation never change.
func _pill_hit_case(table_index: int, c: Dictionary, at: Vector3) -> void:
	var line := "\"%s\"" % PillLines.pick(0)
	_broadcast("pill_line", {"pos": at, "text": line})
	if String(c.get("patient_id", "")) != "player":
		pill_notes[table_index] = world_time   # the OR screen (or_screen_model.gd) reads this directly


## A monster: the line floats over it in quotes for everyone nearby.
func _pill_hit_creature(at: Vector3) -> void:
	var line := "\"%s\"" % PillLines.pick(0)
	_broadcast("pill_line", {"pos": at + Vector3.UP * 1.6, "text": line})


## SWEEP 4A HOOK, host: the player pressed Alt+(slot_idx+1).
func player_ability_slot(p: Node, slot_idx: int) -> void:
	if is_host() and brains != null:
		brains.ability_slot(p, slot_idx)


func _in_shove_cone(from: Node, target: Vector3, forward: Vector3) -> bool:
	var to_target: Vector3 = target - from.global_position
	to_target.y = 0.0
	if to_target.length() > C.SHOVE_RANGE:
		return false
	return forward.normalized().dot(to_target.normalized()) > 0.6


# =========================================================================
# networking
# =========================================================================
#
# Snapshots (host -> each client, unreliable, SNAPSHOT_HZ):
#   The host builds one "state" per tick: sections of entity reports keyed by id
#     g   the global fields (time, phase, cases, shelf, surgery, loop...) as a few entities
#         grouped by which fields come and go together (_global_groups)
#     pl  players, mo monsters, it world items: id -> report dictionary (without "id")
#     ct  open containers: interact_id -> {} (absent means closed)
#   Replication is per field with acknowledgements, so no message ever depends on another one
#   arriving and no message is ever large:
#   - For each client the host remembers, per entity field, the value that client has confirmed
#     (acked) and the value still in flight. A field is sent when the current value differs from
#     what is in flight, or (nothing in flight) from what was confirmed. A lost or timed-out
#     message turns its fields "unknown", so they are sent again with their current values.
#   - Every message carries absolute values and its own sequence number; the client keeps, per
#     field, the newest sequence it applied and ignores older values. Any subset of messages in
#     any order converges to the host's state.
#   - Existence is the field "@": a hash of the entity's field names while it exists, -1 once
#     removed. A client uses an entity only once its own field names hash the same (it holds
#     exactly the host's fields). A change of field names sends the whole entity; a field that
#     left the report is sent as NET_GONE.
#   - Messages are packed up to NET_MSG_BYTES (well under the ENet MTU and Steam's unreliable
#     segment size, so nothing is ever fragmented), in priority order g, pl, mo, ct, it. A burst
#     (clock-in spawns ~70 loot stacks at once, a late joiner needs everything) spreads over as
#     many ticks as it takes: at most NET_TICK_BYTES per tick and NET_WINDOW_BYTES unacknowledged,
#     one small message per tick while the window is full, fewer while the client is silent.
#   Wire format: {s: seq, g/pl/mo/ct/it: {id: {field: value}}}; empty sections are omitted.
#   Clients ack in _player_state([newest seq, bit mask of the 64 before it], ...).
#   Every KEYFRAME_SECONDS a client re-applies its whole replica to its nodes (no bandwidth), so
#   anything local that drifted is put back.
# Discrete one-off things (sounds, messages, hits, phase changes) stay reliable RPCs.
#
# Joining mid-shift: a peer that arrives outside the lobby waits as a spectator (not alive,
# in `waiting_peers`, not counted by all_players_out) and spawns with everyone at the next lobby.
# Leaving: the host drops what the leaver carried where it stood (nothing breaks) and ends
# its operation; the step keeps its progress for whoever operates next.

const KEYFRAME_SECONDS := 10.0
const NET_SECS := ["g", "pl", "mo", "ct", "it"]
## Largest snapshot message (estimated payload bytes). ENet's MTU is 1392 and Steam's unreliable
## segment carries about 1200, so a message this size is one datagram on both backends.
const NET_MSG_BYTES := 1000
## Per client, per tick: at most this many bytes while catching up on a burst...
const NET_TICK_BYTES := 4000
## ...and no new catch-up messages while this many bytes are unacknowledged.
const NET_WINDOW_BYTES := 16000
## A field whose last message was lost: never equal to any real value, so it is sent again.
const NET_UNKNOWN := "\u0001unknown"
## The value that says "this field left the report" (null is an ordinary value).
const NET_GONE := "\u0001gone"
const ACK_BITS := 64
## How long peers keep patient ENet timeouts after a level build (Net.PATIENT_*), wall ms.
const NET_PATIENCE_MS := 15000
## A message is lost once one sent this much later (wall ms) was acknowledged without it.
const NET_REORDER_MS := 100

## Peers that joined mid-shift and spectate until the next lobby: peer id -> true. Replicated.
var waiting_peers: Dictionary = {}

## Test instrumentation: when set, counts the serialized size of every snapshot message sent.
var net_measure := false
var net_payload_bytes: int = 0
var net_section_bytes: Dictionary = {}
## Counters (always on, cheap): host {msgs, bytes, acked, lost, max_msg}, client {msgs, stale}.
var net_counters: Dictionary = {}

# host
var _net_seq: int = 0                 # snapshot ticks sent (kept for _rpc_shift)
var _net_prev: Dictionary = {}        # last tick's state, to find what changed
var _repl: Dictionary = {}            # peer id -> per-client replication record (_repl_new)
var _net_patience: Dictionary = {}    # peer id -> wall msec its patient timeouts end (-1: first ack)
# client
var _cl_recs: Dictionary = {}         # sec -> id -> {v: {field: value}, s: {field: seq}}
var _cl_state: Dictionary = {}        # sec -> id -> fields, only complete entities (g: the fields)
var _cl_dead: Dictionary = {}         # sec -> id -> [seq, msec] of removals, so late values do not resurrect
var _cl_changed: Dictionary = {}      # sec -> id -> true since the last apply
var _cl_removed: Dictionary = {}      # sec -> id -> true since the last apply
var _cl_latest: int = 0
var _cl_mask: int = 0
var _cl_full := true                  # next apply touches every entity (new level, periodic)
var _cl_full_acc := 0.0
var _cl_seed_wait := false            # _rpc_shift built a new hospital; ignore older seeds
var _pl_applied: Dictionary = {}      # peer id -> instance id of the Player node last applied
var _cl_apply_queued := false
var _revived_at: Dictionary = {}      # peer id -> [position, wall msec] of the last "revive" event
var _cl_g_last: Dictionary = {}       # global group id -> its last complete fields (a copy)


func _net_tick(delta: float) -> void:
	if not Net.active:
		return
	_net_patience_tick()
	if not is_host():
		_cl_full_acc += delta
		if _cl_full_acc >= KEYFRAME_SECONDS:
			_cl_full_acc = 0.0
			_cl_full = true
			_repl_apply()
	_snap_accum += delta
	if _snap_accum < 1.0 / SNAPSHOT_HZ:
		return
	_snap_accum = 0.0
	if is_host():
		if Net.names.size() > 1:
			_send_snapshots()
	else:
		var me := local_player()
		_player_state.rpc_id(Net.HOST_ID, [_cl_latest, _cl_mask], me.report_state() if me != null else [])


# ---------------------------------------------------------------------------
# host

## Host: build this tick's state and send every client what it is missing.
func _send_snapshots() -> void:
	_net_seq += 1
	var state := _build_state()
	var now := Time.get_ticks_msec()
	# What changed since last tick, once for every client (Dictionary != compares contents).
	var changed := {}
	for sec in NET_SECS:
		var cur: Dictionary = state[sec]
		var prev: Dictionary = _net_prev.get(sec, {})
		var ch := {}
		for id in cur.keys():
			if not prev.has(id) or _differs(prev[id], cur[id]):
				ch[id] = true
		for id in prev.keys():
			if not cur.has(id):
				ch[id] = true
		changed[sec] = ch
	_net_prev = state
	for id in Net.peer_ids():
		if id == Net.HOST_ID:
			continue
		if not _repl.has(id):
			_repl[id] = _repl_new(state, now)
			_net_be_patient(id, -1)   # it will stall building the level when this arrives
		var r: Dictionary = _repl[id]
		for sec in NET_SECS:
			(r.dirty[sec] as Dictionary).merge(changed[sec])
		_repl_expire(r, now)
		_repl_send(id, r, state, now)


func _build_state() -> Dictionary:
	var pl := {}
	for p in players.values():
		var d: Dictionary = p.report_full()
		d.erase("id")   # the key already says it
		pl[p.peer_id] = d
	var mo := {}
	for m in monsters.values():
		var d: Dictionary = m.report()
		d.erase("id")
		mo[m.monster_id] = d
	var it := {}
	for i in world_items.values():
		var d: Dictionary = i.report()
		d.erase("id")
		it[i.item_id] = d
	var ct := {}
	for n in get_tree().get_nodes_in_group("container"):
		if n.has_meta("interact_id") and n.has_method("is_open") and n.is_open():
			ct[String(n.get_meta("interact_id"))] = {}
	# A deep copy: several net_state()s hand out their live dictionaries (the dev room's bots, a
	# surgery's minigame state), and the replication records keep these values to compare with
	# later ticks. A shared dictionary edited in place would look unchanged and never be sent.
	return {"g": _global_groups(_global_fields().duplicate(true)), "pl": pl, "mo": mo, "ct": ct, "it": it}


## The global fields as a few entities whose field names change together, so a client missing
## one new field (a case added, a minigame started) only holds back that group:
## "" the fixed fields, "cs" the cases, "lp" the loop, "s<table>" a table's surgery.
static func _global_groups(g: Dictionary) -> Dictionary:
	var out := {"": {}}
	for k in g.keys():
		var key := String(k)
		var gid := ""
		if key == "cs" or key.begins_with("c.") or key.begins_with("v."):
			gid = "cs"
		elif key.begins_with("lp."):
			gid = "lp"
		elif key.begins_with("d."):
			gid = "dr"   # DOORS HOOK: the door set changes with the wings
		elif (key.begins_with("sg") or key.begins_with("ms")) and key.contains("."):
			gid = "s" + key.substr(2, key.find(".") - 2)
		if not out.has(gid):
			out[gid] = {}
		out[gid][k] = g[k]
	return out


func _repl_new(state: Dictionary, now: int) -> Dictionary:
	var r := {"seq": 0, "ents": {}, "dirty": {}, "pend": {}, "inflight": 0,
		"srtt": 200.0, "rttvar": 50.0, "last_ack": now, "last_rx": now, "acked_max": 0, "tick": 0}
	for sec in NET_SECS:
		r.ents[sec] = {}
		var d := {}
		for id in (state[sec] as Dictionary).keys():
			d[id] = true
		r.dirty[sec] = d
	return r


## Host: messages to one client whose acknowledgement is overdue count as lost.
## Measured against when this client's acknowledgements last arrived, not the clock: a host frame
## that stalls, or acks that sit unprocessed until after this runs, must not count as loss. A client
## that stopped acknowledging altogether expires nothing (the window throttles it instead); its
## next ack sorts out what arrived.
func _repl_expire(r: Dictionary, _now: int) -> void:
	var rto := clampf(float(r.srtt) + 4.0 * float(r.rttvar) + 50.0, 250.0, 2000.0)
	var ref := int(r.last_rx)
	for seq in r.pend.keys():
		if ref - int(r.pend[seq].t) > rto:
			_repl_resolve(r, seq, false)


## Host: pack one client's missing fields into messages and send them.
func _repl_send(peer_id: int, r: Dictionary, state: Dictionary, now: int) -> void:
	r.tick = int(r.tick) + 1
	var max_msgs := 64
	if int(r.inflight) >= NET_WINDOW_BYTES:
		max_msgs = 1
	if not (r.pend as Dictionary).is_empty() and now - int(r.last_ack) > 1500:
		max_msgs = 1 if int(r.tick) % 4 == 0 else 0   # silent client (loading, or gone): trickle
	if max_msgs == 0:
		return
	var msgs := []        # [{parts: [[sec, id, fields]], bytes}]
	var cur := {"parts": [], "bytes": 24}
	var tick_bytes := 0
	var full := false
	for sec in NET_SECS:
		if full:
			break
		var dirty: Dictionary = r.dirty[sec]
		if dirty.is_empty():
			continue
		var ents: Dictionary = r.ents[sec]
		var cur_sec: Dictionary = state[sec]
		for eid in dirty.keys():
			var want := _repl_want(ents, dirty, eid, cur_sec.get(eid))
			if want.is_empty():
				continue
			for chunk in _repl_chunks(want):
				var b := var_to_bytes([eid, chunk]).size() + 4
				if (cur.parts as Array).size() > 0 and int(cur.bytes) + b > NET_MSG_BYTES:
					msgs.append(cur)
					tick_bytes += int(cur.bytes)
					cur = {"parts": [], "bytes": 24}
					if msgs.size() >= max_msgs or tick_bytes >= NET_TICK_BYTES or int(r.inflight) + tick_bytes >= NET_WINDOW_BYTES:
						full = true
						break
				cur.parts.append([sec, eid, chunk])
				cur.bytes = int(cur.bytes) + b
			if full:
				break
	if not full and (cur.parts as Array).size() > 0:
		msgs.append(cur)
	for m in msgs:
		r.seq = int(r.seq) + 1
		var seq: int = r.seq
		var wire := {"s": seq}
		for part in m.parts:
			var sec: String = part[0]
			if not wire.has(sec):
				wire[sec] = {}
			var fields: Dictionary = part[2]
			if (wire[sec] as Dictionary).has(part[1]):
				(wire[sec][part[1]] as Dictionary).merge(fields, true)
			else:
				wire[sec][part[1]] = fields.duplicate()
			var rec: Dictionary = r.ents[sec][part[1]]
			for k in fields.keys():
				rec.f[k] = [fields[k], seq]
		r.pend[seq] = {"t": now, "n": int(m.bytes), "parts": m.parts}
		r.inflight = int(r.inflight) + int(m.bytes)
		net_counters["msgs"] = int(net_counters.get("msgs", 0)) + 1
		net_counters["bytes"] = int(net_counters.get("bytes", 0)) + int(m.bytes)
		if net_measure:
			var size := var_to_bytes(wire).size()
			net_payload_bytes += size
			net_counters["max_msg"] = maxi(int(net_counters.get("max_msg", 0)), size)
			for k in wire.keys():
				net_section_bytes[k] = int(net_section_bytes.get(k, 0)) + var_to_bytes(wire[k]).size()
		_snapshot.rpc_id(peer_id, wire)


## Host: the fields of one entity this client needs now ({} when none). Also retires records of
## entities the client provably no longer has, and clears `dirty` once nothing is pending.
func _repl_want(ents: Dictionary, dirty: Dictionary, eid, cur) -> Dictionary:
	var rec = ents.get(eid)
	if rec == null:
		if cur == null:
			dirty.erase(eid)
			return {}
		rec = {"c": {}, "f": {}}
		ents[eid] = rec
	var want := {}
	if cur == null:
		# Gone on the host: only existence matters.
		var need := _repl_needs(rec, "@", -1)
		if need:
			want["@"] = -1
		elif (rec.f as Dictionary).is_empty():
			ents.erase(eid)
			dirty.erase(eid)
		return want
	var cur_d: Dictionary = cur
	var sig := _keys_sig(cur_d)
	# The field names changed (or never arrived): send the whole entity with its new "@", so the
	# one message that lands makes the client's copy whole, whatever was lost before.
	var whole := _repl_needs(rec, "@", sig)
	if whole:
		want["@"] = sig
	for k in cur_d.keys():
		if whole or _repl_needs(rec, k, cur_d[k]):
			want[k] = cur_d[k]
	for k in rec.c.keys():
		if k != "@" and not cur_d.has(k) and _repl_needs(rec, k, NET_GONE):
			want[k] = NET_GONE
	for k in rec.f.keys():
		if k != "@" and not cur_d.has(k) and not want.has(k) and _repl_needs(rec, k, NET_GONE):
			want[k] = NET_GONE
	if want.is_empty() and (rec.f as Dictionary).is_empty():
		dirty.erase(eid)
	return want


## An entity's field names as one number (never -1): a client knows it holds exactly the
## fields the host has, not just as many.
static func _keys_sig(d: Dictionary) -> int:
	var ks := d.keys()
	ks.erase("@")
	ks.sort()
	return hash(ks)


static func _repl_needs(rec: Dictionary, k, v) -> bool:
	var f = rec.f.get(k)
	if f != null:
		return _differs(f[0], v)
	var c = rec.c.get(k)
	if c == null:
		# Never sent: absent is what the client already has (existence "@" = -1 included).
		if k == "@":
			return int(v) != -1
		return _differs(v, NET_GONE)
	return _differs(c[0], v)


## Split one entity's fields so every piece fits a message (a single huge field goes alone).
static func _repl_chunks(want: Dictionary) -> Array:
	if var_to_bytes(want).size() + 32 <= NET_MSG_BYTES:
		return [want]
	var out := []
	var cur := {}
	var bytes := 32
	for k in want.keys():
		var b := var_to_bytes(k).size() + var_to_bytes(want[k]).size()
		if not cur.is_empty() and bytes + b > NET_MSG_BYTES:
			out.append(cur)
			cur = {}
			bytes = 32
		cur[k] = want[k]
		bytes += b
	if not cur.is_empty():
		out.append(cur)
	return out


## Host: a message's fate is known. Delivered fields become confirmed; lost ones unknown.
func _repl_resolve(r: Dictionary, seq: int, delivered: bool) -> void:
	var p: Dictionary = r.pend[seq]
	r.pend.erase(seq)
	r.inflight = maxi(0, int(r.inflight) - int(p.n))
	net_counters["acked" if delivered else "lost"] = int(net_counters.get("acked" if delivered else "lost", 0)) + 1
	for part in p.parts:
		var sec: String = part[0]
		var rec = r.ents[sec].get(part[1])
		if rec == null:
			continue
		var fields: Dictionary = part[2]
		for k in fields.keys():
			var c = rec.c.get(k)
			if c == null or int(c[1]) < seq:
				rec.c[k] = [fields[k] if delivered else NET_UNKNOWN, seq]
			var f = rec.f.get(k)
			if f != null and int(f[1]) == seq:
				rec.f.erase(k)
		r.dirty[sec][part[1]] = true


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _player_state(ack: Array, s: Array) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	var r = _repl.get(id)
	if r != null and ack.size() >= 2:
		var latest := int(ack[0])
		var mask := int(ack[1])
		var now := Time.get_ticks_msec()
		r.last_rx = now
		if latest > int(r.acked_max):
			if int(r.acked_max) == 0 and int(_net_patience.get(id, 0)) == -1:
				_net_patience[id] = now + NET_PATIENCE_MS   # it has built the level: settle soon
			r.acked_max = latest
			r.last_ack = now
			if r.pend.has(latest):
				var sample := float(now - int(r.pend[latest].t))
				r.rttvar = lerpf(float(r.rttvar), absf(sample - float(r.srtt)), 0.25)
				r.srtt = lerpf(float(r.srtt), sample, 0.125)
		var newest_acked_t := -1
		for seq in r.pend.keys():
			var d: int = latest - int(seq)
			if d < 0:
				continue
			if d == 0 or (d <= ACK_BITS and (mask >> (d - 1)) & 1 == 1):
				newest_acked_t = maxi(newest_acked_t, int(r.pend[seq].t))
				_repl_resolve(r, seq, true)
			elif d > ACK_BITS:
				_repl_resolve(r, seq, false)
		# Fast loss: a message sent well after this one arrived and this one did not. The margin
		# covers reordering by network jitter.
		if newest_acked_t >= 0:
			for seq in r.pend.keys():
				if int(seq) < latest and int(r.pend[seq].t) < newest_acked_t - NET_REORDER_MS:
					_repl_resolve(r, seq, false)
	var p = players.get(id)
	if p != null and not s.is_empty():
		p.apply_remote_state(s)


## Host: a new hospital needs nothing special for replication (the replicas diff to it), but
## every client is about to stall building it: give them patient timeouts for a while.
func _net_reset_history() -> void:
	for id in Net.peer_ids():
		if id != Net.HOST_ID:
			_net_be_patient(id, Time.get_ticks_msec() + NET_PATIENCE_MS)


## Patient ENet timeouts for a peer until `until_msec` (-1: until its first acknowledgement).
func _net_be_patient(id: int, until_msec: int) -> void:
	Net.set_patient(id, true)
	_net_patience[id] = until_msec


func _net_patience_tick() -> void:
	if _net_patience.is_empty():
		return
	var now := Time.get_ticks_msec()
	for id in _net_patience.keys():
		var until := int(_net_patience[id])
		if until >= 0 and now >= until:
			_net_patience.erase(id)
			Net.set_patient(id, false)


# ---------------------------------------------------------------------------
# shared helpers

static func _differs(a, b) -> bool:
	return typeof(a) != typeof(b) or a != b


## The global fields, flattened one level so a changing tool position does not resend the
## whole surgery state: {"sg": {"op":.., "ms": {"c":..}}} becomes {"sg.op":.., "ms.c":..}.
func _global_fields() -> Dictionary:
	var g := {
		"t": snappedf(world_time, 0.5), "ph": phase, "sh": shift, "sd": seed_value,
		"pu": snappedf(punch, 0.01),
		"pt": player_surgery.net_state(),  # downed: the player table's case and its surgery
		"et": snappedf(end_timer, 0.1), "sf": shelf.duplicate(),
		"wp": waiting_peers.keys(),
		"dv": dev.net_state() if dev_on() else {},  # DEV HOOK
		"dt": dev_tools,  # DEV HOOK: the pharmacy's secret order
		"mn": money,  # inventory: team money
		"fh": economy.furnace.hatch_open if economy.furnace != null and is_instance_valid(economy.furnace) else false,  # hub: the furnace hatch
		"pj": projector_on,  # terminal redesign: the break room projector
		"wn": economy.waiting_nurse.net_state() if economy.waiting_nurse != null and is_instance_valid(economy.waiting_nurse) else {},  # hub: the waiting room's Night Nurse
		"pn": pill_notes.duplicate(),  # SWEEP 4A HOOK (pharmacy, chunk 3): OR green blip notes
		# SWEEP 3 HOOK: small dictionaries of quantized values only (see docs/SWEEP3.md)
		"cb": combat.net_state(), "dx": dissection.net_state(), "br": brains.net_state(),
	}
	# loop: the cases, one field per case so a vitals tick resends a float, not every case:
	# "cs" the ids in order, "c.<id>" the case without vitals, "v.<id>" its vitals.
	var ids := []
	for c in cases:
		var id := int(c.id)
		ids.append(id)
		var body: Dictionary = c.duplicate(true)
		body.erase("vitals")
		g["c.%d" % id] = body
		g["v.%d" % id] = snappedf(float(c.get("vitals", 100.0)), 0.1)
	g["cs"] = ids
	# One surgery system per patient table: "sg<table>.<field>" and "ms<table>.<minigame field>".
	for s in surgeries:
		if int(s.table_index) < 0:
			continue
		var sg: Dictionary = s.net_state()
		var ti := int(s.table_index)
		for k in sg.keys():
			if k == "ms" and sg[k] is Dictionary:
				for mk in sg.ms.keys():
					g["ms%d.%s" % [ti, str(mk)]] = sg.ms[mk]
			else:
				g["sg%d.%s" % [ti, str(k)]] = sg[k]
	var lp: Dictionary = loop.net_state()
	for k in lp.keys():
		g["lp." + str(k)] = lp[k]
	# DOORS HOOK: every door's amount ("d.<id>", in fiftieths, group "dr"), the gates' lock ("dl"),
	# and which wings the level has ("wg").
	g.merge(doors.net_fields())
	g["wg"] = wing_loader.generation
	g.merge(wall.net_fields())   # terminal redesign: the break room screen ("wt", "wu", "wd")
	return g


static func _surgery_state_from(g: Dictionary, table_index: int) -> Dictionary:
	var sg := {}
	var ms := {}
	var sp := "sg%d." % table_index
	var mp := "ms%d." % table_index
	for k in g.keys():
		var key := String(k)
		if key.begins_with(sp):
			sg[key.substr(sp.length())] = g[k]
		elif key.begins_with(mp):
			ms[key.substr(mp.length())] = g[k]
	sg["ms"] = ms
	return sg


static func _cases_from(g: Dictionary) -> Array:
	var out := []
	for id in g.get("cs", []):
		var c: Dictionary = (g.get("c.%d" % int(id), {}) as Dictionary).duplicate(true)
		if c.is_empty():
			continue
		c["vitals"] = float(g.get("v.%d" % int(id), 100.0))
		out.append(c)
	return out


# ---------------------------------------------------------------------------
# client

@rpc("authority", "unreliable", "call_remote")
func _snapshot(msg: Dictionary) -> void:
	var seq := int(msg.get("s", 0))
	if seq <= 0:
		return
	net_counters["msgs"] = int(net_counters.get("msgs", 0)) + 1
	# Acknowledge: newest sequence plus a bit per earlier one.
	if seq > _cl_latest:
		var shift_by := seq - _cl_latest
		if _cl_latest == 0 or shift_by > ACK_BITS:
			_cl_mask = 0
		else:
			_cl_mask = ((_cl_mask << shift_by) if shift_by < ACK_BITS else 0) | (1 << (shift_by - 1))
		_cl_latest = seq
	elif seq < _cl_latest:
		var d := _cl_latest - seq
		if d <= ACK_BITS:
			_cl_mask |= 1 << (d - 1)
	var now := Time.get_ticks_msec()
	for sec in NET_SECS:
		if not msg.has(sec):
			continue
		var recs: Dictionary = _cl_recs.get(sec, {})
		_cl_recs[sec] = recs
		var dead: Dictionary = _cl_dead.get(sec, {})
		_cl_dead[sec] = dead
		var entries: Dictionary = msg[sec]
		for eid in entries.keys():
			var fields: Dictionary = entries[eid]
			var rec = recs.get(eid)
			if rec == null:
				if dead.has(eid) and int(dead[eid][0]) > seq:
					net_counters["stale"] = int(net_counters.get("stale", 0)) + 1
					continue   # a late value for something already removed
				if int(fields.get("@", 0)) == -1:
					if not dead.has(eid) or int(dead[eid][0]) < seq:
						dead[eid] = [seq, now]   # removed before it ever arrived here
					continue
				rec = {"v": {}, "s": {}}
				recs[eid] = rec
				dead.erase(eid)
			var vals: Dictionary = rec.v
			var seqs: Dictionary = rec.s
			for k in fields.keys():
				if int(seqs.get(k, 0)) > seq:
					continue
				seqs[k] = seq
				var v = fields[k]
				if typeof(v) == TYPE_STRING and v == NET_GONE:
					vals.erase(k)
				else:
					vals[k] = v
			var state_sec: Dictionary = _cl_state.get(sec, {})
			_cl_state[sec] = state_sec
			if int(vals.get("@", 0)) == -1:
				recs.erase(eid)
				dead[eid] = [int(seqs["@"]), now]
				state_sec.erase(eid)
				if sec == "g":
					_cl_g_last.erase(eid)
				_cl_mark(_cl_removed, sec, eid)
				if _cl_changed.has(sec):
					_cl_changed[sec].erase(eid)
				continue
			if vals.has("@") and _keys_sig(vals) == int(vals["@"]):
				if sec == "g":
					_cl_g_last[eid] = vals.duplicate()   # used until the group is whole again
				state_sec[eid] = vals
				_cl_mark(_cl_changed, sec, eid)
				if _cl_removed.has(sec):
					_cl_removed[sec].erase(eid)
			elif state_sec.has(eid) and sec != "g":
				state_sec.erase(eid)   # a field is missing again: wait for it
	# Forget removals old enough that nothing in flight can still mention them.
	if int(net_counters.get("msgs", 0)) % 200 == 0:
		for sec in _cl_dead.keys():
			for eid in _cl_dead[sec].keys():
				if now - int(_cl_dead[sec][eid][1]) > 10000:
					_cl_dead[sec].erase(eid)
	# Several messages can land in one frame (a burst): apply once, at the end of the frame.
	if not _cl_apply_queued:
		_cl_apply_queued = true
		_repl_apply_queued.call_deferred()


func _repl_apply_queued() -> void:
	_cl_apply_queued = false
	if Net.active and not is_host():
		_repl_apply()


static func _cl_mark(where: Dictionary, sec: String, eid) -> void:
	if not where.has(sec):
		where[sec] = {}
	where[sec][eid] = true


## Client: put what the replica holds onto the game: the changed entities, or all of them.
func _repl_apply() -> void:
	if not _cl_g_last.has(""):
		return
	var g := {}
	for gid in _cl_g_last.keys():
		g.merge(_cl_g_last[gid])
	if not g.has("sd"):
		return
	if phase == Phase.MENU:
		wing_loader.next_generation = int(g.get("wg", -1))   # DOORS HOOK: build the host's wings
		start_lobby(int(g.sd), int(g.sh))   # sets _cl_full
	elif int(g.sd) != seed_value:
		if _cl_seed_wait:
			return   # _rpc_shift already built the newer hospital; this is an older value
		wing_loader.next_generation = int(g.get("wg", -1))   # DOORS HOOK
		_client_rebuild_cover()
		start_lobby(int(g.sd), int(g.sh))
	else:
		_cl_seed_wait = false
	var full := _cl_full
	_cl_full = false
	var state := {"g": g, "pl": _cl_state.get("pl", {}), "mo": _cl_state.get("mo", {}),
		"it": _cl_state.get("it", {}), "ct": _cl_state.get("ct", {})}
	var msg := {"x": {}}
	for sec in ["pl", "mo", "it", "ct"]:
		msg[sec] = _cl_changed.get(sec, {})
		msg.x[sec] = (_cl_removed.get(sec, {}) as Dictionary).keys()
	_cl_changed = {}
	_cl_removed = {}
	_apply_state(state, msg, full)


func _apply_state(state: Dictionary, msg: Dictionary, keyframe: bool) -> void:
	var g: Dictionary = state.g
	# The clock runs locally; the host's (sent in half-second steps) only corrects drift.
	if absf(world_time - float(g.t)) > 1.0:
		world_time = float(g.t)
	_set_phase(int(g.ph))
	shift = int(g.sh)
	punch = float(g.pu)
	end_timer = float(g.et)
	waiting_peers.clear()
	for id in g.get("wp", []):
		waiting_peers[id] = true
	cases = _cases_from(g)
	_apply_cases_locally()
	if str(shelf) != str(g.sf):
		shelf = (g.sf as Dictionary).duplicate()
		if shelf_node != null:
			shelf_node.show_stock(shelf)
	for s in surgeries:
		if int(s.table_index) >= 0:
			s.apply_net_state(_surgery_state_from(g, int(s.table_index)))
	var lp := {}
	for k in g.keys():
		if String(k).begins_with("lp."):
			lp[String(k).substr(3)] = g[k]
	loop.apply_net_state(lp)
	# Terminal redesign: the break room projector, and what its screen shows.
	if g.has("pj") and bool(g.pj) != projector_on:
		_set_projector(bool(g.pj))
	wall.apply_net(g)
	# Hub rebuild: the crematorium furnace's hatch.
	if economy.furnace != null and is_instance_valid(economy.furnace) and g.has("fh"):
		economy.furnace.set_hatch(bool(g.fh))
	var wn = g.get("wn", {})
	if economy.waiting_nurse != null and is_instance_valid(economy.waiting_nurse) and wn is Dictionary and not wn.is_empty():
		economy.waiting_nurse.apply_net_state(wn)
	# inventory: money.
	var new_money := int(g.get("mn", money))
	if new_money != money:
		var delta := new_money - money
		money = new_money
		economy.on_money_changed(delta, "")
	pill_notes = (g.get("pn", pill_notes) as Dictionary).duplicate()   # SWEEP 4A HOOK (pharmacy, chunk 3)
	# SWEEP 3 HOOK
	combat.apply_net_state(g.get("cb", {}))
	dissection.apply_net_state(g.get("dx", {}))
	brains.apply_net_state(g.get("br", {}))
	var new_tools := bool(g.get("dt", dev_tools))   # DEV HOOK
	if new_tools != dev_tools:
		dev_tools = new_tools
		if not new_tools:
			dev.reset_state()
		dev.on_dev_tools(new_tools)
	if dev_on() and not (g.get("dv", {}) as Dictionary).is_empty():
		dev.apply_net_state(g.dv)  # DEV HOOK: creates bot players before their entries apply
	# DOORS HOOK: the host rebuilt the wings (a new shift): follow; then the doors' amounts.
	if g.has("wg") and int(g.wg) != wing_loader.generation:
		wing_loader.regenerate(int(g.wg))
	doors.apply_net(g)

	var removed: Dictionary = msg.get("x", {})
	# Players: nodes come from the roster (and the dev room's bots); apply what changed, and
	# everything to a node that has not had this machine's replica yet.
	var pl_changed: Dictionary = msg.get("pl", {})
	for id in players.keys():
		var p = players[id]
		if not state.pl.has(id) or not is_instance_valid(p):
			continue
		if keyframe or pl_changed.has(id) or int(_pl_applied.get(id, 0)) != p.get_instance_id():
			_pl_applied[id] = p.get_instance_id()
			var was_pinned: bool = p.on_table or p.carried_by != 0
			p.apply_remote_full(state.pl[id])
			# downed: the reliable "revive" event put me beside the table, then an older snapshot
			# pinned me back onto it; now that the snapshot lets go, stand where the host put me.
			var rv = _revived_at.get(id)
			if p.is_local and was_pinned and rv != null and not p.on_table and p.carried_by == 0 \
					and Time.get_ticks_msec() - int(rv[1]) < 10000:
				p.teleport(rv[0])
	# downed: the player table's case, after the players so its patient's colour is known.
	var pt = g.get("pt", {})
	player_surgery.apply_net_state(pt if pt is Dictionary else {})

	# Monsters and items are created and destroyed to match the host.
	_apply_entities(monsters, state.mo, msg.get("mo", {}), removed.get("mo", []), keyframe,
		func(id, e): return MonsterScript.new_monster(id, String(e.kind), e.pos))
	_apply_entities(world_items, state.it, msg.get("it", {}), removed.get("it", []), keyframe,
		func(id, e): return WorldItemScript.new_item(id, String(e.k), int(e.n)))

	if keyframe:
		for n in get_tree().get_nodes_in_group("container"):
			if n.has_meta("interact_id") and n.has_method("is_open"):
				var want: bool = state.ct.has(String(n.get_meta("interact_id")))
				if n.is_open() != want:
					n.set_open(want, true)
	else:
		for id in msg.get("ct", {}).keys():
			_set_container_open(id, true)
		for id in removed.get("ct", []):
			_set_container_open(id, false)


func _apply_entities(nodes: Dictionary, entities: Dictionary, changed: Dictionary, removed: Array, keyframe: bool, make: Callable) -> void:
	for id in removed:
		if nodes.has(id):
			if is_instance_valid(nodes[id]):
				nodes[id].queue_free()
			nodes.erase(id)
	var ids: Array = entities.keys() if keyframe else changed.keys()
	for id in ids:
		var e: Dictionary = entities.get(id, {})
		if e.is_empty():
			continue
		var node = nodes.get(id)
		if node == null or not is_instance_valid(node):
			node = make.call(id, e)
			nodes[id] = node
			_entities.add_child(node)
		node.apply_remote(e)
	if keyframe:
		for id in nodes.keys():
			if not entities.has(id):
				if is_instance_valid(nodes[id]):
					nodes[id].queue_free()
				nodes.erase(id)


func _set_container_open(id: String, open: bool) -> void:
	var node := find_interactable(id)
	if node != null and node.has_method("is_open") and node.is_open() != open:
		node.set_open(open, true)


@rpc("authority", "reliable", "call_remote")
func _rpc_shift(new_seed: int, new_shift: int, new_phase: int, _net_seq_unused: int = 0) -> void:
	if new_seed != seed_value:
		if phase != Phase.MENU:
			_client_rebuild_cover()
		start_lobby(new_seed, new_shift)
		_cl_seed_wait = true
	shift = new_shift
	_set_phase(new_phase)


## Client side of a new level: the replica stays (the host keeps diffing against it), but every
## node is new, so the next apply touches everything.
func _net_client_reset() -> void:
	_cl_full = true
	_pl_applied.clear()
	if Net.active:
		_net_be_patient(Net.HOST_ID, Time.get_ticks_msec() + NET_PATIENCE_MS)


## Client: a new connection starts a new replica (the host's sequence numbers start again).
func _net_client_forget() -> void:
	_cl_recs.clear()
	_cl_state.clear()
	_cl_g_last.clear()
	_cl_dead.clear()
	_cl_changed.clear()
	_cl_removed.clear()
	_cl_latest = 0
	_cl_mask = 0
	_cl_full = true
	_cl_seed_wait = false
	_pl_applied.clear()
	net_counters.clear()


## Host: a peer joined outside the lobby. It watches until the next shift.
func _hold_until_next_shift(p: Node) -> void:
	waiting_peers[p.peer_id] = true
	p.alive = false
	p.dead_time = 0.0
	p._set_visible_alive(false)


## Host: someone left. What they carried lands where they stood, gently: nothing smashes.
func _drop_hands_in_place(p: Node) -> bool:
	var any := false
	for i in p.slots.size():
		var s: Dictionary = p.slots[i]
		if s.kind == "":
			continue
		any = true
		var a := TAU * float(i) / float(maxi(1, p.slots.size())) + randf() * 0.5
		var at: Vector3 = p.global_position + Vector3(cos(a) * 0.3, 0.5, sin(a) * 0.3)
		var xf := Transform3D(Basis(Vector3.UP, randf() * TAU), at)
		var it := _spawn_item(s.kind, int(s.count), xf, WorldItem.State.LOOSE)
		it.value = int(s.get("v", 0))  # inventory: loot keeps its value
		it.bt = float(s.get("bt", -1000000.0))   # SWEEP 3 HOOK (brains)
		it.toss(xf, Vector3(cos(a), 0.0, sin(a)) * 0.4)
		p.clear_slot(i)
	if any:
		emit_noise(p.global_position, 0.4, "drop")
	return any


## Discrete one-off things the host wants everyone to see or hear.
@rpc("authority", "reliable", "call_remote")
func _event(kind: String, data: Dictionary) -> void:
	match kind:
		"db_update":
			# SWEEP 4A HOOK (database terminal, chunk 4): this player sighted, scanned or harvested
			# something (the host's mark_db): it goes in their own database, saved on this machine.
			mark_own_db(String(data.kind), String(data.field))
		"wt_pulse":
			wall.on_pulse(data)   # terminal redesign: someone clicked the break room screen
		"sound":
			Audio.play(data.cue, data.get("at"))
		"cremate":
			corpses.play_cremation(data)   # patient exits: a body into the furnace
		"sting":
			Audio.sting(String(data.cue))  # loop: a patient saved or lost
		"loop":
			loop.on_event(data)
		"say":
			message = data.text
			message_timer = data.secs
			notice.emit(data.text, data.secs)
		"pill_player":
			# SWEEP 4A HOOK (pharmacy, chunk 3): a thrown/eaten pill landed on me specifically.
			message = String(data.line)
			message_timer = 2.5
			notice.emit(String(data.line), 2.5)
			var me := local_player()
			if me != null:
				me.add_warm()
		"pill_line":
			# SWEEP 4A HOOK (pharmacy, chunk 3): the floating quoted line over a patient or
			# monster, for everyone nearby. Purely decorative and local to each machine.
			_spawn_pill_line(data.pos, String(data.text))
		"pharmacy_order":
			# Hub rebuild, chunk 3: every client plays the fax order's timeline (the page, the
			# Night Nurse, the drawer); only the host (economy_props.gd) spawns the items.
			if economy != null and economy.pharmacy != null and is_instance_valid(economy.pharmacy):
				economy.pharmacy.queue_order(data.get("items", []))
		"hit":
			var p = players.get(data.id)
			if p != null:
				p.hp = data.hp
				if data.id == Net.my_id():
					p.apply_knock(data.knock)
					p.flinch()
			Audio.play("hurt", p.global_position if p != null else null)
		"shoved":
			var q = players.get(data.id)
			if q != null and data.id == Net.my_id():
				q.apply_knock(data.knock)
		"revive":
			var r = players.get(data.id)
			_revived_at[data.id] = [data.pos, Time.get_ticks_msec()]  # net: see _apply_state
			if r != null:
				r.teleport(data.pos)
				r.revive(int(data.get("hp", 2)))
				r.refresh_downed_visuals()
			Audio.play("revive", data.pos)
		"placed":
			# downed: put down by a carrier; this machine owns its own position.
			var pd = players.get(data.id)
			if pd != null:
				pd.carried_by = 0   # the snapshot agrees a moment later
				pd.teleport(data.pos)
				pd.refresh_downed_visuals()
		"stun":
			var st = players.get(data.id)
			if st != null:
				st.stun = float(data.t)
		_:
			# SWEEP 3 HOOK: each system's reliable one-off events carry its prefix.
			if kind.begins_with("cb_"):
				combat.on_event(kind, data)
			elif kind.begins_with("dx_"):
				dissection.on_event(kind, data)
			elif kind.begins_with("br_"):
				brains.on_event(kind, data)
			elif kind == "dr_evict":
				# DOORS HOOK: the host walked me out of a wing that is about to be rebuilt.
				var me := local_player()
				if me != null:
					me.teleport(data.pos)
			elif kind.begins_with("dr_"):
				doors.on_event(kind, data)
			else:
				dev.on_event(kind, data)  # DEV HOOK: monster_killed and other dev room events


## SWEEP 4A HOOK (pharmacy, chunk 3): a small floating quoted line, local to this machine only
## (every machine that gets the "pill_line" event spawns its own copy; nothing here is tracked in
## game state). Rises and fades over a couple of seconds, then frees itself.
func _spawn_pill_line(pos: Vector3, text: String) -> void:
	if level == null or not is_instance_valid(level):
		return
	var l := Label3D.new()
	l.text = text
	l.font_size = 34
	l.pixel_size = 0.0034
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.modulate = Color(0.85, 0.95, 1.0)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = false
	l.global_position = pos
	level.add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "position:y", l.position.y + 0.6, 1.8)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 1.8).set_delay(0.6)
	tw.tween_callback(l.queue_free)


static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp
