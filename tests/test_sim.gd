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
	var res := []
	ap.finished.connect(func(ok: bool, msg: String) -> void: res.append([ok, msg]))
	ap.start_chain(Autopilot.tasks_orbit(20_000.0), ap_r, 0.0)
	t = 0.0
	var phases := {}
	while t < 1500.0 and res.is_empty():
		ap.update(ap_r, t)
		phases[ap.status()] = phases.get(ap.status(), 0.0) + dt
		ap_r.step(dt, t)
		t += dt
	var fe := OrbitMath.elements(ap_r.pos, ap_r.vel, earth.mu)
	print("autopilot: t=%.0fs %s apo=%.1f peri=%.1f dv left=%.0f phases=%s" % [t, str(res),
		(fe.apoapsis - earth.radius) / 1000.0, (fe.periapsis - earth.radius) / 1000.0, ap_r.total_delta_v(), str(phases)])
	check(not res.is_empty() and res[0][0], "autopilot reached orbit")
	check(fe.periapsis - earth.radius > earth.atmosphere_height, "autopilot periapsis above atmosphere")

	# 6. Moon: elements round trip, SOI size, period
	var root := SolarSystem.build()
	var moon := SolarSystem.find(root, "Луна")
	var mst: Array = moon.state_at(12345.0)
	var mel := OrbitMath.elements(mst[0], mst[1], root.mu)
	print("moon: a=%.0f km e=%.4f inc=%.2f deg period=%.2f d soi=%.0f km" % [mel.a / 1000.0, mel.e,
		rad_to_deg(mel.inc), moon.orbital_period() / 86400.0, moon.soi_radius / 1000.0])
	check(absf(mel.a - moon.orbit_a) < 1.0 and absf(mel.e - moon.orbit_e) < 1e-6, "moon elements round trip")
	check(absf(rad_to_deg(mel.inc) - 28.58) < 1e-6, "moon inclination")
	var mst2: Array = moon.state_at(moon.orbital_period() + 12345.0)
	check((mst2[0] as DVec3).sub(mst[0]).length() < 10.0, "moon orbit periodic")
	var kp := OrbitMath.propagate(mst[0], mst[1], root.mu, 50000.0)
	var mst3: Array = moon.state_at(12345.0 + 50000.0)
	check((kp[0] as DVec3).sub(mst3[0]).length() < 50.0, "moon ephemeris == Kepler")

	# 7. SOI transitions keep the absolute state continuous
	var sv := Vessel.default_rocket(root)
	sv.landed = false
	var t_enc := 200000.0
	var mpos: DVec3 = moon.state_at(t_enc)[0]
	var mvel: DVec3 = moon.state_at(t_enc)[1]
	sv.pos = mpos.add(mpos.normalized().mul(-moon.soi_radius - 20_000.0))
	sv.vel = mvel.add(mpos.normalized().mul(800.0))
	var abs0 := sv.pos.copy()
	var v_abs0 := sv.vel.copy()
	var changed := []
	sv.soi_changed.connect(func(_a, b): changed.append(b.name))
	sv.rails_step(200.0, t_enc)
	print("soi changes: ", changed, " now in ", sv.body.name, " r=", sv.pos.length() / 1000.0, " km")
	check(changed == ["Луна"], "entered Moon SOI")
	var abs1 := sv.pos.add(moon.state_at(t_enc + 200.0)[0])
	var kep_abs := OrbitMath.propagate(abs0, v_abs0, root.mu, 200.0)
	print("abs position diff vs earth-only propagation: %.2f km" % (abs1.sub(kep_abs[0]).length() / 1000.0))
	check(abs1.sub(kep_abs[0]).length() < 5000.0, "absolute position continuous across SOI")
	sv.pos = sv.pos.normalized().mul(moon.soi_radius + 1000.0)
	sv.vel = sv.pos.normalized().mul(500.0)
	sv.rails_step(10.0, t_enc + 200.0)
	check(sv.body == root, "left Moon SOI back to Earth")

	# 8. Trajectory prediction finds a Moon encounter on a Hohmann transfer
	var r1 := root.radius + 20_000.0
	var tof := 0.0
	var m_hat := DVec3.new()
	var r_m := moon.orbit_a
	for _k in 5:
		var a_t := (r1 + r_m) * 0.5
		tof = PI * sqrt(a_t * a_t * a_t / root.mu)
		var mp: DVec3 = moon.state_at(tof)[0]
		m_hat = mp.normalized()
		r_m = mp.length()
	var h_m := (moon.state_at(0.0)[0] as DVec3).cross(moon.state_at(0.0)[1]).normalized()
	var p_ship := m_hat.mul(-r1)
	var v_dir := h_m.cross(p_ship.normalized())
	var a_tr := (r1 + r_m) * 0.5
	var v_peri := sqrt(root.mu * (2.0 / r1 - 1.0 / a_tr))
	var t_start := Time.get_ticks_msec()
	var segs := Trajectory.predict(p_ship, v_dir.mul(v_peri), root, 0.0)
	var ms := Time.get_ticks_msec() - t_start
	var names := []
	for sg in segs:
		names.append("%s:%s" % [sg.body.name, sg.end])
	print("transfer tof=%.2f d, segments=%s, predict %d ms" % [tof / 86400.0, str(names), ms])
	var enc := Trajectory.find_encounter(segs, moon)
	check(not enc.is_empty(), "prediction enters Moon SOI")
	if not enc.is_empty():
		print("moon periapsis: %.0f km (r=%.0f km)" % [(enc.el.periapsis - moon.radius) / 1000.0, enc.el.periapsis / 1000.0])

	# 9. Planner: full Moon mission on rails with impulsive burns
	var t9 := 1000.0
	var rr := DVec3.new(root.radius + 20_000.0, 0, 0).rotated_y(0.3)
	var vv := DVec3.new(0, 1, 0).cross(rr).normalized().mul(sqrt(root.mu / rr.length()))
	var t_c := Time.get_ticks_msec()
	var plan := Planner.plan_transfer(rr, vv, root, t9, moon, 30_000.0)
	print("transfer plan in %d ms: %s" % [Time.get_ticks_msec() - t_c, str(plan.keys())])
	check(not plan.is_empty(), "found a Moon transfer window")
	if not plan.is_empty():
		var nd: ManeuverNode = plan.node
		print("  burn in %.1f h, dv=%.1f pro %.1f nor, moon peri %.1f km, arrive in %.2f d" % [
			(nd.t - t9) / 3600.0, nd.prograde, nd.normal, plan.peri_alt / 1000.0, (plan.t_arrive - t9) / 86400.0])
		check(absf(plan.peri_alt - 30_000.0) < 3000.0, "transfer periapsis near 30 km")
		# Fly it: propagate to the node, apply dv, rails to the Moon.
		var mv := Vessel.default_rocket(root)
		mv.landed = false
		mv.pos = rr.copy()
		mv.vel = vv.copy()
		mv.rails_step(nd.t - t9, t9)
		var dvw := ManeuverNode.dv_vector(mv.pos, mv.vel, nd.prograde, nd.normal, nd.radial)
		mv.vel = mv.vel.add(dvw)
		mv.rails_step(plan.t_arrive - nd.t + 60.0, nd.t)
		check(mv.body == moon, "arrived in Moon SOI")
		var t_now: float = plan.t_arrive + 60.0
		var cap := Planner.circularize(mv.pos, mv.vel, moon, t_now, "peri")
		print("  capture dv=%.1f at peri alt %.1f km" % [cap.prograde, (OrbitMath.elements(mv.pos, mv.vel, moon.mu).periapsis - moon.radius) / 1000.0])
		mv.rails_step(cap.t - t_now, t_now)
		mv.vel = mv.vel.add(ManeuverNode.dv_vector(mv.pos, mv.vel, cap.prograde, 0, 0))
		t_now = cap.t
		var mel2 := OrbitMath.elements(mv.pos, mv.vel, moon.mu)
		print("  moon orbit: apo %.1f peri %.1f km" % [(mel2.apoapsis - moon.radius) / 1000.0, (mel2.periapsis - moon.radius) / 1000.0])
		check(mel2.e < 0.01, "circular lunar orbit after capture")
		t_c = Time.get_ticks_msec()
		var ret := Planner.plan_return(mv.pos, mv.vel, moon, t_now, 4000.0)
		print("  return plan in %d ms: dv=%.1f earth peri %.1f km" % [Time.get_ticks_msec() - t_c,
			ret.node.prograde if not ret.is_empty() else 0.0, ret.peri_alt / 1000.0 if not ret.is_empty() else 0.0])
		check(not ret.is_empty() and absf(ret.peri_alt - 4000.0) < 1500.0, "return periapsis near 4 km")
		var total_dv: float = nd.total() + absf(cap.prograde) + (ret.node.prograde if not ret.is_empty() else 0.0)
		print("  mission dv from LEO: %.0f m/s" % total_dv)

	print("FAILURES: %d" % failures)
	quit(1 if failures > 0 else 0)
