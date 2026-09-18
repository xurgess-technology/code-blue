class_name DatabaseStore
extends RefCounted
## Saves and loads this machine's player's own monster database (game.database: kind -> DbRecord)
## to user://database.save, plain JSON. Every player keeps their own (Zach, 2026-09-16: the terminal
## is the individual's database): it survives a wipe (game.reset_money / game over) and a full
## reload, is loaded once when the game starts and saved whenever one of its records changes.

const DbRecordScript := preload("res://scripts/database/db_record.gd")
const PATH := "user://database.save"
const LEGACY_HIVE_KIND := "walk" + "_in"   # the Hive's kind id before the rename (split so a rename sweep keeps it)


static func load_into(database: Dictionary) -> void:
	if not FileAccess.file_exists(PATH):
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	for kind in (parsed as Dictionary).keys():
		var k := String(kind)
		# 2026-09-17: the Walk-In became the Hive; saves from before keep its page.
		if k == LEGACY_HIVE_KIND:
			if (parsed as Dictionary).has("hive"):
				continue
			k = "hive"
		var rec := DbRecordScript.new(k)
		rec.from_dict(parsed[kind])
		database[k] = rec


static func save(database: Dictionary) -> void:
	var out := {}
	for kind in database.keys():
		var rec: DbRecord = database[kind]
		out[kind] = rec.to_dict()
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(out))
	f.close()
