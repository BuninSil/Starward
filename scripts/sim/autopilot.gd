class_name Autopilot
extends RefCounted
## Task-based autopilot. Runs a queue of ApTask objects (a mission chain) using the
## same controls as the player: attitude hold, throttle, staging, time warp.
## Any manual input stops it (handled by the HUD).

signal finished(success: bool, message: String)
signal task_changed(title: String)

var queue: Array[ApTask] = []
var current: ApTask = null
var requested_warp := 1        ## desired time warp; flight applies it on change
var wants_warp_reset := false  ## force 1x now (before burns)
var node: ManeuverNode = null  ## maneuver being executed (shown on the map)
var log_prefix := "Autopilot"


func active() -> bool:
	return current != null


func status() -> String:
	if current == null:
		return ""
	var s := current.title
	if current.status != "":
		s += ": " + current.status
	if queue.size() > 0:
		s += "  (ещё задач: %d)" % queue.size()
	return s


## Titles of the running + queued tasks.
func titles() -> PackedStringArray:
	var out := PackedStringArray()
	if current:
		out.append("▶ " + current.title)
	for q in queue:
		out.append(q.title)
	return out


func start_chain(tasks: Array, v: Vessel, t: float) -> void:
	stop(v)
	for task in tasks:
		queue.append(task)
	_next(v, t)


## Inserts tasks to run right after the current one.
func insert_next(tasks: Array) -> void:
	for i in range(tasks.size() - 1, -1, -1):
		queue.push_front(tasks[i])


func stop(v: Vessel) -> void:
	if current:
		current.stop(v)
	current = null
	queue.clear()
	node = null
	requested_warp = 1
	if v and v.hold_mode == "target":
		v.hold_mode = ""


## Legacy single-task API used by the HUD button.
func disengage(v: Vessel) -> void:
	stop(v)


func update(v: Vessel, t: float) -> void:
	if current == null:
		return
	if v.destroyed_flag:
		_finish(v, false, "Ракета разрушена")
		return
	var res := current.update(self, v, t)
	if res == ApTask.RUNNING:
		return
	var msg := current.message
	if res == ApTask.FAILED:
		_finish(v, false, "%s — %s" % [current.title, msg])
		return
	print("[I] ", "%s: done '%s' %s" % [log_prefix, current.title, msg])
	if queue.is_empty():
		_finish(v, true, msg if msg != "" else current.title)
	else:
		_next(v, t)


func _next(v: Vessel, t: float) -> void:
	current = queue.pop_front() if not queue.is_empty() else null
	if current:
		print("[I] ", "%s: start '%s'" % [log_prefix, current.title])
		current.start(self, v, t)
		task_changed.emit(current.title)


func _finish(v: Vessel, ok: bool, msg: String) -> void:
	current = null
	queue.clear()
	node = null
	requested_warp = 1
	v.throttle = 0.0
	if v.hold_mode == "target":
		v.hold_mode = ""
	v.sas = true
	finished.emit(ok, msg)


# --- Mission building blocks -----------------------------------------------------------

static func tasks_orbit(alt: float) -> Array:
	return [ApAscent.new(alt)]


static func tasks_circularize(where := "apo") -> Array:
	return [ApPlan.new("circularize", {"where": where})]


static func tasks_moon(root: CelestialBody, moon_alt: float) -> Array:
	var moon := SolarSystem.find(root, "Луна")
	return [
		ApPlan.new("transfer", {"target": moon, "alt": moon_alt}),
		ApPlan.new("correction", {"target": moon, "alt": moon_alt}),
		ApCoast.new("soi", {"body": moon}),
		# The correction can settle in a poor local optimum: trim the periapsis
		# on arrival (skipped when already within 3 km).
		ApPlan.new("peri_correction", {"alt": moon_alt}),
		ApPlan.new("circularize", {"where": "peri"}),
	]


## From an orbit around a planet to an orbit around another planet (same Sun).
static func tasks_planet(target: CelestialBody, alt: float) -> Array:
	return [
		ApPlan.new("interplanetary", {"target": target, "alt": alt}),
		ApCoast.new("soi_parent", {}),
		ApPlan.new("correction", {"target": target, "alt": alt}),
		ApCoast.new("soi", {"body": target}),
		# Months of cruise turn a 0.05 m/s burn error into hundreds of km:
		# trim the periapsis right after entering the SOI, then capture.
		ApPlan.new("peri_correction", {"alt": alt}),
		ApPlan.new("circularize", {"where": "peri"}),
	]


## Back to Earth from another planet's orbit: transfer, aim into the atmosphere, chute.
static func tasks_planet_home(earth: CelestialBody, earth_peri_alt := 3000.0) -> Array:
	return [
		ApPlan.new("interplanetary", {"target": earth, "alt": earth_peri_alt}),
		ApCoast.new("soi_parent", {}),
		ApPlan.new("correction", {"target": earth, "alt": earth_peri_alt}),
		ApCoast.new("soi", {"body": earth}),
		ApPlan.new("peri_correction", {"alt": earth_peri_alt}),
		ApCoast.new("atmosphere", {}),
		ApLand.new(),
	]


static func tasks_home(earth_peri_alt := 3000.0) -> Array:
	return [
		ApPlan.new("return", {"alt": earth_peri_alt}),
		ApCoast.new("soi_parent", {}),
		ApPlan.new("peri_correction", {"alt": earth_peri_alt}),
		ApCoast.new("altitude", {"alt": 6_000_000.0}),
		ApPlan.new("peri_correction", {"alt": earth_peri_alt}),
		ApCoast.new("atmosphere", {}),
		ApLand.new(),
	]


static func tasks_deorbit() -> Array:
	return [
		ApPlan.new("deorbit", {"alt": 3000.0}),
		ApCoast.new("atmosphere", {}),
		ApLand.new(),
	]


## Powered landing from orbit around an airless body (the Moon).
static func tasks_moon_land(peri_alt := 6000.0) -> Array:
	return [
		ApPlan.new("moon_deorbit", {"alt": peri_alt}),
		ApDescent.new(),
	]


## Liftoff from an airless body to a circular orbit (drops the descent stage).
static func tasks_moon_ascent(alt := 20_000.0, body: CelestialBody = null, t := 0.0) -> Array:
	var asc := ApAscent.new(alt)
	asc.title = "Взлёт на орбиту %d км" % int(alt / 1000.0)
	if body != null and body.parent != null:
		# Launch into the plane of the moon's own orbit: the way home is in that
		# plane, so the return burn stays cheap.
		var st: Array = body.state_at(t)
		asc.plane_normal = (st[0] as DVec3).cross(st[1]).normalized().to_v3()
	return [ApLiftoff.new(), asc]


static func tasks_execute(n: ManeuverNode) -> Array:
	return [ApExecute.new(n)]
