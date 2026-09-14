extends RefCounted
## POCKETS: generation time. Which pocket space (if any) a hospital gets and where its entrances
## are, in hospital tile space. Called once from MapGen after every wing slot has a room kind and
## before the rooms are carved (`# POCKETS HOOK` in mapgen.gd).
##
## An entrance is a U-shaped hallway stub carved into one or two neighbouring room slots of a wing
## (see stub.gd for the frame and the geometry): leg 1 opens onto the wing hallway, turns along the
## back of the slot (leg 2, where the hidden seam is) and turns back toward the hallway (leg 3, a
## dead end in the hospital; in the pocket it opens into the space). Stub tiles get their own zone
## (ZONE_STUB, so nothing that walks wing hallways places anything there), `keep` 2 (no furniture,
## markers or containers), and the tiles past the seam are `blocked` (the hospital's navigation
## mesh leaves them out: nobody should path into the half of the stub that only exists to be seen).
##
## The plan lands in `gen.spots.pocket`:
##   {kind: "factory" | "restaurant", seed: int, stubs: [{id, wing, depth, zone, o: Vector2i,
##    eu: Vector2i, ev: Vector2i, w: int, d: int, lights: [Vector2i]}]}
## `o` is the hospital tile of stub-local tile (0, 0): the slot tile beside the front wall at leg 1's
## end; `eu` runs along the slot toward leg 3, `ev` away from the hallway.

const S := preload("res://scripts/level/level_state.gd")
const Rng := preload("res://scripts/level/rng.gd")
const StubScript := preload("res://scripts/level/pockets/stub.gd")

const KINDS := ["factory", "restaurant"]
## Zone id of stub tiles (wings are 2..5, outdoor 9).
const ZONE_STUB := 10
## Chance a map (with doors: a shift) gets a pocket at all.
const CHANCE := 0.5
const MIN_ENTRANCES := 2
const MAX_ENTRANCES := 3
const MAX_W := 14

## Tools and the dev room: "" rolls normally, "none" never, "factory" / "restaurant" always that one.
static var force_kind := ""
## Tools: how many entrances a forced pocket wants (0 = roll 2-3).
static var force_entrances := 0
const RESERVED := "__pocket_stub"
## Tools: why the last roll that wanted a pocket placed none ("" when it did).
static var last_failure := ""

## `gens`: the wing generators (WingGen, hallways carved, no room kinds yet), `defs`: the wing
## definitions, `seed`: the map's stream. Slots the stubs take are marked RESERVED so MapGen gives
## them no room; `release()` clears the mark before the rooms are carved.
static func plan(st: S, gens: Array, defs: Array, seed: int) -> void:
	var rng := Rng.new((seed * 1103515245 + 0x70C4E7) & 0x7FFFFFFF)
	var kind := ""
	if force_kind == "":
		if rng.chance(CHANCE):
			kind = KINDS[rng.rint(0, KINDS.size() - 1)]
	elif KINDS.has(force_kind):
		kind = force_kind
		rng.nextf()
	if kind == "":
		return
	var want := force_entrances if force_entrances > 0 else rng.rint(MIN_ENTRANCES, MAX_ENTRANCES)
	var cands := _candidates(st, gens, defs)
	if cands.is_empty():
		last_failure = "no candidate slots"
		return
	# Weight by depth: deeper wings are likelier to hold an entrance.
	var picked: Array = []
	var used_slots := {}
	var used_wings := {}
	for round_i in want:
		var pool: Array = []
		var weights: Array = []
		for c in cands:
			var clash := false
			for s in c.slots:
				if used_slots.has(s):
					clash = true
			if clash:
				continue
			# The first two entrances must be in different wings (the pocket is a shortcut).
			if round_i < MIN_ENTRANCES and used_wings.has(c.wing):
				continue
			if round_i >= MIN_ENTRANCES and used_wings.has(c.wing) and rng.chance(0.7):
				continue
			pool.append(c)
			weights.append(pow(float(c.depth), 1.5) * (1.3 if c.slots.size() == 1 else 1.0))
		if pool.is_empty():
			break
		var c: Dictionary = pool[rng.weighted(weights)]
		picked.append(c)
		for s in c.slots:
			used_slots[s] = true
		used_wings[c.wing] = true
	if picked.size() < MIN_ENTRANCES or used_wings.size() < 2:
		var wings := {}
		for c in cands:
			wings[c.wing] = int(wings.get(c.wing, 0)) + 1
		last_failure = "%d candidates by wing %s" % [cands.size(), str(wings)]
		return
	last_failure = ""
	var stubs: Array = []
	for c in picked:
		for s in c.slots:
			s.kind = RESERVED
		stubs.append(_carve(st, c, stubs.size(), rng))
	st.spots["pocket"] = {"kind": kind, "seed": rng.rint(1, 0x3FFFFFFF), "stubs": stubs}


## After MapGen gave every other slot its room: the stubs' slots get none carved.
static func release(gens: Array) -> void:
	for g in gens:
		for s in g.slots:
			if String(s.kind) == RESERVED:
				s.kind = ""


## The plan of a generated map, or {}.
static func of(gen: Dictionary) -> Dictionary:
	return gen.get("spots", {}).get("pocket", {})


# ---------------------------------------------------------------------------
# Candidates
# ---------------------------------------------------------------------------

