extends "res://scripts/containers/container_base.gd"
## Tall glass-front medicine fridge. Three glass shelves of two slots each, a cold interior
## light that stutters up brighter when the door swings open, and a quiet hum.
##
## Local frame: origin on the floor at the wall, the fridge stands toward -Z (its front).

const W := 0.74
const D := 0.62
const H := 1.86
const WALL := 0.035
const SHELVES := [0.46, 0.93, 1.40]
const DOOR_OPEN_DEG := 108.0
const LIGHT_CLOSED := 0.18
const LIGHT_OPEN := 0.55
const HUM_CUE := "res://audio/sfx/containers_fridge_hum.wav"

var _door: Node3D
var _light: OmniLight3D
var _strip: MeshInstance3D
var _hum: AudioStreamPlayer3D
var _light_tween: Tween


static func create(id: String) -> Node3D:
	var f = new()
	f.init_container("med_fridge", id)
	f.display_name = "fridge"
	f.sound_open = "containers_fridge_open"
	f.sound_close = "containers_fridge_close"
	f.open_time = 0.7
	f.close_time = 0.45
	f._build()
	return f


func _build() -> void:
	var enamel := Mats.get_mat("enamel")
	var liner := Mats.get_mat("liner")
	var zc := -D * 0.5
	# Carcass: back, sides, top, plinth. Built from panels so the interior is open.
	box(self, Vector3(W, H, WALL), Vector3(0, H * 0.5, -WALL * 0.5), enamel)
	for sx in [-1.0, 1.0]:
		box(self, Vector3(WALL, H, D), Vector3(sx * (W - WALL) * 0.5, H * 0.5, zc), enamel)
	box(self, Vector3(W, 0.12, D), Vector3(0, H - 0.06, zc), enamel)
	box(self, Vector3(W, 0.16, D), Vector3(0, 0.08, zc), enamel)
	box(self, Vector3(W - 0.08, 0.06, 0.01), Vector3(0, 0.07, -D - 0.001), Mats.get_mat("grille"))
	# Interior liner so the inside reads bright and clinical against the dark room.
	box(self, Vector3(W - 2 * WALL - 0.002, H - 0.3, 0.01), Vector3(0, H * 0.5 + 0.01, -WALL - 0.006), liner)
	for sy in SHELVES:
		box(self, Vector3(W - 2 * WALL - 0.01, 0.018, D - 0.1), Vector3(0, sy - 0.009, zc - 0.03), Mats.get_mat("shelf_glass"))
		box(self, Vector3(W - 2 * WALL - 0.01, 0.012, 0.015), Vector3(0, sy - 0.006, -D + 0.085), Mats.get_mat("chrome"))
	# Light strip under the top and the cold light it throws.
	_strip = box(self, Vector3(W - 0.14, 0.02, 0.05), Vector3(0, H - 0.13, zc + 0.05), Mats.get_mat("fridge_light"))
	var strip_mat := (Mats.get_mat("fridge_light") as StandardMaterial3D).duplicate() as StandardMaterial3D
	_strip.material_override = strip_mat
	_light = OmniLight3D.new()
	_light.name = "FridgeLight"
	_light.position = Vector3(0, H - 0.45, zc - 0.05)
	_light.omni_range = 1.5
	_light.omni_attenuation = 1.2
	_light.light_color = Color(0.72, 0.92, 1.0)
	_light.light_energy = LIGHT_CLOSED
	_light.light_volumetric_fog_energy = 0.0
	_light.shadow_enabled = false
	add_child(_light)
	# Header with a status LED and a temperature label.
	box(self, Vector3(0.12, 0.035, 0.01), Vector3(-0.2, H - 0.06, -D - 0.001), Mats.get_mat("enamel_dark"))
	box(self, Vector3(0.012, 0.012, 0.006), Vector3(0.26, H - 0.06, -D - 0.004), Mats.get_mat("led_green"))

	# Slots: two per shelf, set back a little so they sit clear of the door.
	for sy in SHELVES:
		for sx in [-0.16, 0.16]:
			add_slot(self, Transform3D(Basis.IDENTITY, Vector3(sx, sy, zc - 0.02)))

	# Door, hinged on its -X edge at the front.
	_door = Node3D.new()
	_door.name = "Door"
	_door.position = Vector3(-W * 0.5, 0.0, -D)
	add_child(_door)
	var frame := enamel
	var dh := H - 0.02
	var t := 0.045
	var fw := 0.07
	var dz := -t * 0.5
	box(_door, Vector3(fw, dh, t), Vector3(fw * 0.5, dh * 0.5, dz), frame)
	box(_door, Vector3(fw, dh, t), Vector3(W - fw * 0.5, dh * 0.5, dz), frame)
	box(_door, Vector3(W, 0.18, t), Vector3(W * 0.5, 0.09, dz), frame)
	box(_door, Vector3(W, 0.14, t), Vector3(W * 0.5, dh - 0.07, dz), frame)
	box(_door, Vector3(W - 2 * fw, dh - 0.32, 0.012), Vector3(W * 0.5, 0.18 + (dh - 0.32) * 0.5, dz), Mats.get_mat("glass"))
	# Gasket line and a long chrome handle on the free edge.
	box(_door, Vector3(W, 0.01, 0.01), Vector3(W * 0.5, 0.005, -0.004), Mats.get_mat("rubber"))
	box(_door, Vector3(0.022, 0.62, 0.022), Vector3(W - 0.045, 1.05, -t - 0.035), Mats.get_mat("chrome"))
	for hy in [0.76, 1.34]:
		box(_door, Vector3(0.018, 0.018, 0.035), Vector3(W - 0.045, hy, -t - 0.017), Mats.get_mat("chrome"))
	# Pharmacy label on the glass.
	box(_door, Vector3(0.2, 0.06, 0.004), Vector3(W * 0.5, dh - 0.25, -t - 0.001), Mats.get_mat("label"))

	# Collision: carcass panels on the world layer, the door on the interact layer.
	collider(self, C.L_WORLD, Vector3(W, H, 0.06), Vector3(0, H * 0.5, -0.03), "BodyBack")
	collider(self, C.L_WORLD, Vector3(W, 0.16, D), Vector3(0, 0.08, zc), "BodyBase")
	collider(self, C.L_WORLD, Vector3(W, 0.12, D), Vector3(0, H - 0.06, zc), "BodyTop")
	for sx in [-1.0, 1.0]:
		collider(self, C.L_WORLD, Vector3(0.05, H, D), Vector3(sx * (W - 0.05) * 0.5, H * 0.5, zc), "BodySide")
	collider(_door, C.L_INTERACT, Vector3(W, dh, 0.07), Vector3(W * 0.5, dh * 0.5, -0.035), "Aim")
	bake(self, [_strip])
	bake(_door)


