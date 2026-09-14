extends Node
## Sweep 3 stub (main session). Replaced entirely by the `dissection` worker; keep the public API.
## Monster cases on the patient tables: sedation wearing off, re-dosing, the brain. See
## docs/SWEEP3.md.

var game: Node = null


func setup(g: Node) -> void:
	game = g


## Every machine: is this case a strapped monster this system runs (no vitals drain, no pay)?
func owns_case(c: Dictionary) -> bool:
	return bool(c.get("monster", false))


func physics_tick(_delta: float) -> void:
	pass


func net_state() -> Dictionary:
	return {}


func apply_net_state(_s: Dictionary) -> void:
	pass


func on_event(_kind: String, _data: Dictionary) -> void:
	pass
