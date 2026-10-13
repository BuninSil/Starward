extends SceneTree
## Damage by module and aerodynamics, headless on the real flight scene.
## godot --headless --path . --script tests/test_damage.gd

var f: Node
var frames := 0
var fails := 0
var lost: Array = []


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1


func _new_flight(design: String) -> void:
	if f:
		f.queue_free()
	Vessel.design = design
	f = load("res://scenes/flight.tscn").instantiate()
	root.add_child(f)
	lost.clear()


func _hook() -> void:
	f.vessel.wrecked.connect(func(s: Dictionary, why: String) -> void:
		lost.append(s.name)
		print("     wrecked: ", why))


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		_new_flight("moon")
		return false
	if frames != 3:
		return false
	# 1. Lander hits the Moon at 17 m/s upright: legs stage crumples, crew lives.
	f.teleport_lunar_module_to_orbit(30_000.0)
	var moon = SolarSystem.find(f.root_body, "moon")
	f.teleport_to_surface(moon, 0.0, 10.0)
	_hook()
	var v: Vessel = f.vessel
	v.landed = false
	v.pos = v.pos.add(v.pos.normalized().mul(2.0))
	v.vel = v.vel.add(v.pos.normalized().mul(-17.0))
	for k in 120:
		f.sim_tick()
	_check(not v.destroyed_flag, "lander at 17 m/s: crew survives")
	_check(lost.has("Посадочная ступень") and v.stages.size() == 2, "lander at 17 m/s: descent stage wrecked (%s)" % [lost])
	# 2. Same at 40 m/s: capsule lost.
	f.reset_to_pad()
	f.teleport_lunar_module_to_orbit(30_000.0)
	f.teleport_to_surface(moon, 0.0, 10.0)
	_hook()
	v = f.vessel
	v.landed = false
	v.pos = v.pos.add(v.pos.normalized().mul(2.0))
	v.vel = v.vel.add(v.pos.normalized().mul(-40.0))
	for k in 120:
		f.sim_tick()
	_check(v.destroyed_flag, "lander at 40 m/s: capsule destroyed")
	# 3. Rocket flown broadside through thick air breaks up, capsule survives.
	f.reset_to_pad()
	_hook()
	v = f.vessel
	v.landed = false
	v.pos = v.pos.add(v.pos.normalized().mul(800.0))
	var up: Vector3 = v.pos.normalized().to_v3()
	var east := Vector3.UP.cross(up).normalized()
	v.vel = f.home.fixed_to_inertial(DVec3.new(), 0.0).add(DVec3.new(0, f.home.angular_velocity(), 0).cross(v.pos)).add(DVec3.from_v3(up * 250.0))
	v.attitude = Quaternion(Vector3.UP, east)   # nose sideways, flying up at 300 m/s
	v.ang_vel = Vector3.ZERO
	for k in 30:
		f.sim_tick()
	_check(not v.destroyed_flag and v.stages.size() == 1, "broadside at 250 m/s: stack breaks up, capsule left (%d stages)" % v.stages.size())
	# 4. Aero stability: a rocket at 20 deg AoA in air turns into the flow by itself.
	f.reset_to_pad()
	v = f.vessel
	v.landed = false
	v.pos = v.pos.add(v.pos.normalized().mul(600.0))
	up = v.pos.normalized().to_v3()
	east = Vector3.UP.cross(up).normalized()
	v.vel = DVec3.new(0, f.home.angular_velocity(), 0).cross(v.pos).add(DVec3.from_v3(up * 120.0))
	v.attitude = Quaternion(up.cross(east).normalized(), deg_to_rad(20.0)) * Quaternion(Vector3.UP, up)
	v.sas = false
	v.hold_mode = ""
	var a0 := rad_to_deg(v.up_world().angle_to(v.surface_velocity().to_v3().normalized()))
	for k in 240:
		f.sim_tick()
	var a1 := rad_to_deg(v.up_world().angle_to(v.surface_velocity().to_v3().normalized()))
	_check(a1 < a0 * 0.5 and not v.destroyed_flag, "finned rocket weathervanes into the flow (%.1f -> %.1f deg)" % [a0, a1])
	# 5. Lone capsule entering nose-first flips heat shield forward and survives.
	f.reset_to_pad()
	v = f.vessel
	while v.stages.size() > 1:
		v.stages.pop_back()
	f.rocket.build(v)
	f.teleport_to_orbit(60_000.0)
	v.vel = v.vel.mul(0.97)
	v.attitude = Quaternion(Vector3.UP, v.vel.normalized().to_v3())   # nose forward
	v.sas = false
	v.hold_mode = ""
	var steps := 0
	while not v.landed and not v.destroyed_flag and steps < 200000:
		f.sim_tick()
		steps += 1
		if v.altitude() < 3000.0 and not v.chute_deployed:
			v.deploy_chute()
	_check(v.landed and not v.destroyed_flag, "capsule entering nose-first self-rights and lands (heat lead '%s')" % v.heat_lead)
	print("FAILURES: %d" % fails)
	quit(1 if fails > 0 else 0)
	return true
