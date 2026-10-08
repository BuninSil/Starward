extends Node3D
## Flight scene controller: owns simulation time, time warp, the active vessel,
## floating origin (vessel always at the scene origin), cameras and map mode.

const PlanetView := preload("res://scripts/flight/planet_view.gd")
const RocketView := preload("res://scripts/flight/rocket_view.gd")
const TrajectoryView := preload("res://scripts/flight/trajectory_view.gd")
const HudScript := preload("res://scripts/flight/flight_hud.gd")
const SKY_SHADER := preload("res://shaders/starfield.gdshader")
const AstronautScript := preload("res://scripts/eva/astronaut.gd")
const TetherScript := preload("res://scripts/eva/tether.gd")
const EvaHudScript := preload("res://scripts/eva/eva_hud.gd")

const DT := 1.0 / 60.0
const WARPS: Array[int] = [1, 2, 4, 10, 50, 100, 1000, 10000]
const PHYSICS_WARP_MAX := 4
const SUN_DIR := Vector3(0.62, 0.35, 0.7)   ## towards the sun, inertial

signal message(text: String)

var root_body: CelestialBody
var bodies: Array[CelestialBody] = []
## Current reference body (the vessel's SOI).
var body: CelestialBody:
	get:
		return vessel.body if vessel != null else root_body
var vessel: Vessel
var sim_time := 0.0
var warp_index := 0
var map_mode := false

var planets := {}          ## CelestialBody -> PlanetView
var rocket: Node3D
var traj_view: Node3D
var map_focus: CelestialBody
var trajectory: Array[Dictionary] = []
var _traj_timer := 0.0
var hud: CanvasLayer
var camera: Camera3D
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ShaderMaterial

# Flight camera, relative to the vessel attitude.
var cam_yaw := 0.35
var cam_pitch := 0.15
var cam_dist := 40.0
# Map camera, inertial, around the planet.
var map_yaw := 0.0
var map_pitch := 0.5
var map_dist := 2_500_000.0

var autopilot := Autopilot.new()
# EVA
var eva_mode := false
var astronaut: RigidBody3D = null
var tether: Node3D = null
var eva_hud: CanvasLayer = null
var eva_cam_dist := 5.0
var _ship_kick := 0.0
var maneuver: ManeuverNode = null
var preview: Array[Dictionary] = []
var maneuver_info := ""
var _last_ap_warp := -1
var _debris: Array[Dictionary] = []
var _touches := {}
var _pinch_start := 0.0
var _pinch_dist0 := 0.0


func _ready() -> void:
	root_body = SolarSystem.build()
	_collect_bodies(root_body)
	_set_morning_at_site()
	_build_environment()
	for b in bodies:
		var pv := PlanetView.new()
		add_child(pv)
		pv.setup(b, b == root_body, SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON, SUN_DIR.normalized())
		planets[b] = pv
	rocket = RocketView.new()
	add_child(rocket)
	traj_view = TrajectoryView.new()
	add_child(traj_view)
	traj_view.setup(root_body)
	map_focus = root_body
	camera = Camera3D.new()
	camera.near = 0.3
	camera.far = 3.0e7
	camera.fov = 60.0
	add_child(camera)
	camera.make_current()
	autopilot.finished.connect(_on_autopilot_finished)
	autopilot.task_changed.connect(func(title: String) -> void: message.emit("Автопилот: " + title))
	hud = HudScript.new()
	hud.flight = self
	add_child(hud)
	reset_to_pad()
	Log.info("Flight: scene ready, bodies=%d, body=%s R=%.0f m g=%.2f" % [bodies.size(), body.name, body.radius, body.surface_gravity()])


func _collect_bodies(b: CelestialBody) -> void:
	bodies.append(b)
	for c in b.children:
		_collect_bodies(c)


