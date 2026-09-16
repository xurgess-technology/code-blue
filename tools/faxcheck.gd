extends Node
## Quick headless run of the pharmacy's fax order and the waiting room's Night Nurse (hub rebuild,
## chunk 3): starts a solo shift, gives the team money, fills in the order form (3 sets of pills),
## orders them, and follows the order until the pickup drawer serves them; then forces the waiting
## nurse to get up and walk.
##
##   godot --headless --path . tools/faxcheck.tscn

var main: Node3D
var game: Game


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	if main.launching:
		await main.launched
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Fax")
	game.start_session(4242)
	for i in 120:
		await get_tree().process_frame
	var ok := true
	var ph = game.economy.pharmacy
	print("[faxcheck] economy placed=%s mode=%s terminal=%s nurse=%s" % [game.economy.placed(), game.economy.mode,
			str(game.find_interactable("pharmacy_fax") != null), str(game.economy.waiting_nurse != null)])
	game.add_money(200, "test")
	# The order form: tick pills, step the quantity up to 3 sets.
	var ui = game.economy.fax_ui
	ui.open(game)
	await get_tree().process_frame
	var row: Dictionary = ui._rows[0]
	row.box.pressed.emit()
	ui._step(row, 1)
	ui._set_qty(row, ui._qty(row) + 1)
	ui._refresh()
	print("[faxcheck] form qty %d, %s, send disabled %s" % [ui._qty(row), ui._total.text, str(ui._send.disabled)])
	ok = ui._qty(row) == 3 and ui._total.text.ends_with("$%d" % (3 * game.PILL_PRICE)) and ok
	ui.close()
	var before := game.world_items.size()
	var me = game.local_player()
	var money_before: int = game.money
	ok = game.order_pharmacy(me, {"placebo_pills": 3}) and ok
	ok = game.money == money_before - 3 * game.PILL_PRICE and ok
	print("[faxcheck] ordered 3 sets, money %d, busy %s" % [game.money, str(ph.busy())])
	var phases := {}
	var served := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 90000:
		await get_tree().process_frame
		phases[ph._phase] = true
		if game.world_items.size() > before:
			served = true
			var counts := []
			for it in game.world_items.values():
				if it.kind == "placebo_pills":
					counts.append(it.count)
			ok = counts.has(3 * game.PILL_COUNT) and ok
			print("[faxcheck] served after %.1f s, pill stacks %s" % [(Time.get_ticks_msec() - t0) / 1000.0, str(counts)])
			break
	print("[faxcheck] phases seen %s, served %s, drawer %s" % [str(phases.keys()), str(served), ph._drawer_state])
	var wn = game.economy.waiting_nurse
	wn._hold = 0.0
	var moved := false
	var start: Vector3 = wn.pos
	for i in 60 * 20:
		await get_tree().process_frame
		if wn.pos.distance_to(start) > 1.0:
			moved = true
			break
	print("[faxcheck] nurse mode %s sit %.2f moved %s seen %s" % [wn._mode, wn.sit, str(moved), str(wn.seen)])
	print("[faxcheck] result=%s" % ("PASS" if ok and served else "FAIL"))
	get_tree().quit(0 if ok and served else 1)
