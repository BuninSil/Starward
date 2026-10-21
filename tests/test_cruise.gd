extends SceneTree
## Supercruise: from a low Earth orbit to the Moon and to Mars with the
## target set and "aim" on; the ship must arrive by itself, drop out near the
## target's drop altitude and keep flying with flight assist.
## godot --headless --path . --script tests/test_cruise.gd

var f: Node
var frames := 0
var fails := 0
var leg := 0
var t_leg := 0.0
var max_speed := 0.0
const LEGS := ["Луна", "Марс"]
const LIMIT := [120.0, 400.0]


func _initialize() -> void:
	Vessel.design = "ship"
	f = load("res://scenes/flight.tscn").instantiate()
	root.add_child(f)


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		fails += 1


func _start(v: Vessel) -> void:
	var target: CelestialBody = null
	for b in v.all_bodies():
		if b.name == LEGS[leg]:
			target = b
	v.cruise_target = target
	v.cruise_aim = true
	v.throttle = 1.0
	var why := v.cruise_start(f.sim_time)
	_check(why == "", "cruise engaged towards %s (%s)" % [target.name, why])
	t_leg = 0.0
	max_speed = 0.0


func _process(_d: float) -> bool:
	frames += 1
	if frames < 3:
		return false
	var v: Vessel = f.vessel
	if frames == 3:
		f.teleport_to_orbit(300_000.0)
		_check(v.cruise_block_reason(f.sim_time) == "", "cruise allowed in orbit")
		_start(v)
	for i in 60:
		f.sim_tick()
		t_leg += 1.0 / 60.0
		max_speed = maxf(max_speed, v.cruise_speed)
		if not v.cruise:
			var alt := v.altitude()
			var drop := Vessel.cruise_drop_alt(v.body)
			print("  %s: %.0f s, top speed %.0f km/s, dropped at %.0f km (drop alt %.0f km), speed %.0f m/s" % [
				LEGS[leg], t_leg, max_speed / 1000.0, alt / 1000.0, drop / 1000.0, v.vel.length()])
			_check(v.body.name == LEGS[leg], "arrived in the SOI of %s (%s)" % [LEGS[leg], v.body.name])
			_check(alt > drop * 0.8 and alt < drop * 1.5, "dropped out near the drop altitude")
			_check(t_leg < LIMIT[leg], "trip short enough (%.0f s < %.0f s)" % [t_leg, LIMIT[leg]])
			_check(not v.destroyed_flag, "ship intact")
			leg += 1
			if leg >= LEGS.size():
				# A few seconds of normal flight after the drop: no crash, sane speed.
				for k in 600:
					f.sim_tick()
				_check(not v.destroyed_flag and v.surface_velocity().length() < 1000.0,
					"flies on with flight assist (%.0f m/s)" % v.surface_velocity().length())
				print("FAILURES: %d" % fails)
				quit(0 if fails == 0 else 1)
				return true
			_start(v)
			return false
		if t_leg > LIMIT[leg] * 2.0:
			_check(false, "%s not reached in %.0f s (body %s, target dist %s)" % [LEGS[leg], t_leg, v.body.name, str(v.cruise_info.get("target_d"))])
			quit(1)
			return true
	return false
