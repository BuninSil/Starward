extends SceneTree
## Full autopilot mission on the real flight scene, headless:
## pad -> orbit -> Moon orbit -> return -> parachute landing.
## godot --headless --path . --script tests/test_mission.gd

var f: Node
var frames := 0
var done := false
var ok := false
var t0 := 0


func _initialize() -> void:
	f = load("res://scenes/flight.tscn").instantiate()
	root.add_child(f)
	f.autopilot.finished.connect(func(success: bool, msg: String) -> void:
		print("FINISHED ok=%s %s" % [success, msg])
		ok = success
		done = true)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 3:
		var tasks: Array = Autopilot.tasks_orbit(20000.0) + Autopilot.tasks_moon(f.root_body, 30000.0) + Autopilot.tasks_home()
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
		if f.vessel.destroyed_flag:
			print("DESTROYED")
			done = true
	if done or Time.get_ticks_msec() - t0 > 400000:
		var v = f.vessel
		var landed_ok: bool = ok and v.landed and v.body == f.root_body and not v.destroyed_flag
		print("MISSION %s: t=%.2f d, landed=%s, touchdown %.1f m/s, wall %d s" % [
			"PASS" if landed_ok else "FAIL", f.sim_time / 86400.0, v.landed, v.touchdown_speed,
			(Time.get_ticks_msec() - t0) / 1000])
		quit(0 if landed_ok else 1)
		return true
	return false
