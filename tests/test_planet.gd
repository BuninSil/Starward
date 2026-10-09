extends SceneTree
## Interplanetary autopilot on the real flight scene, headless:
## lunar rocket in a Baikonur-like 20 km Earth orbit -> Mars orbit -> back to Earth.
## godot --headless --path . --script tests/test_planet.gd

var f: Node
var frames := 0
var stage := 0
var done := false
var ok := false
var t0 := 0
var fails := 0


func _initialize() -> void:
	Vessel.design = "moon"
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
		f.vessel.infinite_fuel = OS.get_cmdline_user_args().has("inf")
		f.start_mission(Autopilot.tasks_orbit(20_000.0))
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
	if not done and Time.get_ticks_msec() - t0 < 900000:
		return false
	var v = f.vessel
	var mars := SolarSystem.find(f.root_body, "mars")
	match stage:
		0:
			_check(ok, "Earth orbit")
			stage = 1
			done = false
			f.start_mission(Autopilot.tasks_planet(mars, f.default_orbit_altitude(mars)))
			t0 = Time.get_ticks_msec()
			return false
		1:
			var el := OrbitMath.elements(v.pos, v.vel, v.body.mu)
			_check(ok and v.body == mars and el.e < 0.2, "orbit around Mars (%.0f x %.0f km, t=%.0f d, dV left %.0f)" % [
				(el.apoapsis - mars.radius) / 1000.0, (el.periapsis - mars.radius) / 1000.0, f.sim_time / 86400.0, v.total_delta_v()])
			if fails > 0:
				quit(1)
				return true
			stage = 2
			done = false
			f.start_mission(Autopilot.tasks_planet_home(f.home))
			t0 = Time.get_ticks_msec()
			return false
	_check(ok and v.landed and v.body == f.home, "back on Earth (touchdown %.1f m/s, t=%.0f d)" % [v.touchdown_speed, f.sim_time / 86400.0])
	print("PLANET %s" % ("PASS" if fails == 0 else "FAIL"))
	quit(0 if fails == 0 else 1)
	return true
