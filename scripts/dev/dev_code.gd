extends Node
## The secret knock for the dev room, listening on the title screen.
##
## Deliberately undocumented in the game and the README. See docs/CONTRACTS.md ("Dev room")
## for where it lives; the code itself is below.
##
## While no text field has focus, typing the word arms the menu: a defibrillator charges and
## thumps, and the red title turns blue. Solo and Host then open the dev room instead of a
## hospital. Typing it again disarms.

signal armed_changed(armed: bool)

## Compared against the last letters typed, case-insensitive.
const CODE := "clear"
## Letters further apart than this start over.
const GAP_SECONDS := 2.0

var armed := false
var _typed := ""
var _last_key_ms := 0


func _input(event: InputEvent) -> void:
	var menu := get_parent() as Control
	if menu == null or not menu.is_visible_in_tree():
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	feed(String.chr(event.unicode) if event.unicode > 0 else "")


## One typed character. Public so tests can type without a keyboard.
func feed(ch: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_key_ms > int(GAP_SECONDS * 1000.0):
		_typed = ""
	_last_key_ms = now
	ch = ch.to_lower()
	if ch.length() != 1 or ch < "a" or ch > "z":
		_typed = ""
		return
	_typed = (_typed + ch).right(CODE.length())
	if _typed == CODE:
		_typed = ""
		set_armed(not armed)


func set_armed(on: bool, sound: bool = true) -> void:
	if armed == on:
		return
	armed = on
	var audio := get_node_or_null("/root/Audio")
	if audio != null and sound:
		audio.play("dev_defib" if on else "click")
	armed_changed.emit(on)
