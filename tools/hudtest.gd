extends Node
## Headless check of the icon item bar's layout and the icon lookups (docs/ITEMS_AND_ICONS.md, chunk C).
##
##   godot --headless --fixed-fps 60 --path . tools/hudtest.tscn
##
## The bar's geometry is pure (Hud.bar_units), so it is checked here without a draw: one unit per hand
## slot, a bulky stack as one wide unit across two adjacent slots, the selected unit lifted, the Alt
## row's small squares, and a bulky pair that wraps round the bar left as two. Every kind in
## categories.json has a bare and a framed icon, and the greyscale copy is grey.

var fails := 0
var checks := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	checks += 1
	if ok:
		print("[hud] ok    ", what)
	else:
		fails += 1
		print("[hud] FAIL  ", what)


func _slots(spec: Array) -> Array:
	var out := []
	for s in spec:
		out.append(s)
	return out


func _run() -> void:
	var w := 1280.0
	var h := 720.0
	var e := {"kind": "", "count": 0}
	# Four empty slots: four units, all in one row across the bottom centre.
	var u: Array = Hud.bar_units(w, h, [e.duplicate(), e.duplicate(), e.duplicate(), e.duplicate()], 0, 0.0)
	_check(u.size() == C.CARRY_CAP, "an empty bar draws a slot per hand slot (%d)" % u.size())
	var xs := 0.0
	for x in u:
		xs += (x.rect as Rect2).get_center().x
	_check(absf(xs / u.size() - w * 0.5) < 6.0, "the bar is centred")
	_check(int(u[0].slot) == 0 and String(u[0].keys) == "1" and String(u[3].keys) == "4", "key numbers 1 to 4")
	_check((u[0].rect as Rect2).position.y < (u[1].rect as Rect2).position.y, "the selected slot is lifted")
	_check((u[0].rect as Rect2).size.x > (u[1].rect as Rect2).size.x, "the selected slot is bigger")
	# A bulky stack in slots 1 and 2: one wide unit, the tail slot gone.
	var s := [{"kind": "anesthetic", "count": 2}, {"kind": "heart_monitor", "count": 1}, {"kind": "", "count": 0, "of": 1}, e.duplicate()]
	u = Hud.bar_units(w, h, s, 0, 0.0)
	_check(u.size() == 3, "a bulky stack takes one wide slot across two (units %d)" % u.size())
	var wide := 0
	for x in u:
		if x.wide:
			wide += 1
			_check((x.rect as Rect2).size.x > 100.0 and String(x.keys) == "2", "the wide slot spans both and is keyed 2")
	_check(wide == 1, "exactly one wide slot")
	# Selecting the bulky stack lifts the whole wide slot; selecting its tail does the same (head_of).
	u = Hud.bar_units(w, h, s, 1, 0.0)
	var sel_wide := false
	for x in u:
		if x.wide and x.sel:
			sel_wide = true
	_check(sel_wide, "the selected bulky stack lifts as one wide slot")
	# The tail listed before the head (the pair wraps): still one wide slot.
	s = [{"kind": "", "count": 0, "of": 1}, {"kind": "defibrillator", "count": 1}, e.duplicate(), e.duplicate()]
	u = Hud.bar_units(w, h, s, 1, 0.0)
	_check(u.size() == 3 and (u[0].wide or u[1].wide), "a tail before its head still joins into one wide slot")
	# Non-adjacent halves (slots 0 and 3): two squares, the far one a ghost.
	s = [{"kind": "ultrasound", "count": 1}, e.duplicate(), e.duplicate(), {"kind": "", "count": 0, "of": 0}]
	u = Hud.bar_units(w, h, s, 0, 0.0)
	_check(u.size() == 4 and not u[0].wide and u[3].ghost, "a bulky pair that does not touch stays two squares (ghost half)")
	# Alt held: the small row, no wide slots, no lift.
	s = [{"kind": "anesthetic", "count": 2}, {"kind": "heart_monitor", "count": 1}, {"kind": "", "count": 0, "of": 1}, e.duplicate()]
	u = Hud.bar_units(w, h, s, 0, 1.0)
	var small_ok := u.size() == 4
	for x in u:
		small_ok = small_ok and (x.rect as Rect2).size.x < 40.0 and not x.wide
	_check(small_ok, "with Alt held every slot is a small square")
	# Icons.
	var data = JSON.parse_string(FileAccess.get_file_as_string(ItemIcons.CATEGORIES))
	var missing := []
	for k in (data.items as Dictionary).keys():
		if ItemIcons.bare(k) == null or ItemIcons.framed(k) == null:
			missing.append(k)
	_check(missing.is_empty(), "every kind in categories.json has a bare and a framed icon %s" % str(missing))
	_check(ItemIcons.bare("eye_hive") != null and ItemIcons.bare("eye_surgeon") != null, "the game's eye kinds find their art")
	_check(ItemIcons.bare("zzz_new_kind") == null and ItemIcons.border("zzz_new_kind") == ItemIcons.DEFAULT_BORDER, "an unknown kind falls back to a plain slot")
	_check(ItemIcons.border("forceps").is_equal_approx(Color("3fa860")) == false and ItemIcons.border("forceps").is_equal_approx(Color("3f86d6")), "surgery items have the doctor-blue border")
	_check(ItemIcons.is_trinket("laptop") and not ItemIcons.is_trinket("gold_watch"), "trinkets are the gold-border kinds")
	var g := ItemIcons.grey("hive_eyeball")
	_check(g != null, "a greyscale icon is made")
	if g != null:
		var img := g.get_image()
		var grey_ok := true
		for _i in 200:
			var p := img.get_pixel(randi() % img.get_width(), randi() % img.get_height())
			if p.a > 0.5 and (absf(p.r - p.g) > 0.02 or absf(p.g - p.b) > 0.02):
				grey_ok = false
		_check(grey_ok, "the greyscale icon has no colour left")
	_check(ItemIcons.ability("hive_in") != null and ItemIcons.ability("echo") != null and ItemIcons.ability("zzz") == null, "ability icons, and none for an unknown one")
	_check(ItemIcons.kind_named("Forceps") == "forceps", "a step's item name finds its kind")
	print("[hud] result=%s checks=%d fails=%d" % ["PASS" if fails == 0 else "FAIL", checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