## Picks the planet spin offset so the launch site has the sun ~35° high, rising, at t = 0.
func _set_morning_at_site() -> void:
	var n := CelestialBody.surface_normal(SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON)
	var sdir := DVec3.from_v3(SUN_DIR.normalized())
	var best := 0.0
	var best_err := INF
	for i in 720:
		var a := TAU * i / 720.0
		var e0 := n.rotated_y(a).dot(sdir)
		var e1 := n.rotated_y(a + 0.01).dot(sdir)
		var err := absf(e0 - sin(deg_to_rad(35.0)))
		if e1 > e0 and err < best_err:
			best_err = err
			best = a
	root_body.rotation_offset = best


func _build_environment() -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.06, 0.07, 0.1)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.5
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.light_energy = 1.5
	sun.shadow_enabled = false
	add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -SUN_DIR, Vector3.UP if absf(SUN_DIR.normalized().y) < 0.99 else Vector3.RIGHT)


# --- Vessel lifecycle -------------------------------------------------------------

func reset_to_pad() -> void:
	abort_eva()
	for d in _debris:
		d.node.queue_free()
	_debris.clear()
	if vessel:
		autopilot.disengage(vessel)
	var inf_fuel := vessel.infinite_fuel if vessel else false
	vessel = Vessel.default_rocket(root_body)
	vessel.infinite_fuel = inf_fuel
	vessel.staged.connect(_on_staged)
	vessel.destroyed.connect(_on_destroyed)
	vessel.soi_changed.connect(_on_soi_changed)
	vessel.place_on_surface(SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON, sim_time)
	# Roll so local +X points east and +Z south: joystick right = nose east.
	var up := vessel.pos.normalized().to_v3()
	var east := Vector3.UP.cross(up).normalized()
	var south := east.cross(up)
	vessel.attitude = Basis(east, up, south).get_rotation_quaternion()
	rocket.build(vessel)
	set_warp(0)
	cam_yaw = 0.35
	cam_pitch = 0.12
	cam_dist = 40.0
	hud.on_vessel_reset()
	Log.info("Flight: vessel on pad, mass %.0f kg, dV %.0f m/s, TWR %.2f" % [vessel.mass(), vessel.total_delta_v(), vessel.twr()])


## Debug: circular orbit at the given altitude (prograde, equatorial-ish over the site).
func teleport_to_orbit(altitude: float) -> void:
	autopilot.disengage(vessel)
	var r := body.radius + altitude
	var radial := vessel.pos.normalized()
	if radial.length() < 0.5:
		radial = DVec3.new(1, 0, 0)
	var east := DVec3.new(0, 1, 0).cross(radial).normalized()
	vessel.pos = radial.mul(r)
	vessel.vel = east.mul(sqrt(body.mu / r))
	vessel.landed = false
	vessel.destroyed_flag = false
	vessel.throttle = 0.0
	vessel.ang_vel = Vector3.ZERO
	vessel.attitude = Quaternion(Vector3.UP, east.to_v3()).normalized()
	set_warp(0)
	hud.on_vessel_reset()
	Log.info("Flight: teleported to circular orbit %.0f m" % altitude)


## Debug: circular orbit around another body (e.g. the Moon).
func teleport_to_body_orbit(target: CelestialBody, altitude: float) -> void:
	autopilot.disengage(vessel)
	var r := target.radius + altitude
	var radial := DVec3.new(1, 0, 0)
	var east := DVec3.new(0, 1, 0).cross(radial).normalized()
	vessel.body = target
	vessel.pos = radial.mul(r)
	vessel.vel = east.mul(sqrt(target.mu / r))
	_after_teleport("орбита %s %.0f км" % [target.name, altitude / 1000.0])