## Every way a stub fits: one slot, or two neighbouring slots of one row joined through the wall
## between them. Each candidate knows its frame (o, eu, ev), size and which slots it uses.
static func _candidates(st: S, gens: Array, defs: Array) -> Array:
	var out: Array = []
	for gi in gens.size():
		var g = gens[gi]
		var z := int(defs[gi].zone)
		var slots: Array = g.slots
		for i in slots.size():
			var a: Dictionary = slots[i]
			if String(a.kind) != "":
				continue
			_try_rect(st, out, gi, z, defs[gi], [a], a.rect, a.front)
			for j in slots.size():
				if j == i:
					continue
				var b: Dictionary = slots[j]
				if String(b.kind) != "" or b.front != a.front:
					continue
				var ra: Rect2i = a.rect
				var rb: Rect2i = b.rect
				var joined := Rect2i()
				if a.front.x == 0:
					# Rows run along x: b directly east of a, one wall tile between, same depth.
					if ra.position.y == rb.position.y and ra.size.y == rb.size.y and rb.position.x == ra.end.x + 1:
						joined = Rect2i(ra.position.x, ra.position.y, ra.size.x + 1 + rb.size.x, ra.size.y)
				else:
					if ra.position.x == rb.position.x and ra.size.x == rb.size.x and rb.position.y == ra.end.y + 1:
						joined = Rect2i(ra.position.x, ra.position.y, ra.size.x, ra.size.y + 1 + rb.size.y)
				if joined.size != Vector2i.ZERO:
					_try_rect(st, out, gi, z, defs[gi], [a, b], joined, a.front)
	return out


static func _try_rect(st: S, out: Array, gi: int, z: int, wdef: Dictionary, slots: Array, r: Rect2i, front: Vector2i) -> void:
	var ev := -front
	var perp := Vector2i(absi(ev.y), absi(ev.x))
	var full_w := r.size.x if ev.x == 0 else r.size.y
	var d := r.size.y if ev.x == 0 else r.size.x
	for eu in [perp, -perp]:
		# The stub may use part of the rect: pick the smallest width that clears the light margin,
		# at either end of the rect (u = 0 at one end along eu).
		for w in range(StubScript.MIN_W, mini(full_w, MAX_W) + 1):
			if not StubScript.size_ok(w, d):
				continue
			var o := _origin(r, eu, ev)
			for shift in [0, full_w - w]:
				var oo: Vector2i = o + eu * shift
				if _mouth_ok(st, z, oo, eu, ev):
					out.append({"gi": gi, "wing": String(wdef.id), "depth": int(wdef.depth), "zone": z,
							"slots": slots, "o": oo, "eu": eu, "ev": ev, "w": w, "d": d})
					break
			break


## The tile of stub-local (0, 0) for a rect: u = 0 at the end along -eu, v = 0 beside the front.
static func _origin(r: Rect2i, eu: Vector2i, ev: Vector2i) -> Vector2i:
	var o := Vector2i.ZERO
	for axis in 2:
		var e: int = eu[axis] if eu[axis] != 0 else ev[axis]
		o[axis] = r.position[axis] if e > 0 else r.end[axis] - 1
	return o


## Leg 1's mouth (u 0..1 in the front wall) opens onto two hallway tiles of the wing, with a
## hallway tile to either side so the opening is not wedged into a corner.
static func _mouth_ok(st: S, z: int, o: Vector2i, eu: Vector2i, ev: Vector2i) -> bool:
	for u in range(0, StubScript.CORRIDOR):
		var wall: Vector2i = o + eu * u - ev
		var hall: Vector2i = o + eu * u - ev * 2
		if st.get_c(wall.x, wall.y) != S.CH_WALL or not _is_corr(st, z, hall):
			return false
	return true


static func _is_corr(st: S, z: int, p: Vector2i) -> bool:
	return st.in_bounds(p.x, p.y) and st.zone_at(p.x, p.y) == z and st.get_c(p.x, p.y) == S.CH_FLOOR \
			and st.room_index(p.x, p.y) < 0


# ---------------------------------------------------------------------------
# Carving
# ---------------------------------------------------------------------------

static func _carve(st: S, c: Dictionary, index: int, rng: Rng) -> Dictionary:
	var o: Vector2i = c.o
	var eu: Vector2i = c.eu
	var ev: Vector2i = c.ev
	var w: int = c.w
	var d: int = c.d
	var tile := func(u: int, v: int) -> Vector2i:
		return o + eu * u + ev * v
	for t in StubScript.open_tiles(w, d, true):
		var p: Vector2i = tile.call(t.x, t.y)
		st.set_c(p.x, p.y, S.CH_FLOOR)
		st.zone[st.idx(p.x, p.y)] = ZONE_STUB
		st.set_keep(p.x, p.y, 2)
		if StubScript.phantom_hospital(w, t):
			st.blocked[st.idx(p.x, p.y)] = 1
	# Nothing blocking in front of the mouth.
	for u in range(-1, StubScript.CORRIDOR + 1):
		var p: Vector2i = tile.call(u, -2)
		st.set_keep(p.x, p.y, 1)
	var lights: Array = []
	for t in StubScript.light_tiles(w, d):
		var p: Vector2i = tile.call(t.x, t.y)
		lights.append(p)
		# Steady or a deterministic flicker; both copies of the stub run the same waveform.
		st.lights.append({"tile": p, "zone": ZONE_STUB, "mode": 0 if rng.chance(0.6) else 1, "stub": index})
	return {"id": index, "wing": c.wing, "depth": c.depth, "zone": c.zone, "o": o, "eu": eu, "ev": ev,
			"w": w, "d": d, "lights": lights}
