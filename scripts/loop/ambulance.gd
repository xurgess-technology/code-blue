extends Node3D
## The driven ambulance (sweep 4A chunk 2). Purely local presentation: the shift loop
## (`scripts/loop/shift_loop.gd`) drives its replicated position and phase every tick and calls
## `set_target()`; this just glides the model there, lights the headlights and flashers, and
## reports whether it is moving (for the siren volume/pitch the loop plays locally).
##
## Reuses the existing "ambulance" piece mesh (`piece_factory.gd`, itself the `Assets` model
## `hosp/ambulance` when present, else the same procedural primitive the old static prop used) --
## no new model.

const PieceFactory := preload("res://scripts/level/piece_factory.gd")
const SIZE := Vector3(2.18, 2.61, 4.71)   # piece_defs.gd "ambulance"

var target_pos := Vector3.ZERO
var target_yaw := 0.0
var phase := "hidden"   # "hidden" | "out" | "parked" | "back"

var _mesh: MeshInstance3D
var _headlight_l: OmniLight3D
var _headlight_r: OmniLight3D
var _flasher: OmniLight3D
var _flash_t := 0.0


static func create() -> Node3D:
	var n: Node3D = (load("res://scripts/loop/ambulance.gd") as GDScript).new()
	n.name = "Ambulance"
	n._build()
	return n


func _build() -> void:
	_mesh = MeshInstance3D.new()
	var parts: Array = PieceFactory.parts("ambulance")
	if not parts.is_empty():
		_mesh.mesh = parts[0].mesh
		_mesh.transform = parts[0].xform
	add_child(_mesh)
	_headlight_l = _light(Vector3(-SIZE.x * 0.35, 0.55, -SIZE.z * 0.5 - 0.05), Color(1.0, 0.97, 0.85), 5.0)
	_headlight_r = _light(Vector3(SIZE.x * 0.35, 0.55, -SIZE.z * 0.5 - 0.05), Color(1.0, 0.97, 0.85), 5.0)
	_flasher = _light(Vector3(0, SIZE.y + 0.1, 0), Color(1.0, 0.2, 0.15), 4.0)


func _light(pos: Vector3, col: Color, rng: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = col
	l.light_energy = 0.0
	l.omni_range = rng
	l.shadow_enabled = false
	l.light_volumetric_fog_energy = 0.6   # this is what makes the lights glow *through* the fog
	add_child(l)
	return l


func snap(pos: Vector3, yaw: float, ph: String) -> void:
	global_position = pos
	rotation.y = yaw
	set_target(pos, yaw, ph)


func set_target(pos: Vector3, yaw: float, ph: String) -> void:
	target_pos = pos
	target_yaw = yaw
	phase = ph


func is_moving() -> bool:
	return phase == "out" or phase == "back"


func _process(delta: float) -> void:
	var k := clampf(delta * 6.0, 0.0, 1.0)
	global_position = global_position.lerp(target_pos, k)
	rotation.y = lerp_angle(rotation.y, target_yaw, k)
	visible = phase != "hidden"
	var lit := phase != "hidden"
	_headlight_l.light_energy = 5.0 if lit else 0.0
	_headlight_r.light_energy = 5.0 if lit else 0.0
	if is_moving():
		_flash_t += delta * 6.5
		_flasher.light_energy = 4.0 if int(_flash_t) % 2 == 0 else 0.2
	else:
		_flash_t = 0.0
		_flasher.light_energy = 0.0
