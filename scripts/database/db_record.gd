class_name DbRecord
extends RefCounted
## SWEEP 4A HOOK (scanner, docs/SWEEP4A.md "Scanner"): one species' record in the host's in-memory
## monster database. `sighted` (seen by any player, in range, with line of sight) and `scanned`
## (a player held R on it long enough) are both host-only for now, kept in memory and lost on
## restart; chunk 4 (docs/backlog/SWEEP4B.md) extends this class and saves it to disk.

var kind: String = ""
var sighted: bool = false
var scanned: bool = false


func _init(k: String = "") -> void:
	kind = k