## Debug: on a Hohmann transfer from a 20 km orbit that hits the Moon's SOI.
func teleport_to_moon_transfer() -> void:
	autopilot.disengage(vessel)
	var moon := SolarSystem.find(root_body, "Луна")
	var r1 := root_body.radius + 20_000.0
	var r_m := moon.orbit_a
	var tof := 0.0
	var m_hat := DVec3.new()
	for _k in 5:
		var a_t := (r1 + r_m) * 0.5
		tof = PI * sqrt(a_t * a_t * a_t / root_body.mu)
		var mp: DVec3 = moon.state_at(sim_time + tof)[0]
		m_hat = mp.normalized()
		r_m = mp.length()
	var st: Array = moon.state_at(sim_time)
	var h_m := (st[0] as DVec3).cross(st[1]).normalized()
	# Aim slightly off-centre so the pass misses the surface (~periapsis 50-100 km).
	var p_ship := m_hat.mul(-r1)
	var v_dir := h_m.cross(p_ship.normalized())
	var a_tr := (r1 + r_m - 2.0 * moon.radius) * 0.5
	vessel.body = root_body
	vessel.pos = p_ship
	vessel.vel = v_dir.mul(sqrt(root_body.mu * (2.0 / r1 - 1.0 / a_tr)))
	_after_teleport("перелёт к Луне")


func _after_teleport(what: String) -> void:
	abort_eva()
	vessel.landed = false
	vessel.destroyed_flag = false
	vessel.throttle = 0.0
	vessel.ang_vel = Vector3.ZERO
	vessel.attitude = Quaternion(Vector3.UP, vessel.vel.normalized().to_v3()).normalized()
	set_warp(0)
	rocket.visible = not map_mode
	hud.on_vessel_reset()
	_traj_timer = 0.0
	Log.info("Flight: teleported: " + what)


func _exit_tree() -> void:
	# Break parent <-> children reference cycles of the body tree.
	for b in bodies:
		b.children.clear()
		b.parent = null


func _on_staged(_dropped: Dictionary) -> void:
	var node: Node3D = rocket.detach_bottom_stage()
	if node == null:
		return
	add_child(node)
	node.top_level = true
	node.global_transform = node.get_meta("global")
	_debris.append({
		"node": node,
		"pos": vessel.pos.add(DVec3.from_v3(node.global_position)),
		"vel": vessel.vel.sub(DVec3.from_v3(vessel.up_world() * Vessel.STAGE_SEPARATION_DV * 2.0)),
		"basis": node.global_transform.basis,
		"body": vessel.body,
		"life": 25.0,
	})
	Log.info("Flight: stage separated, %d stage(s) left" % vessel.stages.size())


func engage_autopilot(altitude: float) -> void:
	start_mission(Autopilot.tasks_orbit(altitude))


## Runs a chain of autopilot tasks.
func start_mission(tasks: Array) -> void:
	if vessel.destroyed_flag or tasks.is_empty():
		return
	_last_ap_warp = -1
	autopilot.start_chain(tasks, vessel, sim_time)
	Log.info("Autopilot: mission started, %d task(s)" % tasks.size())


func disengage_autopilot(reason: String) -> void:
	if autopilot.active():
		autopilot.disengage(vessel)
		message.emit("Автопилот выключен: " + reason)
		Log.info("Autopilot: disengaged (%s)" % reason)


func _on_autopilot_finished(ok: bool, msg: String) -> void:
	if ok and maneuver != null and maneuver.t < sim_time:
		clear_maneuver()
	message.emit(("Автопилот: " if ok else "Автопилот не справился: ") + msg)
	Log.info("Autopilot: finished ok=%s %s" % [ok, msg])
	hud.on_autopilot_finished()


func _on_soi_changed(from: CelestialBody, to: CelestialBody) -> void:
	if maneuver != null and maneuver.body != to:
		clear_maneuver()
	Log.info("Flight: SOI %s -> %s at t=%.0f" % [from.name, to.name, sim_time])
	message.emit("Сфера влияния: %s" % to.name)
	if map_mode:
		map_focus = to
	_traj_timer = 0.0


func _on_destroyed(reason: String) -> void:
	Log.warn("Flight: vessel destroyed: " + reason)
	rocket.visible = false
	set_warp(0)
	hud.show_destroyed(reason)


# --- Time warp ----------------------------------------------------------------------

func warp() -> int:
	return WARPS[warp_index]


func is_rails() -> bool:
	return warp() > PHYSICS_WARP_MAX


