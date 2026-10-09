extends SceneTree
## Lunar module from a 30 km Moon orbit: powered landing, liftoff, return to Earth.
## godot --headless --path . --script tests/test_moon_landing.gd

var f: Node
var frames := 0
var stage := 0      # 0 landing, 1 ascent + home
var done := false
var ok := false
var t0 := 0
var fails := 0


func _initialize() -> void:
	f = load("res://scenes/flight.tscn").instantiate()
	root.add_child(f)
	f.autopilot.finished.connect(func(success: bool, msg: String) -> void:
		print("FINISHED ok=%s %s" % [success, msg])
		ok = success
		done = true)


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		fails += 1


func _process(_d: float) -> bool:
	frames += 1
	if frames == 3:
		f.teleport_lunar_module_to_orbit(30_000.0)
		print("module dV %.0f m/s" % f.vessel.total_delta_v())
		f.start_mission(Autopilot.tasks_moon_land())
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
	if not done and Time.get_ticks_msec() - t0 < 400000:
		return false
	var v = f.vessel
	if stage == 0:
		var moon := SolarSystem.find(f.root_body, "Луна")
		_check(ok and v.landed and v.body == moon and not v.destroyed_flag, "landed on the Moon (touchdown %.1f m/s)" % v.touchdown_speed)
		var n: DVec3 = v.pos.normalized()
		var sd := SolarSystem.sun_dir(moon, f.sim_time)
		_check(n.to_v3().dot(sd) > 0.15, "landing site in daylight (sun elev %.0f°)" % rad_to_deg(asin(n.to_v3().dot(sd))))
		print("dV left %.0f m/s, stages %d" % [v.total_delta_v(), v.stages.size()])
		if fails > 0:
			quit(1)
			return true
		stage = 1
		done = false
		ok = false
		f.start_mission(Autopilot.tasks_moon_ascent(20_000.0, SolarSystem.find(f.root_body, "moon"), f.sim_time) + Autopilot.tasks_home())
		t0 = Time.get_ticks_msec()
		return false
	_check(ok and v.landed and v.body == f.home and not v.destroyed_flag, "back on Earth (touchdown %.1f m/s)" % v.touchdown_speed)
	print("MOON LANDING %s: t=%.2f d" % ["PASS" if fails == 0 else "FAIL", f.sim_time / 86400.0])
	quit(0 if fails == 0 else 1)
	return true
