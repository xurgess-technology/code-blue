class_name DatabaseStore
extends RefCounted
## Saves and loads the host's monster database (game.database: kind -> DbRecord) to
## user://database.save. Host-only, plain JSON. The database belongs to the host and survives a
## wipe (game.reset_money / game over) and a full reload (a new Godot process): it is loaded once
## when the game starts and saved whenever a record changes (throttled by the caller).
##
## docs/SWEEP4A.md "Chunk 4": "Saving: the database belongs to the host... survives wipes."

const DbRecordScript := preload("res://scripts/database/db_record.gd")
const PATH := "user://database.save"


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
		var rec := DbRecordScript.new(String(kind))
		rec.from_dict(parsed[kind])
		database[String(kind)] = rec


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