func set_warp(i: int) -> void:
	i = clampi(i, 0, WARPS.size() - 1)
	if eva_mode and i > 0:
		message.emit("Во время выхода ускорение времени недоступно")
		i = 0
	if WARPS[i] > PHYSICS_WARP_MAX and not vessel.can_rails_warp():
		var why := "двигатель работает" if vessel.throttle > 0.0 else "в атмосфере"
		message.emit("Ускорение > %dx недоступно: %s" % [PHYSICS_WARP_MAX, why])
		i = WARPS.find(PHYSICS_WARP_MAX)
	warp_index = i


# --- Main loop -----------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	sim_tick()


## One fixed tick of the simulation (60 Hz). Also used by headless tests.
func sim_tick() -> void:
	if is_rails():
		autopilot.update(vessel, sim_time)
		_apply_autopilot_warp()
	if is_rails():
		if not vessel.can_rails_warp():
			set_warp(WARPS.find(PHYSICS_WARP_MAX))
		else:
			var step := DT * warp()
			vessel.rails_step(step, sim_time)
			sim_time += step
			if not vessel.landed and vessel.altitude() < body.atmosphere_height and body.has_atmosphere():
				message.emit("Вход в атмосферу — ускорение времени сброшено")
				set_warp(0)
			_step_debris(step)
			return
	if eva_mode:
		_eva_physics(DT)
	var n := warp()
	for _k in n:
		autopilot.update(vessel, sim_time)
		_apply_autopilot_warp()
		if warp() != n:
			break
		vessel.step(DT, sim_time)
		sim_time += DT
	_step_debris(DT * n)


## Autopilot drives time warp: forced 1x before burns, otherwise its request is
## applied when it changes (so the player can still change warp in between).
func _apply_autopilot_warp() -> void:
	if not autopilot.active():
		_last_ap_warp = -1
		autopilot.wants_warp_reset = false
		return
	if autopilot.wants_warp_reset:
		autopilot.wants_warp_reset = false
		_last_ap_warp = 1
		if warp() != 1:
			warp_index = 0
		return
	var req := autopilot.requested_warp
	if req == _last_ap_warp:
		return
	_last_ap_warp = req
	var idx := 0
	for i in WARPS.size():
		if WARPS[i] <= req:
			idx = i
	if WARPS[idx] > PHYSICS_WARP_MAX and not vessel.can_rails_warp():
		idx = WARPS.find(PHYSICS_WARP_MAX) if req >= PHYSICS_WARP_MAX else idx
	warp_index = idx


func _step_debris(dt: float) -> void:
	for i in range(_debris.size() - 1, -1, -1):
		var d: Dictionary = _debris[i]
		d.life -= dt
		var p: DVec3 = d.pos
		var db: CelestialBody = d.body
		var r2 := p.length_squared()
		var acc := p.mul(-db.mu / (r2 * sqrt(r2)))
		var v: DVec3 = d.vel
		v.add_scaled(acc, dt)
		var alt := sqrt(r2) - db.radius
		var rho := db.density_at(alt)
		if rho > 0.0:
			v.add_scaled(v, -minf(rho * v.length() * 0.0004 * dt, 0.5))
		p.add_scaled(v, dt)
		if d.life <= 0.0 or alt < 0.0:
			(d.node as Node3D).queue_free()
			_debris.remove_at(i)


func _process(delta: float) -> void:
	# Floating origin: vessel at 0; everything else relative to it in doubles.
	var vabs := vessel_absolute()
	for b in bodies:
		var rel := b.absolute_position(sim_time).sub(vabs)
		(planets[b] as Node3D).call("update_view", rel, sim_time, 1.0 if map_mode else _view_scale(rel.length(), b.radius))
	rocket.basis = Basis(vessel.attitude)
	rocket.update_visual(delta)
	for d in _debris:
		var n: Node3D = d.node
		var dabs := (d.body as CelestialBody).absolute_position(sim_time).add(d.pos)
		n.global_transform = Transform3D(d.basis, dabs.sub(vabs).to_v3())

	_update_sky()
	if map_mode:
		_update_map_camera()
	elif eva_mode:
		_update_eva_camera()
		tether.update_visual(hatch_world(), astronaut.global_position + astronaut.global_transform.basis * Vector3(0, 0.15, 0.32), camera.global_position, delta)
	else:
		_update_flight_camera()
	traj_view.visible = map_mode
	if map_mode:
		_traj_timer -= delta
		if _traj_timer <= 0.0:
			_traj_timer = 0.25
			refresh_trajectory()
		var node_pos = null
		var shown: ManeuverNode = maneuver if maneuver != null else autopilot.node
		if shown != null and shown.body == vessel.body and shown.t > sim_time:
			var st := shown.state_before(vessel.pos, vessel.vel, sim_time)
			node_pos = body_render_pos(vessel.body) + (st[0] as DVec3).to_v3()
		traj_view.update_view(_body_pos_at, sim_time, camera, vessel.up_world(), vessel.vel.to_v3(), node_pos)