func _ready() -> void:
	if DisplayServer.get_name() == "headless" or not ResourceLoader.exists(HUM_CUE) and not FileAccess.file_exists(HUM_CUE):
		return
	var stream: AudioStreamWAV = null
	if ResourceLoader.exists(HUM_CUE):
		var res = load(HUM_CUE)
		if res is AudioStreamWAV:
			stream = (res as AudioStreamWAV).duplicate()
	if stream == null:
		stream = AudioStreamWAV.load_from_file(HUM_CUE)
	if stream == null:
		return
	var frames := stream.data.size() / ((2 if stream.format == AudioStreamWAV.FORMAT_16_BITS else 1) * (2 if stream.stereo else 1))
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = frames
	_hum = AudioStreamPlayer3D.new()
	_hum.name = "Hum"
	_hum.stream = stream
	_hum.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	_hum.volume_db = -20.0
	_hum.unit_size = 1.2
	_hum.max_distance = 7.0
	_hum.position = Vector3(0, 0.2, -0.3)
	add_child(_hum)
	# Offset each fridge's loop so a pharmacy full of them does not phase.
	_hum.play(fmod(float(hash(name) & 0xFFFF) / 1000.0, stream.get_length()))


func _trans(open: bool) -> Tween.TransitionType:
	return Tween.TRANS_BACK if open else Tween.TRANS_QUAD


func _apply_pose(t: float) -> void:
	if _door != null:
		_door.rotation.y = deg_to_rad(DOOR_OPEN_DEG) * t
	if _light_tween == null or not _light_tween.is_running():
		_set_light(lerpf(LIGHT_CLOSED, LIGHT_OPEN, clampf(t, 0.0, 1.0)))


func _on_animate(open_now: bool) -> void:
	if _light_tween != null:
		_light_tween.kill()
	_light_tween = create_tween()
	if open_now:
		# A fluorescent stutter: dip, catch, dip, then full.
		_light_tween.tween_callback(func(): _play("containers_click"))
		_light_tween.tween_method(_set_light, _light.light_energy, 0.08, 0.05)
		_light_tween.tween_method(_set_light, 0.08, LIGHT_OPEN * 0.8, 0.06)
		_light_tween.tween_method(_set_light, LIGHT_OPEN * 0.8, 0.2, 0.07)
		_light_tween.tween_method(_set_light, 0.2, LIGHT_OPEN, 0.18)
	else:
		_light_tween.tween_interval(close_time * 0.8)
		_light_tween.tween_method(_set_light, LIGHT_OPEN, LIGHT_CLOSED, 0.2)


func _set_light(e: float) -> void:
	if _light == null:
		return
	_light.light_energy = e
	var m := _strip.material_override as StandardMaterial3D
	m.emission_energy_multiplier = 0.4 + e * 1.2
	if _hum != null:
		_hum.volume_db = lerpf(-20.0, -14.0, clampf((e - LIGHT_CLOSED) / (LIGHT_OPEN - LIGHT_CLOSED), 0.0, 1.0))
