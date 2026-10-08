extends SceneTree
## Headless sim tests: godot --headless --path . --script tests/test_sim.gd
## (tests/ has .gdignore so it is never exported.)

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failures += 1
		print("  FAIL ", msg)


func _initialize() -> void:
	var earth := SolarSystem.earth()
	print("Earth R=%.0f mu=%.0f g=%.3f" % [earth.radius, earth.mu, earth.surface_gravity()])

	# 1. Circular orbit elements
	var r := earth.radius + 20_000.0
	var vc := sqrt(earth.mu / r)
	var p0 := DVec3.new(r, 0, 0)
	var v0 := DVec3.new(0, 0, -vc)
	var el := OrbitMath.elements(p0, v0, earth.mu)
	print("circular v=%.1f m/s period=%.1f min" % [vc, el.period / 60.0])
	check(absf(el.e) < 1e-9, "circular e ~ 0")
	check(absf(el.apoapsis - r) < 1.0 and absf(el.periapsis - r) < 1.0, "apo/peri = r")

	# 2. Kepler propagation over one period returns to start
	var ell_v := DVec3.new(0, 300, -vc * 1.1)
	var el2 := OrbitMath.elements(p0, ell_v, earth.mu)
	var rv := OrbitMath.propagate(p0, ell_v, earth.mu, el2.period)
	check((rv[0] as DVec3).sub(p0).length() < 1.0, "Kepler full period closes (err %.4f m)" % (rv[0] as DVec3).sub(p0).length())
	var rv_half := OrbitMath.propagate(p0, ell_v, earth.mu, el2.period * 0.5)
	check(absf((rv_half[0] as DVec3).length() - el2.apoapsis) < 1.0, "half period reaches apoapsis")
	# hyperbolic
	var hyp_v := DVec3.new(0, 0, -vc * 1.6)
	var rvh := OrbitMath.propagate(p0, hyp_v, earth.mu, 3000.0)
	var eh0: float = OrbitMath.elements(p0, hyp_v, earth.mu).energy
	var eh1: float = OrbitMath.elements(rvh[0], rvh[1], earth.mu).energy
	check(absf(eh1 - eh0) / absf(eh0) < 1e-8, "hyperbolic energy conserved")

	# 3. Numerical integrator vs Kepler over one orbit (vacuum, dt = 1/60)
	var ves := Vessel.default_rocket(earth)
	ves.landed = false
	ves.pos = p0.copy()
	ves.vel = ell_v.copy()
	ves.body = earth
	var dt := 1.0 / 60.0
	var n := int(el2.period / dt)
	var t := 0.0
	for i in n:
		ves.step(dt, t)
		t += dt
	var kep := OrbitMath.propagate(p0, ell_v, earth.mu, n * dt)
	var err := ves.pos.sub(kep[0]).length()
	print("integrator vs Kepler after one orbit: %.2f m" % err)
	check(err < 200.0, "Verlet error after 1 orbit < 200 m")

	# 4. Ascent with a simple gravity-turn autopilot reaches orbit
	var rk := Vessel.default_rocket(earth)
	rk.place_on_surface(SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON, 0.0)
	print("rocket mass %.0f kg, TWR %.2f, dV %.0f m/s" % [rk.mass(), rk.twr(), rk.total_delta_v()])
	check(rk.twr() > 1.2, "liftoff TWR > 1.2")
	rk.throttle = 1.0
	rk.sas = true
	t = 0.0
	var max_t := 1200.0
	var staged := 0
	var done := false
	var circ := false
	while t < max_t and not rk.destroyed_flag:
		var alt := rk.altitude()
		var up := rk.pos.normalized().to_v3()
		var east := Vector3.UP.cross(up).normalized()
		var el3 := OrbitMath.elements(rk.pos, rk.vel, earth.mu)
		var pitch := clampf(alt / 9000.0, 0.0, 1.0) * deg_to_rad(80.0)
		var target := (up * cos(pitch) + east * sin(pitch)).normalized()
		if not circ and el3.apoapsis - earth.radius > 25_000.0:
			rk.throttle = 0.0
			if alt > 23_000.0:
				circ = true
		if circ:
			target = (up * 0.0 + rk.vel.normalized().to_v3()).normalized()
			rk.throttle = 1.0
			if el3.periapsis - earth.radius > 15_000.0:
				done = true
				break
		# crude steering: snap attitude toward target (autopilot test only)
		rk.attitude = Quaternion(Vector3.UP, target).normalized()
		rk.ang_vel = Vector3.ZERO
		if not rk.has_fuel() and rk.stages.size() > 1:
			rk.stage()
			staged += 1
		rk.step(dt, t)
		t += dt
	var fin := OrbitMath.elements(rk.pos, rk.vel, earth.mu)
	print("ascent: t=%.0fs staged=%d apo=%.1f km peri=%.1f km dv left=%.0f" % [t, staged,
		(fin.apoapsis - earth.radius) / 1000.0, (fin.periapsis - earth.radius) / 1000.0, rk.total_delta_v()])
	check(done, "reached orbit with periapsis > 15 km")

	# 5. Autopilot flies the real controls to a 20 km orbit
	var ap_r := Vessel.default_rocket(earth)
	ap_r.place_on_surface(SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON, 0.0)
	var ap := Autopilot.new()
	ap.engage(ap_r, 20_000.0)
	var res := []
	ap.finished.connect(func(ok: bool, msg: String) -> void: res.append([ok, msg]))
	t = 0.0
	var phases := {}
	while t < 1500.0 and res.is_empty():
		ap.update(ap_r)
		phases[ap.status()] = phases.get(ap.status(), 0.0) + dt
		ap_r.step(dt, t)
		t += dt
	var fe := OrbitMath.elements(ap_r.pos, ap_r.vel, earth.mu)
	print("autopilot: t=%.0fs %s apo=%.1f peri=%.1f dv left=%.0f phases=%s" % [t, str(res),
		(fe.apoapsis - earth.radius) / 1000.0, (fe.periapsis - earth.radius) / 1000.0, ap_r.total_delta_v(), str(phases)])
	check(not res.is_empty() and res[0][0], "autopilot reached orbit")
	check(fe.periapsis - earth.radius > earth.atmosphere_height, "autopilot periapsis above atmosphere")

	print("FAILURES: %d" % failures)
	quit(1 if failures > 0 else 0)
