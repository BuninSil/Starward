class_name ApTask
extends RefCounted
## One autopilot task. The Autopilot runs a queue of these in order.

enum { RUNNING, DONE, FAILED }

var title := ""     ## shown in the mission list, e.g. "Орбита 20 км"
var status := ""    ## current phase text
var message := ""   ## result text when finished


## Called once when the task becomes current.
func start(_ap: Autopilot, _v: Vessel, _t: float) -> void:
	pass


## Called every physics tick (also during rails warp). Returns RUNNING/DONE/FAILED.
func update(_ap: Autopilot, _v: Vessel, _t: float) -> int:
	return DONE


## Called when the autopilot is stopped while this task runs.
func stop(_v: Vessel) -> void:
	pass


## Drops a spent engine stage if an engine remains above it.
static func auto_stage(v: Vessel) -> void:
	var s := v.active_stage()
	if s.is_empty() or v.infinite_fuel:
		return
	if s.has_engine and s.fuel <= 0.0 and v.stages.size() > 2:
		v.stage()
	elif not s.has_engine and v.stages.size() > 1:
		# A spent/engineless lower stage (e.g. decoupler only).
		v.stage()


## Warp factor to coast toward an event `dt` seconds away.
static func warp_for(dt: float) -> int:
	if dt > 4.0 * 3600.0:
		return 10000
	if dt > 1200.0:
		return 1000
	if dt > 240.0:
		return 100
	if dt > 60.0:
		return 10
	return 1
