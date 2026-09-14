extends Node
## Sweep 3 stub (main session). Replaced entirely by the `combat` worker; keep the public API.
## Bone saw swings, anesthetic jabs, dragging sedated monsters and strapping them to a patient
## table. See docs/SWEEP3.md.

var game: Node = null


func setup(g: Node) -> void:
	game = g


## Every machine: does left mouse "use" this held kind instead of shoving?
func is_usable(_kind: String) -> bool:
	return false


## Host: p pressed left mouse with a usable item selected.
func use(_p: Node) -> void:
	pass


func physics_tick(_delta: float) -> void:
	pass


func net_state() -> Dictionary:
	return {}


func apply_net_state(_s: Dictionary) -> void:
	pass


func on_event(_kind: String, _data: Dictionary) -> void:
	pass


## Host: every monster is about to be freed (clock-out, new level).
func on_monsters_cleared() -> void:
	pass


## Host: one monster is leaving the game (killed, or strapped onto a table).
func on_monster_removed(_m: Node) -> void:
	pass
