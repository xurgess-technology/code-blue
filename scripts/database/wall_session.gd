extends Node
## The break room screen, shared by everyone (terminal redesign, chunks 3 and 4). The host owns it:
## the page on screen and how it got there, who is signed in, and that player's database. Everyone
## else mirrors the snapshot ("wt" the page and its history, "wu" who is signed in, "wd" their
## database) and sends the host their clicks and sign-ins. Anyone can click anything; signing in only
## decides whose database fills the cards (nobody: every monster and found item is "???").
##
##   click(px)                 this machine's player's laser clicked the screen at px
##   sign_in()                 this machine's player held the laser on SIGN IN for HOLD_SECONDS
##   sign_out()                SIGN OUT (host: the Button only ever presses on the host's screen)
##   own_db_changed()          game.mark_own_db flipped a field on this machine
##   user -> int               the signed-in player's peer id, 0 for nobody
##   user_name() -> String
##   view() -> Dictionary      {db: {kind: bits (1 sighted, 2 scanned, 4 harvested)}, peer, brains}
##   laser_of(p) -> Dictionary where player p's laser lands, on any machine: {from, to, landed,
##                             terminal, px} (px (-1, -1) off the screen)
##   net_fields() / apply_net(g)
##
## Signed out by SIGN OUT, by walking WALK_AWAY_M from the screen, by leaving the game, and after
## IDLE_SECONDS with nobody's laser on the screen. Signing out goes back to HOME.

const WALK_AWAY_M := 9.0
const IDLE_SECONDS := 60.0
const HOLD_SECONDS := 1.5
const LASER_RANGE := 14.0   # scan_fx.gd LASER_RANGE

var game: Node
var user := 0
var _db: Dictionary = {}
var _idle := 0.0


func setup(g: Node) -> void:
	game = g


static func encode(database: Dictionary) -> Dictionary:
	var out := {}
	for kind in database.keys():
		var rec = database[kind]
		var bits := (1 if bool(rec.sighted) else 0) | (2 if bool(rec.scanned) else 0) | (4 if bool(rec.harvested) else 0)
		if bits != 0:
			out[String(kind)] = bits
	return out


func view() -> Dictionary:
	return {"db": _db, "peer": user, "brains": game.brains if game != null else null}


func user_name() -> String:
	var p = game.players.get(user) if game != null and user != 0 else null
	return String(p.player_name).left(16) if p != null else ""


func _terminal() -> Node3D:
	return game.wall_terminal() if game != null else null


# ---------------------------------------------------------------------------
# this machine's player

func click(px: Vector2) -> void:
	var wt := _terminal()
	if wt == null:
		return
	if game.is_host():
		_host_click(Net.my_id(), px)
	else:
		wt.ui.pulse(px)
		game._rpc_wall.rpc_id(1, "click", {"px": px, "link": wt.ui.link_at(px)})


func sign_in() -> void:
	if game.is_host():
		_host_sign_in(Net.my_id(), encode(game.database))
	else:
		game._rpc_wall.rpc_id(1, "sign_in", {"db": encode(game.database)})


func own_db_changed() -> void:
	if user == 0 or user != Net.my_id():
		return
	if game.is_host():
		_set_db(encode(game.database))
	else:
		game._rpc_wall.rpc_id(1, "db", {"db": encode(game.database)})


# ---------------------------------------------------------------------------
# host

## A client's message (game._rpc_wall).
func on_rpc(peer: int, kind: String, data: Dictionary) -> void:
	if not game.is_host():
		return
	match kind:
		"click":
			if data.get("px") is Vector2:
				_host_click(peer, data.px, String(data.get("link", "")))
		"sign_in":
			_host_sign_in(peer, data.get("db", {}))
		"db":
			if peer == user and data.get("db") is Dictionary:
				_set_db(data.db)


## `link`: the tool the guest's own turntable had under px (the host's may have turned elsewhere).
func _host_click(peer: int, px: Vector2, link := "") -> void:
	var wt := _terminal()
	if wt == null or not wt.on:
		return
	_idle = 0.0
	if link != "":
		wt.ui.pulse(px)
		wt.ui.open_link(link)
	else:
		wt.click(px)
	# The host's own laser keeps its hover where it is.
	var me = game.local_player()
	if me != null and peer != Net.my_id():
		var mine := laser_of(me)
		if mine.terminal == wt:
			wt.point(mine.px)
		else:
			wt.clear_pointer()
	if Net.active:
		game._event.rpc("wt_pulse", {"px": px, "id": peer})


