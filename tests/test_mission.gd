extends SceneTree
## Full autopilot mission on the real flight scene, headless:
## lunar rocket: pad -> orbit -> Moon orbit -> powered landing -> liftoff ->
## return -> parachute landing.
## godot --headless --path . --script tests/test_mission.gd

var f: Node
var frames := 0
var done := false
var ok := false
var t0 := 0
var moon_reported := false


func _initialize() -> void:
	Vessel.design = "moon"
	f = load("res://scenes/flight.tscn").instantiate()
	root.add_child(f)
	f.autopilot.finished.connect(func(success: bool, msg: String) -> void:
		print("FINISHED ok=%s %s" % [success, msg])
		ok = success
		done = true)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 3:
		var tasks: Array = Autopilot.tasks_orbit(20000.0) + Autopilot.tasks_moon(f.root_body, 30000.0) \
			+ Autopilot.tasks_moon_land() + Autopilot.tasks_moon_ascent(20000.0) + Autopilot.tasks_home()
		f.start_mission(tasks)
		t0 = Time.get_ticks_msec()
	if frames < 3:
		return false
	var budget := Time.get_ticks_msec() + 50
	while Time.get_ticks_msec() < budget and not done:
		var cur = f.autopilot.current
		if cur is ApPlan and cur._task_id >= 0:
			OS.delay_msec(2)
		f.sim_tick()
		if f.vessel.landed and f.vessel.body.name == "Луна" and not moon_reported:
			moon_reported = true
			print("ON THE MOON: t=%.2f d, touchdown %.1f m/s, dV left %.0f" % [f.sim_time / 86400.0, f.vessel.touchdown_speed, f.vessel.total_delta_v()])
		if f.vessel.destroyed_flag:
			print("DESTROYED")
			done = true
	if done or Time.get_ticks_msec() - t0 > 600000:
		var v = f.vessel
		var landed_ok: bool = ok and moon_reported and v.landed and v.body == f.home and not v.destroyed_flag
		print("MISSION %s: t=%.2f d, landed=%s, touchdown %.1f m/s, wall %d s" % [
			"PASS" if landed_ok else "FAIL", f.sim_time / 86400.0, v.landed, v.touchdown_speed,
			(Time.get_ticks_msec() - t0) / 1000])
		quit(0 if landed_ok else 1)
		return true
	return false
