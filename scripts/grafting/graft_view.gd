extends CanvasLayer
## GRAFTING chunk C (docs/GRAFTING.md): the first-person tell. A grafted surgeon sees a faint orange
## wash down the LEFT edge of their view -- the side the Hive eyeball is on -- and it comes up while
## Hive Eyes is running.
##
## It sits ABOVE the look pass's grain, vignette and teal grade (scripts/look.gd, canvas layer 50),
## which the HUD deliberately sits under: graded, a faint orange on a teal picture disappears
## completely. Local and cosmetic; what drives it (game.grafts.local_lock) is replicated, so it can
## never disagree with the glow everyone else sees on the eye.

const LAYER := 52

var wash: Control = null


## The wash itself. Its own constants: an inner class cannot see the outer script's when the script
## has no class_name (CLAUDE.md).
class Wash extends Control:
	const TINT := Color(1.0, 0.33, 0.05)
	const BANDS := 8
	## How far across the screen it reaches, at rest and while Hive Eyes runs.
	const WIDTH := Vector2(0.20, 0.30)
	## Total alpha at the very edge, at rest and while Hive Eyes runs.
	const ALPHA := Vector2(0.22, 0.6)

	var game: Node = null
	var t := 0.0
	## Tests: true while the last frame drew anything.
	var showing := false

	func _process(delta: float) -> void:
		t += delta
		queue_redraw()

	func _draw() -> void:
		showing = false
		if game == null or game.grafts == null or bool(game.paused):
			return
		if int(game.phase) == 0:   # Game.Phase.MENU
			return
		var lock: float = float(game.grafts.local_lock())
		if lock < 0.0:
			return   # no graft: nothing to see
		var k := clampf(lock, 0.0, 1.0)
		var a: float = lerpf(ALPHA.x, ALPHA.y, k) * (0.9 + 0.1 * sin(t * 2.1))
		var wide: float = size.x * lerpf(WIDTH.x, WIDTH.y, k)
		# Soft bands: strongest and narrowest at the edge, fading out across.
		for i in BANDS:
			var f := float(i + 1) / float(BANDS)
			draw_rect(Rect2(0.0, 0.0, wide * f, size.y),
				Color(TINT.r, TINT.g, TINT.b, a / float(BANDS)))
		showing = true


static func create(game: Node) -> CanvasLayer:
	var l: CanvasLayer = (load("res://scripts/grafting/graft_view.gd") as GDScript).new()
	l.name = "GraftView"
	l.layer = LAYER
	var w := Wash.new()
	w.name = "Wash"
	w.game = game
	w.mouse_filter = Control.MOUSE_FILTER_IGNORE
	w.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.add_child(w)
	l.wash = w
	return l
