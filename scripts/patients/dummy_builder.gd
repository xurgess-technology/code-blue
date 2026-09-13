extends RefCounted
## Fallback body when the Kenney human asset is missing: a blocky primitive man in the same
## frame (head -X, face up, removable forearm on +Z). Same parts and sites as Bob, cruder.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const SkinShader := preload("res://scripts/patients/bob_skin.gdshader")


static func build(b) -> bool:
	var rig: Node3D = b.rig
	var sm := ShaderMaterial.new()
	sm.shader = SkinShader
	b.skin_mats.append(sm)
	b.breath_amp = 0.0
	var gown := Kit.mat("dummy_gown", Color(0.5, 0.66, 0.7), 0.9)
	var skin := Kit.mat("dummy_skin", Color(0.9, 0.7, 0.55), 0.8)
	Kit.add_mesh(rig, Kit.box(Vector3(0.7, 0.26, 0.5)), gown, Transform3D(Basis(), Vector3(-0.1, 0.13, 0)), "Torso")
	Kit.add_mesh(rig, Kit.sphere(0.17, 10, 6), skin, Transform3D(Basis(), Vector3(-0.62, 0.17, 0)), "Head")
	for sgn in [-1.0, 1.0]:
		Kit.add_mesh(rig, Kit.box(Vector3(0.62, 0.14, 0.16)), gown, Transform3D(Basis(), Vector3(0.52, 0.07, sgn * 0.12)), "Leg")
	var arm := Node3D.new()
	arm.name = "ArmL"
	arm.position = Vector3(-0.35, 0.07, 0.33)
	rig.add_child(arm)
	Kit.add_mesh(arm, Kit.box(Vector3(0.3, 0.1, 0.11)), gown, Transform3D(Basis(), Vector3(0.15, 0, 0)), "Upper")
	var fore := Node3D.new()
	fore.name = "Forearm"
	fore.position = Vector3(0.3, 0, 0)
	arm.add_child(fore)
	Kit.add_mesh(fore, Kit.box(Vector3(0.32, 0.09, 0.1)), skin, Transform3D(Basis(), Vector3(0.16, 0, 0)), "Lower")
	Kit.add_mesh(rig, Kit.box(Vector3(0.6, 0.1, 0.11)), skin, Transform3D(Basis(), Vector3(-0.05, 0.05, -0.33)), "ArmR")
	b.parts["limb_node"] = fore
	var sites := {
		"injection": Transform3D(Basis(), Vector3(0.0, 0.1, -0.33)),
		"gunshot": Transform3D(Basis(), Vector3(0.0, 0.26, 0.08)),
		"limb": Transform3D(Basis(), Vector3(-0.18, 0.12, 0.33)),
		"limb_cut": Transform3D(Basis(), Vector3(-0.04, 0.12, 0.33)),
	}
	for s in sites:
		var a := Node3D.new()
		a.name = s
		a.transform = sites[s]
		rig.add_child(a)
		b.anchors[s] = a
		b._sites[s] = sites[s]
		b.drips[s] = [sites[s].origin, Vector3(sites[s].origin.x, 0.003, sites[s].origin.z + 0.1)]
	for s in ["limb", "limb_cut"]:
		b.sections[s] = {"half_up": 0.05, "half_side": 0.055, "axis_depth": 0.05, "shape": 6.0}
	# No painted infection; report it where the forearm begins, just past the cut.
	b.infection["limb"] = 0.15
	b.infection["limb_cut"] = 0.01
	b.parts["tourniquet"] = Kit.make_tourniquet(b.anchors["limb"], 0.05, 0.055, 0.05)
	b.parts["stump"] = Kit.make_stump(b.anchors["limb_cut"], 0.05, 0.055, 0.05, 0.015)
	b.parts["dress_stump"] = Kit.make_stump_dressing(b.anchors["limb_cut"], 0.05, 0.055, 0.05)
	b.parts["wound"] = Kit.make_wound(b.anchors["gunshot"], 0.022)
	b.parts["dress_wound"] = Kit.make_pad(b.anchors["gunshot"], 0.12)
	return true


static func animate(_b, _jolt: float, _env: float, _fidget: float, _twitch: float, _t: float) -> void:
	pass


static func set_limb_removed(b, removed: bool) -> void:
	(b.parts["limb_node"] as Node3D).visible = not removed


static func make_severed_limb(b, parent: Node) -> Node3D:
	var src: Node3D = b.parts.get("limb_node")
	if src == null:
		return null
	var copy := src.duplicate() as Node3D
	parent.add_child(copy)
	copy.global_transform = src.global_transform
	copy.visible = true
	return copy
