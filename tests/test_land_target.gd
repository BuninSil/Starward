extends SceneTree
## Precision landing on a point (a base's landing pad) from a Moon orbit: plane
## turn, deorbit timed to the site, guided powered descent.
## godot --headless --path . --script tests/test_land_target.gd [dlat_deg]

var f: Node
var frames := 0
var done := false
var ok := false
var t0 := 0
var fails := 0
var tlat := 0.0
var tlon := 0.0
var descent: ApDescent


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
		var moon: CelestialBody = f.vessel.body
		var dlat := float(OS.get_cmdline_user_args()[0]) if OS.get_cmdline_user_args().size() > 0 else 1.5
		# A sunlit point a quarter orbit ahead of the ground track, off it by dlat.
		var st := OrbitMath.propagate(f.vessel.pos, f.vessel.vel, moon.mu, 1500.0)
		var ll := CelestialBody.lat_lon(moon.inertial_to_fixed(st[0], f.sim_time + 1500.0))
		tlat = ll.x + dlat
		tlon = ll.y
		print("target %.3f, %.3f (track at %.3f), module dV %.0f" % [tlat, tlon, ll.x, f.vessel.total_delta_v()])
		var tasks := Autopilot.tasks_land_at(tlat, tlon, "тест")
		descent = tasks[2]
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
	if not done and Time.get_ticks_msec() - t0 < 400000:
		return false
	var v = f.vessel
	_check(ok and v.landed and not v.destroyed_flag, "landed (touchdown %.1f m/s)" % v.touchdown_speed)
	_check(descent.miss < 30.0, "on target: %.1f m away" % descent.miss)
	print("dV left %.0f m/s" % v.total_delta_v())
	print("FAILURES: %d" % fails)
	quit(0 if fails == 0 else 1)
	return true