## Scaled-space rule for the flight view: bodies whose surface is farther than
## NEAR_LIMIT are drawn at a compressed (log) distance with the same angular size.
const NEAR_LIMIT := 120_000.0


# --- Maneuver node (map editor) ---------------------------------------------------------

func create_maneuver() -> void:
	if vessel.landed or vessel.destroyed_flag:
		message.emit("Манёвр можно ставить только в полёте")
		return
	maneuver = ManeuverNode.new(sim_time + 120.0, vessel.body)
	_update_preview()


func clear_maneuver() -> void:
	maneuver = null
	preview = []
	traj_view.set_preview(preview, vessel.body)
	hud.on_maneuver_changed()


func maneuver_set_time(where: String) -> void:
	if maneuver == null:
		create_maneuver()
	var el := OrbitMath.elements(vessel.pos, vessel.vel, vessel.body.mu)
	match where:
		"soon": maneuver.t = sim_time + 120.0
		"apo":
			if el.e >= 1.0:
				message.emit("Орбита незамкнута — апоцентра нет")
				return
			maneuver.t = sim_time + Planner.time_to_anomaly(el, PI)
		"peri": maneuver.t = sim_time + Planner.time_to_anomaly(el, 0.0)
	maneuver.body = vessel.body
	_update_preview()


func maneuver_shift(dt: float) -> void:
	if maneuver == null:
		create_maneuver()
	maneuver.t = maxf(maneuver.t + dt, sim_time + 10.0)
	_update_preview()


func maneuver_add(key: String, dv: float) -> void:
	if maneuver == null:
		create_maneuver()
	maneuver.set(key, maneuver.get(key) + dv)
	_update_preview()


func execute_maneuver() -> void:
	if maneuver == null:
		return
	start_mission(Autopilot.tasks_execute(maneuver))


func _update_preview() -> void:
	if maneuver == null or maneuver.body != vessel.body:
		clear_maneuver()
		return
	preview = maneuver.predict_after(vessel.pos, vessel.vel, sim_time)
	traj_view.set_preview(preview, vessel.body)
	maneuver_info = describe_trajectory(preview)
	hud.on_maneuver_changed()


## Short text about a predicted trajectory: apsides and encounters.
func describe_trajectory(segs: Array[Dictionary]) -> String:
	if segs.is_empty():
		return ""
	var s0: Dictionary = segs[0]
	var b: CelestialBody = s0.body
	var parts := PackedStringArray()
	parts.append("Пе %s" % TrajectoryView.fmt_dist(s0.el.periapsis - b.radius))
	if s0.el.e < 1.0 and s0.end == "loop":
		parts.append("Ап %s" % TrajectoryView.fmt_dist(s0.el.apoapsis - b.radius))
	for i in range(1, segs.size()):
		var sg: Dictionary = segs[i]
		var sb: CelestialBody = sg.body
		if sb != b:
			parts.append("%s: Пе %s" % [sb.name, TrajectoryView.fmt_dist(sg.el.periapsis - sb.radius)])
			break
	if s0.end == "impact":
		parts.append("падение!")
	if s0.end == "exit":
		parts.append("уход из сферы %s" % b.name)
	return ", ".join(parts)


# --- EVA ----------------------------------------------------------------------------