func _host_sign_in(peer: int, db) -> void:
	var p = game.players.get(peer)
	var wt := _terminal()
	if user != 0 or p == null or wt == null or not (db is Dictionary) or _away(p, wt):
		return
	user = peer
	_idle = 0.0
	_set_db(db)


func sign_out() -> void:
	if not game.is_host() or user == 0:
		return
	user = 0
	_db = {}
	var wt := _terminal()
	if wt != null:
		wt.ui.go_home()


func _set_db(db: Dictionary) -> void:
	var clean := {}
	for k in db.keys():
		clean[String(k)] = int(db[k])
	if clean == _db:
		return
	_db = clean
	_refresh()


func _refresh() -> void:
	var wt := _terminal()
	if wt != null:
		wt.ui.refresh()


func _away(p: Node3D, wt: Node3D) -> bool:
	var d := p.global_position - wt.global_position
	return Vector2(d.x, d.z).length() > WALK_AWAY_M


func _physics_process(delta: float) -> void:
	if game == null or not game.is_host() or user == 0:
		return
	var wt := _terminal()
	var p = game.players.get(user)
	if wt == null or p == null or not is_instance_valid(p) or _away(p, wt):
		sign_out()
		return
	var anyone := false
	for q in game.players.values():
		if is_instance_valid(q) and bool(q.scan_holding) and laser_of(q).terminal == wt:
			anyone = true
			break
	_idle = 0.0 if anyone else _idle + delta
	if _idle >= IDLE_SECONDS:
		sign_out()


func net_fields() -> Dictionary:
	var wt := _terminal()
	var out := {"wu": user, "wd": _db.duplicate()}
	if wt != null:
		out["wt"] = {"p": wt.ui.page.duplicate(true), "h": wt.ui.history().duplicate(true)}
	return out


# ---------------------------------------------------------------------------
# everyone else

func apply_net(g: Dictionary) -> void:
	var wt := _terminal()
	var changed := false
	if g.has("wu") and int(g.wu) != user:
		user = int(g.wu)
		changed = true
	if g.get("wd") is Dictionary and (g.wd as Dictionary) != _db:
		_db = (g.wd as Dictionary).duplicate()
		changed = true
	if wt != null and g.get("wt") is Dictionary:
		var v: Dictionary = g.wt
		if not v.get("p", {}).is_empty() and (v.p != wt.ui.page or v.get("h", []) != wt.ui.history()):
			wt.ui.set_view((v.p as Dictionary).duplicate(true), (v.get("h", []) as Array).duplicate(true))
			changed = false   # set_view redraws with the new user too
	if changed:
		_refresh()


## Another player clicked: everyone sees the ring (the clicker drew their own already).
func on_pulse(data: Dictionary) -> void:
	var wt := _terminal()
	if wt != null and int(data.get("id", 0)) != Net.my_id() and data.get("px") is Vector2:
		wt.ui.pulse(data.px)


# ---------------------------------------------------------------------------
# lasers

## Where player p's laser lands: along their view from their camera. The screen under it, and where.
func laser_of(p: Node) -> Dictionary:
	var out := {"from": Vector3.ZERO, "to": Vector3.ZERO, "landed": false, "terminal": null, "px": Vector2(-1, -1)}
	var cam: Camera3D = p.get("camera")
	if cam == null or not p.is_inside_tree():
		return out
	var ray_from := cam.global_position
	var ray_to := ray_from - cam.global_transform.basis.z * LASER_RANGE
	if p.get("carry_cam") != null and p.carry_cam.active:
		var seg: Array = p.carry_cam.aim_segment(LASER_RANGE)
		ray_from = seg[0]
		ray_to = seg[1]
	out.from = ray_from
	out.to = ray_to
	var q := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	q.collision_mask = C.L_WORLD | C.L_MONSTER | C.L_SCAN
	q.exclude = [p.get_rid()]
	var hit: Dictionary = p.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return out
	out.to = hit.position
	out.landed = true
	var collider = hit.get("collider")
	if collider is Node:
		for c in (collider as Node).get_children():
			if c.is_in_group("wall_terminal"):
				var px: Vector2 = c.pixel_at(hit.position)
				if px.x >= 0.0:
					out.terminal = c
					out.px = px
				break
	return out
