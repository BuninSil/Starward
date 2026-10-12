extends Node
## The current game: mode (career / sandbox), inventories, save slots.
## Saves are JSON in user://saves/: "autosave" and "slot1".."slot3". A save
## holds a header (time, mode, where, playtime), the inventories and the flight
## state (Flight.save_state()). Loading stores the flight state in `pending`
## and opens the flight scene, which applies it in _ready.

signal inventories_changed

const SAVE_DIR := "user://saves/"
const SLOTS := ["slot1", "slot2", "slot3"]
const VERSION := 1
const AUTOSAVE := "autosave"

var mode := ""                 ## "career" / "sandbox"; "" = no game started
var astro_inv: Inventory
var ship_inv: Inventory
var pending: Dictionary = {}   ## flight state to apply when the flight scene starts
var playtime := 0.0


func _ready() -> void:
	_fresh_inventories()


func _process(delta: float) -> void:
	if mode != "":
		playtime += delta


func _fresh_inventories() -> void:
	astro_inv = Inventory.new(12, "Скафандр")
	ship_inv = Inventory.new(24, "Корабль")
	astro_inv.changed.connect(func() -> void: inventories_changed.emit())
	ship_inv.changed.connect(func() -> void: inventories_changed.emit())


static func mode_title(m: String) -> String:
	return {"career": "Карьера", "sandbox": "Песочница"}.get(m, "—")


func new_game(m: String, design: String) -> void:
	mode = m
	Vessel.design = design
	pending = {}
	playtime = 0.0
	_fresh_inventories()
	# Starting kit: a little in career, plenty in the sandbox.
	if m == "sandbox":
		for it in [["oxygen", 20], ["parts", 50], ["metal", 50], ["fuel", 100], ["ice", 250]]:
			ship_inv.add(it[0], it[1])
		astro_inv.add("oxygen", 4)
	else:
		ship_inv.add("oxygen", 4)
		ship_inv.add("parts", 5)
		astro_inv.add("oxygen", 1)
	Log.info("Game: new %s game, rocket %s" % [m, design])


func has_game() -> bool:
	return mode != ""


# --- Files ---------------------------------------------------------------------

func _path(slot: String) -> String:
	return SAVE_DIR + slot + ".json"


func save_to(slot: String, flight: Node) -> bool:
	if mode == "" or flight == null:
		return false
	var d := {
		"version": VERSION,
		"time": Time.get_unix_time_from_system(),
		"mode": mode,
		"design": Vessel.design,
		"playtime": playtime,
		"where": flight.where_text(),
		"astro": astro_inv.to_data(),
		"ship": ship_inv.to_data(),
		"flight": flight.save_state(),
	}
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	# Write to a temp file first: a crash mid-write must not eat the old save.
	var tmp := _path(slot) + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		Log.error("Game: cannot write %s (%d)" % [tmp, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(d, "", false, true))
	f.close()
	var err := DirAccess.rename_absolute(tmp, _path(slot))
	if err != OK:
		Log.error("Game: rename failed for %s (%d)" % [slot, err])
		return false
	Log.info("Game: saved %s (%s)" % [slot, d.where])
	return true


func _read(slot: String) -> Dictionary:
	if not FileAccess.file_exists(_path(slot)):
		return {}
	var txt := FileAccess.get_file_as_string(_path(slot))
	var d = JSON.parse_string(txt)
	if typeof(d) != TYPE_DICTIONARY or not d.has("flight"):
		Log.warn("Game: save %s is damaged" % slot)
		return {}
	return d


## Header of a slot for the menus: {} if empty.
func slot_info(slot: String) -> Dictionary:
	var d := _read(slot)
	if d.is_empty():
		return {}
	return {"time": float(d.get("time", 0.0)), "mode": str(d.get("mode", "")),
		"where": str(d.get("where", "")), "playtime": float(d.get("playtime", 0.0))}


## The most recent save (autosave or a slot), or "".
func latest_slot() -> String:
	var best := ""
	var best_t := -1.0
	for s in [AUTOSAVE] + SLOTS:
		var info := slot_info(s)
		if not info.is_empty() and info.time > best_t:
			best_t = info.time
			best = s
	return best


## Loads a slot into memory and opens the flight scene. False if it is empty.
func load_from(slot: String) -> bool:
	var d := _read(slot)
	if d.is_empty():
		return false
	mode = str(d.get("mode", "career"))
	Vessel.design = str(d.get("design", "moon"))
	playtime = float(d.get("playtime", 0.0))
	_fresh_inventories()
	astro_inv = Inventory.from_data(d.get("astro", {}), 12)
	ship_inv = Inventory.from_data(d.get("ship", {}), 24)
	astro_inv.changed.connect(func() -> void: inventories_changed.emit())
	ship_inv.changed.connect(func() -> void: inventories_changed.emit())
	pending = d.flight
	Log.info("Game: loading %s (%s)" % [slot, d.get("where", "")])
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/flight.tscn")
	return true


static func fmt_date(unix: float) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(int(unix) + _tz_offset())
	return "%02d.%02d %02d:%02d" % [dt.day, dt.month, dt.hour, dt.minute]


static func _tz_offset() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


static func fmt_playtime(s: float) -> String:
	var m := int(s) / 60
	return "%d ч %02d мин" % [m / 60, m % 60] if m >= 60 else "%d мин" % m