func can_eva() -> String:
	if eva_mode:
		return "уже снаружи"
	if vessel.destroyed_flag:
		return "корабль разрушен"
	if vessel.landed:
		return "выход на поверхность — в следующем этапе"
	if vessel.body.has_atmosphere() and vessel.altitude() < vessel.body.atmosphere_height:
		return "в атмосфере выходить нельзя"
	if vessel.throttle > 0.0:
		return "сначала выключи двигатель"
	return ""


func start_eva() -> void:
	var why := can_eva()
	if why != "":
		message.emit("Выход невозможен: " + why)
		return
	autopilot.stop(vessel)
	if map_mode:
		toggle_map()
	set_warp(0)
	vessel.throttle = 0.0
	vessel.sas = true
	vessel.hold_mode = ""
	astronaut = AstronautScript.new()
	add_child(astronaut)
	var hatch: Vector3 = hatch_world()
	var out: Vector3 = (hatch - rocket.global_transform * (rocket.hatch_local() - Vector3(0, 0, 0.35))).normalized()
	astronaut.global_transform = Transform3D(Basis.looking_at(-out, rocket.global_transform.basis.y), hatch + out * 0.3)
	astronaut.linear_velocity = out * 0.15
	tether = TetherScript.new()
	add_child(tether)
	tether.length = 12.0
	tether.reset_chain(hatch, astronaut.global_position)
	eva_mode = true
	_tether_broken_reported = false
	hud.visible = false
	eva_hud = EvaHudScript.new()
	eva_hud.flight = self
	add_child(eva_hud)
	eva_cam_dist = 5.0
	Log.info("EVA: started at %s, alt %.0f m" % [vessel.body.name, vessel.altitude()])
	message.emit("Выход в открытый космос. Трос 12 м")


func end_eva(forced_reason := "") -> void:
	if not eva_mode:
		return
	if forced_reason == "" and astronaut_hatch_distance() > 2.5:
		message.emit("До люка дальше 2.5 м")
		return
	astronaut.queue_free()
	tether.queue_free()
	eva_hud.queue_free()
	astronaut = null
	tether = null
	eva_hud = null
	eva_mode = false
	hud.visible = true
	if forced_reason != "":
		Log.warn("EVA: " + forced_reason)
		hud.show_destroyed(forced_reason)
	else:
		Log.info("EVA: back inside")
		message.emit("Космонавт в корабле")


## Removes the astronaut without checks (reset / teleport).
func abort_eva() -> void:
	if not eva_mode:
		return
	astronaut.queue_free()
	tether.queue_free()
	eva_hud.queue_free()
	astronaut = null
	tether = null
	eva_hud = null
	eva_mode = false
	hud.visible = true


func hatch_world() -> Vector3:
	return rocket.global_transform * rocket.hatch_local()


func astronaut_hatch_distance() -> float:
	if astronaut == null:
		return INF
	return astronaut.global_position.distance_to(hatch_world())


## Debug: put the astronaut back at the hatch with a fresh tether.
func debug_eva_to_hatch() -> void:
	if not eva_mode:
		return
	astronaut.global_position = hatch_world()
	astronaut.linear_velocity = Vector3.ZERO
	astronaut.angular_velocity = Vector3.ZERO
	tether.attach(3.0)
	tether.reset_chain(hatch_world(), astronaut.global_position)
	_tether_broken_reported = false


## Debug: fire the ship's engine for 2 s during EVA (to test tether loads).
func debug_ship_kick() -> void:
	_ship_kick = 2.0
	message.emit("Корабль: тяга 2 с")


func _eva_physics(dt: float) -> void:
	if _ship_kick > 0.0:
		_ship_kick -= dt
		vessel.throttle = 1.0 if _ship_kick > 0.0 else 0.0
	var ship_acc := vessel.last_accel_ng
	astronaut.physics_tick(dt, ship_acc)
	var anchor := hatch_world()
	var f: Vector3 = tether.force_on(astronaut.global_position, astronaut.linear_velocity, anchor, Vector3.ZERO, dt)
	astronaut.apply_central_force(f)
	if tether.broken and not _tether_broken_reported:
		_tether_broken_reported = true
		Log.warn("EVA: tether broke")
		message.emit("ТРОС ОБОРВАЛСЯ!")
	if astronaut.oxygen <= 0.0:
		end_eva("Космонавт погиб: кончился кислород")


