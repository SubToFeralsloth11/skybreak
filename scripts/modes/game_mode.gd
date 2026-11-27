class_name GameMode
extends RefCounted
## Base class for game modes. The Session calls these hooks.

var s: Session


func start() -> void:
	pass


func tick(_dt: float) -> void:
	pass


func hud_info() -> Dictionary:
	return {}


func on_player_destroyed() -> void:
	pass


func on_aircraft_destroyed(_a: Aircraft) -> void:
	pass


func on_touchdown(_vs: float) -> void:
	pass


# ------------------------------------------------------------------ persistence

const SAVE_PATH := "user://skybreak.cfg"


static func load_value(key: String, default: Variant) -> Variant:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return default
	return cf.get_value("records", key, default)


static func save_value(key: String, value: Variant) -> void:
	var cf := ConfigFile.new()
	cf.load(SAVE_PATH)
	cf.set_value("records", key, value)
	cf.save(SAVE_PATH)


static func fmt_time(t: float) -> String:
	return "%d:%05.2f" % [int(t) / 60, fmod(t, 60.0)]
