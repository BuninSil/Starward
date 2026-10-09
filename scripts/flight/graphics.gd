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
