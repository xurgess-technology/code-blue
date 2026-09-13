extends Node3D
## A wheeled IV pole dragged behind the Discharged by the tube taped into its wrist.
## Top-level: the base rolls on the floor and lags behind, the pole leans toward the
## hand holding it, the bag sways, and a sagging tube runs from the drip to the wrist.

const Shapes := preload("res://scripts/monsters/shapes.gd")

const HEIGHT := 1.95
const GRIP := 1.02          ## metres up the pole where the hand holds it

var base_pos := Vector3.ZERO
var rolled := 0.0           ## metres the casters travelled, for the rattle
var _placed := false
var _pole: Node3D
var _bag_pivot: Node3D
var _tube_a: MeshInstance3D
var _tube_b: MeshInstance3D
var _sway := 0.0
var _sway_v := 0.0


func _init() -> void:
	name = "IVPole"
	top_level = true
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color("8c8f93")
	metal.metallic = 0.85
	metal.roughness = 0.38
	var rubber := Shapes.flat(Color("161616"), 0.8)
	_pole = Node3D.new()
	add_child(_pole)
	for i in 5:
		var a := TAU * i / 5.0
		var leg := Shapes.box(Vector3(0.022, 0.018, 0.27), metal, Vector3(sin(a) * 0.13, 0.07, cos(a) * 0.13))
		leg.rotation.y = a
		_pole.add_child(leg)
		_pole.add_child(Shapes.ellipsoid(Vector3(0.028, 0.028, 0.028), rubber, Vector3(sin(a) * 0.27, 0.03, cos(a) * 0.27), 8))
	_pole.add_child(Shapes.cylinder(0.035, 0.05, metal, Vector3(0, 0.08, 0)))
	_pole.add_child(Shapes.cylinder(0.013, HEIGHT, metal, Vector3(0, HEIGHT * 0.5 + 0.08, 0), -1.0, 8))
	var hook := Shapes.box(Vector3(0.2, 0.012, 0.012), metal, Vector3(0, HEIGHT + 0.03, 0))
	_pole.add_child(hook)
	_pole.add_child(Shapes.box(Vector3(0.035, 0.06, 0.04), metal, Vector3(0, GRIP, 0)))

	_bag_pivot = Node3D.new()
	_bag_pivot.position = Vector3(0.09, HEIGHT + 0.02, 0)
	_pole.add_child(_bag_pivot)
	var bag_mat := StandardMaterial3D.new()
	bag_mat.albedo_color = Color(0.5, 0.48, 0.4, 0.45)
	bag_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bag_mat.roughness = 0.15
	bag_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bag_pivot.add_child(Shapes.ellipsoid(Vector3(0.065, 0.12, 0.022), bag_mat, Vector3(0, -0.15, 0), 12))
	var fluid := Shapes.flat(Color("3e2217"), 0.3)
	_bag_pivot.add_child(Shapes.ellipsoid(Vector3(0.058, 0.055, 0.018), fluid, Vector3(0, -0.215, 0), 10))
	_bag_pivot.add_child(Shapes.cylinder(0.012, 0.06, bag_mat, Vector3(0, -0.3, 0)))

	var tube_mat := StandardMaterial3D.new()
	tube_mat.albedo_color = Color(0.75, 0.74, 0.68, 0.8)
	tube_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tube_mat.roughness = 0.2
	_tube_a = Shapes.cylinder(0.005, 1.0, tube_mat, Vector3.ZERO, -1.0, 5)
	_tube_b = Shapes.cylinder(0.005, 1.0, tube_mat, Vector3.ZERO, -1.0, 5)
	add_child(_tube_a)
	add_child(_tube_b)


## Called by the model every frame.
func follow(model: Node3D, delta: float) -> void:
	var body: Node3D = model.get_parent() as Node3D
	if body == null:
		return
	var hand: Vector3 = model.hand_point(true)
	var fwd: Vector3 = -body.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var floor_y := body.global_position.y
	var target := Vector3(hand.x, floor_y, hand.z) - fwd * 0.12
	if not _placed or base_pos.distance_to(target) > 3.0:
		base_pos = target
		_placed = true
	var before := base_pos
	base_pos = base_pos.lerp(target, clampf(delta * 5.0, 0.0, 1.0))
	base_pos.y = floor_y
	var moved := Vector2(base_pos.x - before.x, base_pos.z - before.z).length()
	rolled += moved

	# Lean the pole so it passes through the grip point.
	var grip := hand
	var up := grip - base_pos
	up = up.normalized() if up.length() > 0.2 else Vector3.UP
	if up.angle_to(Vector3.UP) > 0.42:
		up = Vector3.UP.slerp(up, 0.42 / up.angle_to(Vector3.UP)).normalized()
	var x := up.cross(fwd).normalized()
	if x.length() < 0.1:
		x = Vector3.RIGHT
	var z := x.cross(up).normalized()
	global_transform = Transform3D.IDENTITY
	_pole.global_transform = Transform3D(Basis(x, up, z), base_pos)

	# The bag swings on its hook from the jolts.
	_sway_v += (-_sway * 40.0 - _sway_v * 3.0 + moved / maxf(delta, 0.001) * 0.6 * signf(sin(rolled * 9.0))) * delta
	_sway += _sway_v * delta
	_bag_pivot.rotation.z = clampf(_sway, -0.5, 0.5)

	var drip := _bag_pivot.global_transform * Vector3(0, -0.33, 0)
	var mid := (drip + hand) * 0.5 + Vector3.DOWN * 0.18
	Shapes.stretch_between(_tube_a, drip, mid)
	Shapes.stretch_between(_tube_b, mid, hand)