var _tether_broken_reported := false


func _update_eva_camera() -> void:
	# Chase camera behind the astronaut's back, up = astronaut up.
	var b := astronaut.global_transform.basis
	var target := astronaut.global_position + b.y * 0.4
	var cam_pos := target + b.z * eva_cam_dist + b.y * eva_cam_dist * 0.25
	camera.near = 0.1
	var far := 1000.0
	var vabs := vessel_absolute()
	for bd in bodies:
		var dist := bd.absolute_position(sim_time).sub(vabs).length()
		far = maxf(far, (dist + bd.radius * 1.05) * _view_scale(dist, bd.radius))
	camera.far = far
	camera.global_transform = Transform3D(Basis(), cam_pos).looking_at(target, b.y)


func _view_scale(dist: float, radius: float) -> float:
	if dist - radius <= NEAR_LIMIT:
		return 1.0
	var d := dist - radius
	var compressed := NEAR_LIMIT * (1.0 + log(d / NEAR_LIMIT) * 0.25)
	return (compressed + radius * (compressed / d)) / dist


func vessel_absolute() -> DVec3:
	return vessel.body.absolute_position(sim_time).add(vessel.pos)


## Render position (relative to the vessel) of a body's centre.
func body_render_pos(b: CelestialBody) -> Vector3:
	return b.absolute_position(sim_time).sub(vessel_absolute()).to_v3()


## Render position of a body at time t (t < 0 = now), relative to the vessel now.
func _body_pos_at(b: CelestialBody, t: float) -> Vector3:
	var tt := sim_time if t < 0.0 else t
	return b.absolute_position(tt).sub(vessel_absolute()).to_v3()


func refresh_trajectory() -> void:
	if vessel.landed or vessel.destroyed_flag:
		trajectory = []
	else:
		trajectory = Trajectory.predict(vessel.pos, vessel.vel, vessel.body, sim_time)
	traj_view.set_trajectory(trajectory, vessel.body)
	if maneuver != null:
		if maneuver.t < sim_time and not autopilot.active():
			clear_maneuver()
		else:
			_update_preview()


func _update_sky() -> void:
	var alt := vessel.altitude()
	var up := vessel.pos.normalized().to_v3()
	var dens := body.density_at(alt) / body.sea_level_density if body.has_atmosphere() else 0.0
	var sun_elev := up.dot(SUN_DIR.normalized())
	var daylight := smoothstep(-0.15, 0.2, sun_elev)
	var day := clampf(pow(dens, 0.35), 0.0, 1.0) * daylight
	if map_mode:
		day = 0.0
	sky_mat.set_shader_parameter("day_amount", day)
	sky_mat.set_shader_parameter("local_up", up)
	env.ambient_light_color = Color(0.06, 0.07, 0.1).lerp(Color(0.35, 0.42, 0.55), day)


func _update_flight_camera() -> void:
	# Keep far/near sane for depth precision and culling: far just covers the bodies.
	camera.near = 0.5
	var far := 1000.0
	var vabs := vessel_absolute()
	for b in bodies:
		var dist := b.absolute_position(sim_time).sub(vabs).length()
		far = maxf(far, (dist + b.radius * 1.05) * _view_scale(dist, b.radius))
	camera.far = far
	# Camera orbits the vessel in the local horizon frame (up = away from the planet),
	# yaw 0 = looking north from the south side.
	var up := vessel.pos.normalized().to_v3()
	var east := Vector3.UP.cross(up)
	if east.length() < 1e-6:
		east = Vector3.RIGHT
	east = east.normalized()
	var south := east.cross(up)
	var horiz := south * cos(cam_yaw) + east * sin(cam_yaw)
	var center := Basis(vessel.attitude) * Vector3(0, 6.0, 0)
	var offset := (horiz * cos(cam_pitch) + up * sin(cam_pitch)) * cam_dist
	camera.global_transform = Transform3D(Basis(), center + offset).looking_at(center, up)


