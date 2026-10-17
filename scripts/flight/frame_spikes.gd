class_name FrameSpikes
extends RefCounted
## Finds what makes a frame stall. Heavy one-off jobs (ground patch rebuild,
## HD texture upload, autosave, the simulation tick...) add their CPU time under
## a name; flight.gd checks every frame and, when one took much longer than
## usual, logs which jobs ran in it ("[hitch] ..."). The last hitches are shown
## in the profiler.

static var _marks := {}
static var recent: Array[String] = []   ## newest last, a few entries
static var min_ms := 45.0               ## never report frames shorter than this


static func now() -> int:
	return Time.get_ticks_usec()


## Adds the time since `since` (from now()) to the job `name` of this frame.
static func add(name: String, since: int) -> void:
	_marks[name] = int(_marks.get(name, 0)) + (Time.get_ticks_usec() - since)


## Called once per frame with the real frame time. Returns a report or "".
static func check(frame_ms: float, typical_ms: float) -> String:
	var m := _marks
	_marks = {}
	if frame_ms < maxf(typical_ms * 1.8, min_ms):
		return ""
	var parts: Array[String] = []
	var keys := m.keys()
	keys.sort_custom(func(a, b) -> bool: return int(m[a]) > int(m[b]))
	for k in keys:
		var ms := int(m[k]) / 1000.0
		if ms >= 1.0:
			parts.append("%s %.0f" % [k, ms])
	var line := "%.0f мс (обычно %.0f): %s" % [frame_ms, typical_ms, ", ".join(parts) if not parts.is_empty() else "не наш код (рендер / шейдеры / система)"]
	recent.append(line)
	if recent.size() > 4:
		recent.pop_front()
	return line
