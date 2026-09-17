class_name TerminalModel
extends RefCounted
## The database terminal as a world object: a standing desk with a full-size monitor and
## keyboard, built from primitives (docs/SWEEP4A.md "Hard rule: no new Blender models"). Replaces
## the old medical guide's lectern and binder (sweep 4a chunk 4).
##
## HUB REDESIGN (2026-09-15): two fixes over the original lectern-sized version.
##  1. It was placed with the SAME yaw `scripts/level/entrance.gd` computes for every other
##     wall-mounted piece via `Defs.yaw_facing` (front assumed to be local -Z, matching every
##     `put()`-placed prop), but this model's screen was built facing local +Z -- so at yaw 0 it
##     faced INTO the wall it stands against, not out into the break room where players walk up to
##     it. The monitor (and its camera mirror below) now face -Z, matching that convention; no
##     placement code needed to change.
##  2. The whole thing is bigger: a proper standing desk (a wide slab, steel legs), a full-size
##     monitor and a keyboard, instead of a narrow lectern-shaped stand.
##
##   make_terminal()   origin on the floor, screen faces -Z (out into the room, the reader's side)

const SCREEN_GLOW := Color(0.35, 0.9, 0.55)
const ScreenLive := preload("res://scripts/database/terminal_screen_live.gd")
const WallTerminal := preload("res://scripts/database/wall_terminal.gd")


static func make_terminal() -> Node3D:
	# Terminal redesign (chunk 1): a big screen on the wall, driven with the scan laser.
	return WallTerminal.make()


static func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi
