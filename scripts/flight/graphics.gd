class_name Graphics
extends RefCounted
## Graphics preset, kept in user://settings.cfg. High: detailed ground (several
## materials, stochastic tiling, crater decals, micro shadows), sun shadows near
## the ground, pebbles. Low: plain ground, no shadows, fewer rocks.

const PATH := "user://settings.cfg"
const LOW := 0
const HIGH := 1

static var quality: int = _load()


static func _load() -> int:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		return int(cf.get_value("graphics", "quality", HIGH))
	return HIGH


static func set_quality(q: int) -> void:
	quality = q
	var cf := ConfigFile.new()
	cf.load(PATH)
	cf.set_value("graphics", "quality", q)
	cf.save(PATH)


static func label() -> String:
	return "высокая" if quality == HIGH else "низкая"


# --- Frame rate ------------------------------------------------------------------
# Auto: the screen's top refresh rate (120 / 90 / 60 Hz, whatever the phone
# has; Android keeps apps at 60 Hz unless asked). 60 / 30: fixed caps (30 saves
# battery). The frame cap always follows the refresh rate actually chosen.

const FPS_AUTO := 0
const FPS_60 := 1
const FPS_30 := 2

static var fps_mode: int = _load_fps()
static var screen_hz := 60.0   ## refresh rate in use after apply_fps()


static func _load_fps() -> int:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		return int(cf.get_value("graphics", "fps", FPS_AUTO))
	return FPS_AUTO


static func set_fps_mode(m: int) -> void:
	fps_mode = m
	var cf := ConfigFile.new()
	cf.load(PATH)
	cf.set_value("graphics", "fps", m)
	cf.save(PATH)
	apply_fps()


## Picks the display mode and the frame cap for the current setting.
static func apply_fps() -> void:
	var want_hz := 1000.0 if fps_mode == FPS_AUTO else 60.0
	var hz := 0.0
	if Engine.has_singleton("StarwardUpdater"):
		var plugin := Engine.get_singleton("StarwardUpdater")
		if plugin.has_method("requestRefreshRate"):
			hz = float(plugin.call("requestRefreshRate", want_hz))
	if hz <= 0.0:
		hz = DisplayServer.screen_get_refresh_rate()
	if hz <= 0.0:
		hz = 60.0
	screen_hz = minf(hz, want_hz)
	Engine.max_fps = 30 if fps_mode == FPS_30 else int(round(screen_hz))


static func fps_label() -> String:
	match fps_mode:
		FPS_60:
			return "60 FPS"
		FPS_30:
			return "30 FPS (экономия батареи)"
	return "авто (%d Гц)" % int(round(screen_hz))
