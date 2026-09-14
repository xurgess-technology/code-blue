extends Node
## Sweep 3 stub (main session). Replaced entirely by the `brains` worker; keep the public API.
## Brain spoilage, the break-room blender, per-player upgrades, Echo and Hive Eyes. See
## docs/SWEEP3.md.

var game: Node = null


func setup(g: Node) -> void:
	game = g


## Host: p pressed R.
func ability(_p: Node) -> void:
	pass


## Host: game over. Every player's absorbed brains are gone.
func on_reset() -> void:
	pass


func physics_tick(_delta: float) -> void:
	pass


func net_state() -> Dictionary:
	return {}


func apply_net_state(_s: Dictionary) -> void:
	pass


func on_event(_kind: String, _data: Dictionary) -> void:
	pass