func _update_map_camera() -> void:
	var center := body_render_pos(map_focus)
	var offset := Vector3(
		sin(map_yaw) * cos(map_pitch),
		sin(map_pitch),
		cos(map_yaw) * cos(map_pitch)) * map_dist
	var far := map_dist * 3.0
	for b in bodies:
		far = maxf(far, (center + offset).distance_to(body_render_pos(b)) + b.radius)
	camera.far = far * 1.5
	camera.near = maxf(map_dist * 0.001, 10.0)
	camera.global_transform = Transform3D(Basis(), center + offset).looking_at(center, Vector3.UP)


func _map_zoom_limits() -> Vector2:
	return Vector2(map_focus.radius * 1.2, maxf(map_focus.radius * 200.0, 1.0e8 if map_focus.parent == null else map_focus.soi_radius * 3.0))


func toggle_map() -> void:
	map_mode = not map_mode
	rocket.visible = not map_mode and not vessel.destroyed_flag
	if map_mode:
		map_focus = vessel.body
		_traj_timer = 0.0
		map_dist = maxf(vessel.pos.length() * 3.2, body.radius * 3.2)
		# Look from above the orbit plane, offset toward the vessel: orbit reads as an ellipse.
		var radial := vessel.pos.normalized().to_v3()
		var normal := vessel.pos.cross(vessel.vel).normalized().to_v3()
		var d := (normal * 0.75 + radial * 0.65).normalized()
		if normal.length() < 0.5:
			d = radial
		map_yaw = atan2(d.x, d.z)
		map_pitch = clampf(asin(clampf(d.y, -1.0, 1.0)), -1.5, 1.5)


## Cycle the map focus through all bodies.
func cycle_map_focus() -> void:
	var i := bodies.find(map_focus)
	map_focus = bodies[(i + 1) % bodies.size()]
	map_dist = map_focus.radius * (12.0 if map_focus.parent != null else 80.0)
	message.emit("Карта: %s" % map_focus.name)


# --- Camera input (touches not taken by the HUD) --------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		if _touches.size() == 2:
			var ps: Array = _touches.values()
			_pinch_dist0 = (ps[0] as Vector2).distance_to(ps[1])
			_pinch_start = map_dist if map_mode else (eva_cam_dist if eva_mode else cam_dist)
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			var rel: Vector2 = event.relative * 0.006
			if map_mode:
				map_yaw -= rel.x
				map_pitch = clampf(map_pitch + rel.y, -1.5, 1.5)
			else:
				cam_yaw -= rel.x
				cam_pitch = clampf(cam_pitch + rel.y, -1.45, 1.45)
		elif _touches.size() == 2 and _pinch_dist0 > 0.0:
			var ps: Array = _touches.values()
			var dnow := (ps[0] as Vector2).distance_to(ps[1])
			var k := _pinch_dist0 / maxf(dnow, 1.0)
			if map_mode:
				var lim := _map_zoom_limits()
				map_dist = clampf(_pinch_start * k, lim.x, lim.y)
			elif eva_mode:
				eva_cam_dist = clampf(_pinch_start * k, 2.0, 40.0)
			else:
				cam_dist = clampf(_pinch_start * k, 8.0, 2000.0)
	elif event is InputEventMouseButton and event.pressed:
		# Desktop testing: wheel zoom.
		var f := 0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else (1.1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 1.0)
		if map_mode:
			var lim := _map_zoom_limits()
			map_dist = clampf(map_dist * f, lim.x, lim.y)
		else:
			cam_dist = clampf(cam_dist * f, 8.0, 2000.0)


func zoom(f: float) -> void:
	if map_mode:
		var lim := _map_zoom_limits()
		map_dist = clampf(map_dist * f, lim.x, lim.y)
	else:
		cam_dist = clampf(cam_dist * f, 8.0, 2000.0)
