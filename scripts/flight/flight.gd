extends Node3D
## Flight scene controller: owns simulation time, time warp, the active vessel,
## floating origin (vessel always at the scene origin), cameras and map mode.

const PlanetView := preload("res://scripts/flight/planet_view.gd")
const RocketView := preload("res://scripts/flight/rocket_view.gd")
const SoundFxScript := preload("res://scripts/flight/sound_fx.gd")
const FxScript := preload("res://scripts/flight/fx_particles.gd")
const TrajectoryView := preload("res://scripts/flight/trajectory_view.gd")
const HudScript := preload("res://scripts/flight/flight_hud.gd")
const SKY_SHADER := preload("res://shaders/starfield.gdshader")
const AstronautScript := preload("res://scripts/eva/astronaut.gd")
const TetherScript := preload("res://scripts/eva/tether.gd")
const EvaHudScript := preload("res://scripts/eva/eva_hud.gd")
const HdTilesScript := preload("res://scripts/flight/hd_tiles.gd")

const DT := 1.0 / 60.0
const WARPS: Array[int] = [1, 2, 4, 10, 50, 100, 1000, 10000, 100000, 1000000]
const PHYSICS_WARP_MAX := 4

signal message(text: String)

## Sky per body: [zenith, horizon, haze density near the ground].
const SKY_COLORS := {
	"earth": [Color(0.18, 0.38, 0.78), Color(0.62, 0.76, 0.95), 0.000015],
	"mars": [Color(0.62, 0.48, 0.36), Color(0.86, 0.68, 0.48), 0.00007],
	"venus": [Color(0.55, 0.4, 0.18), Color(0.9, 0.68, 0.32), 0.0006],
	"jupiter": [Color(0.55, 0.48, 0.38), Color(0.82, 0.74, 0.6), 0.0002],
	"saturn": [Color(0.6, 0.55, 0.4), Color(0.86, 0.8, 0.62), 0.0002],
	"uranus": [Color(0.4, 0.62, 0.68), Color(0.68, 0.86, 0.9), 0.0002],
	"neptune": [Color(0.18, 0.28, 0.7), Color(0.45, 0.58, 0.92), 0.0002],
}

var root_body: CelestialBody   ## the Sun
var home: CelestialBody        ## Earth (launch site)
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
var sfx: Node
var _prev_ang_vel := Vector3.ZERO
var _was_landed := true
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
var cam_dist := 55.0
# Map camera, inertial, around the planet.
var map_yaw := 0.0
var map_pitch := 0.5
var map_dist := 2_500_000.0

var autopilot := Autopilot.new()
var hd_tiles: Node = null
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
	home = SolarSystem.find(root_body, "earth")
	_collect_bodies(root_body)
	_set_morning_at_site()
	_build_environment()
	for b in bodies:
		var pv := PlanetView.new()
		add_child(pv)
		pv.setup(b, b == home, SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON, SolarSystem.sun_dir(b, 0.0))
		planets[b] = pv
	hd_tiles = HdTilesScript.new()
	add_child(hd_tiles)
	sfx = SoundFxScript.new()
	add_child(sfx)
	hd_tiles.tiles_ready.connect(func(b: CelestialBody, tex: Texture2D, rect: Rect2) -> void:
		(planets[b] as Node3D).call("set_hd", tex, rect))
	rocket = RocketView.new()
	add_child(rocket)
	fx = FxScript.new()
	add_child(fx)
	_flame_light = OmniLight3D.new()
	_flame_light.light_color = Color(1.0, 0.62, 0.3)
	_flame_light.omni_range = 110.0
	_flame_light.omni_attenuation = 1.0
	_flame_light.shadow_enabled = false
	_flame_light.visible = false
	add_child(_flame_light)
	traj_view = TrajectoryView.new()
	add_child(traj_view)
	traj_view.setup(root_body)
	map_focus = home
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
	if not Game.pending.is_empty():
		var st := Game.pending
		Game.pending = {}
		if not apply_state(st):
			reset_to_pad()
	else:
		reset_to_pad()
	Log.info("Flight: scene ready, bodies=%d, body=%s R=%.0f m g=%.2f" % [bodies.size(), body.name, body.radius, body.surface_gravity()])


func _collect_bodies(b: CelestialBody) -> void:
	bodies.append(b)
	for c in b.children:
		_collect_bodies(c)


## Picks the planet spin offset so the launch site has the sun ~35° high, rising, at t = 0.
func _set_morning_at_site() -> void:
	var n := CelestialBody.surface_normal(SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON)
	var sdir := DVec3.from_v3(SolarSystem.sun_dir(home, 0.0))
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
	home.rotation_offset = best


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
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	# Short range, so the near split is sharp (rocket, lander, rocks around).
	sun.directional_shadow_max_distance = 80.0
	sun.directional_shadow_split_1 = 0.2
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 2.2
	add_child(sun)
	_update_sun_light()


## Direction from the vessel towards the Sun (inertial == scene axes).
func sun_dir() -> Vector3:
	var p := vessel_absolute() if vessel != null else home.absolute_position(sim_time)
	return p.mul(-1.0).normalized().to_v3() if p.length() > 1.0 else Vector3(0.62, 0.35, 0.7).normalized()


func _update_sun_light() -> void:
	var d := sun_dir()
	sun.look_at_from_position(Vector3.ZERO, -d, Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT)


# --- Vessel lifecycle -------------------------------------------------------------

func reset_to_pad() -> void:
	abort_eva()
	for d in _debris:
		d.node.queue_free()
	_debris.clear()
	if fx:
		fx.clear()
	if vessel:
		autopilot.disengage(vessel)
	var inf_fuel := vessel.infinite_fuel if vessel else false
	_set_vessel(Vessel.make(Vessel.design, home))
	vessel.infinite_fuel = inf_fuel
	vessel.place_on_surface(SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON, sim_time)
	# Roll so local +X points east and +Z south: joystick right = nose east.
	var up := vessel.pos.normalized().to_v3()
	var east := Vector3.UP.cross(up).normalized()
	var south := east.cross(up)
	vessel.set_landed_attitude(Basis(east, up, south).get_rotation_quaternion(), sim_time)
	rocket.build(vessel)
	clear_maneuver()
	set_warp(0)
	cam_yaw = 0.35
	cam_pitch = 0.12
	cam_dist = 55.0
	hud.on_vessel_reset()
	Log.info("Flight: vessel on pad, mass %.0f kg, dV %.0f m/s, TWR %.2f" % [vessel.mass(), vessel.total_delta_v(), vessel.twr()])


func _set_vessel(v: Vessel) -> void:
	vessel = v
	vessel.staged.connect(_on_staged)
	vessel.destroyed.connect(_on_destroyed)
	vessel.soi_changed.connect(_on_soi_changed)
	vessel.burned_off.connect(func(st: Dictionary) -> void:
		_sparks(st)
		message.emit("%s сгорела при входе в атмосферу" % st.name)
		Log.warn("Flight: %s burned off on entry" % st.name))
	vessel.landed_changed.connect(_on_landed_changed)
	vessel.wrecked.connect(_on_wrecked)


## Debug: replaces the vessel by the lunar module (capsule + ascent + descent
## stage) in a circular orbit around the Moon.
func teleport_lunar_module_to_orbit(altitude: float) -> void:
	autopilot.disengage(vessel)
	abort_eva()
	var inf_fuel := vessel.infinite_fuel
	_set_vessel(Vessel.lunar_module(vessel.body))
	vessel.infinite_fuel = inf_fuel
	rocket.build(vessel)
	teleport_to_body_orbit(SolarSystem.find(root_body, "Луна"), altitude)
	Log.info("Flight: lunar module in Moon orbit, dV %.0f m/s" % vessel.total_delta_v())


## Debug: circular orbit at the given altitude (prograde, equatorial-ish over the site).
func teleport_to_orbit(altitude: float) -> void:
	autopilot.disengage(vessel)
	abort_eva()
	clear_maneuver()
	vessel.chute_deployed = false
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
	rocket.visible = not map_mode
	hud.on_vessel_reset()
	_traj_timer = 0.0
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


## Reasonable low orbit for a debug teleport: above the atmosphere, inside the SOI.
func default_orbit_altitude(b: CelestialBody) -> float:
	if b.has_atmosphere():
		return b.atmosphere_height * 1.5 + b.radius * 0.1
	if b.radius < 20_000.0:
		return b.radius * 0.6   # tiny moons: their SOI is only a few radii
	return b.radius * 0.15


## Bodies you can stand on (not the Sun, not gas giants).
func has_solid_surface(b: CelestialBody) -> bool:
	return not b.is_star and not (b.id in ["jupiter", "saturn", "uranus", "neptune"])


## Debug: on a Hohmann transfer from a 20 km orbit that hits the Moon's SOI.
func teleport_to_moon_transfer() -> void:
	autopilot.disengage(vessel)
	var moon := SolarSystem.find(root_body, "Луна")
	var r1 := home.radius + 20_000.0
	var r_m := moon.orbit_a
	var tof := 0.0
	var m_hat := DVec3.new()
	for _k in 5:
		var a_t := (r1 + r_m) * 0.5
		tof = PI * sqrt(a_t * a_t * a_t / home.mu)
		var mp: DVec3 = moon.state_at(sim_time + tof)[0]
		m_hat = mp.normalized()
		r_m = mp.length()
	var st: Array = moon.state_at(sim_time)
	var h_m := (st[0] as DVec3).cross(st[1]).normalized()
	# Aim slightly off-centre so the pass misses the surface (~periapsis 50-100 km).
	var p_ship := m_hat.mul(-r1)
	var v_dir := h_m.cross(p_ship.normalized())
	var a_tr := (r1 + r_m - 2.0 * moon.radius) * 0.5
	vessel.body = home
	vessel.pos = p_ship
	vessel.vel = v_dir.mul(sqrt(home.mu * (2.0 / r1 - 1.0 / a_tr)))
	_after_teleport("перелёт к Луне")


## Longitude on the equator of `b` where the sun is ~40° high right now.
func sunlit_longitude(b: CelestialBody) -> float:
	var sdir := DVec3.from_v3(SolarSystem.sun_dir(b, sim_time))
	var best := 0.0
	var best_err := INF
	for i in 360:
		var n := b.fixed_to_inertial(CelestialBody.surface_normal(0.0, float(i)), sim_time)
		var err := absf(n.dot(sdir) - sin(deg_to_rad(40.0)))
		if err < best_err:
			best_err = err
			best = float(i)
	return best


## Debug: landed on a body's surface at lat/lon.
func teleport_to_surface(target: CelestialBody, lat: float, lon: float) -> void:
	autopilot.disengage(vessel)
	abort_eva()
	clear_maneuver()
	vessel.chute_deployed = false
	vessel.body = target
	vessel.throttle = 0.0
	vessel.destroyed_flag = false
	vessel.place_on_surface(lat, lon, sim_time)
	set_warp(0)
	rocket.visible = not map_mode
	hud.on_vessel_reset()
	_traj_timer = 0.0
	Log.info("Flight: teleported to the surface of %s (%.1f, %.1f)" % [target.name, lat, lon])


func _after_teleport(what: String) -> void:
	abort_eva()
	clear_maneuver()
	vessel.chute_deployed = false
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


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			# Android "back": pause menu instead of quitting the app.
			if hud:
				hud.toggle_pause()
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			# Fingers lifted while the app was away never send "released".
			_touches.clear()
			autosave()
		NOTIFICATION_WM_CLOSE_REQUEST:
			autosave()


func _exit_tree() -> void:
	get_tree().paused = false
	autosave()
	# Planning threads may still walk the body tree: let them finish first.
	if autopilot:
		autopilot.stop(vessel)
	ApPlan.wait_all()
	# Break parent <-> children reference cycles of the body tree.
	for b in bodies:
		b.children.clear()
		b.parent = null


## A stage destroyed by an impact or airloads while the crew lives on: its
## model breaks off as a charred wreck (lying on the ground after an impact,
## tumbling away in the air).
func _on_wrecked(st: Dictionary, reason: String) -> void:
	var node: Node3D = rocket.detach_bottom_stage()
	Log.warn("Flight: " + reason)
	message.emit(reason)
	sfx.event("crash", -2.0, 0.8)
	sfx.event("staging", 0.0, 0.6)
	if node == null:
		return
	# The stage explodes and is gone: fireball, flash, smoke and fragments.
	var gt: Transform3D = node.get_meta("global")
	var centre := gt * Vector3(0, float(st.length) * 0.5, 0)
	node.queue_free()
	_explosion(vessel.pos.add(DVec3.from_v3(centre)), float(st.diameter), float(st.length))


## Fireball + flash + smoke + flying fragments at a body-relative point.
func _explosion(at: DVec3, d: float, l: float) -> void:
	var b := vessel.body
	var air := b.has_atmosphere() and b.density_at(at.length() - b.radius) > 0.0
	var base := _air_velocity(b, at) if vessel.landed or air else vessel.vel
	var size := maxf(d, l * 0.5)
	var on_ground := has_solid_surface(b) and vessel.altitude_above_ground(sim_time) < 40.0
	var lift := 0.6 if on_ground else 0.0   # sits on the ground instead of half under it
	# Fireball: bright, fast-growing, short.
	for i in 34:
		var dir := _rand_dir()
		fx.emit(b, at.add(DVec3.from_v3(dir * randf_range(0.0, size * 0.5))),
			base.add(DVec3.from_v3(dir * randf_range(5.0, 18.0))),
			randf_range(0.6, 1.3), size * 0.9, size * randf_range(2.2, 3.4),
			Color(1.0, 0.38, 0.06, 0.9) if i % 3 else Color(1.0, 0.7, 0.3, 0.9), 1.5 if air else 0.3, false, 0.55, lift)
	# Smoke: billows in air, a quick dark puff in vacuum.
	for i in (22 if air else 10):
		var dir2 := _rand_dir()
		fx.emit(b, at.add(DVec3.from_v3(dir2 * randf_range(0.0, size * 0.5))),
			base.add(DVec3.from_v3(dir2 * randf_range(2.0, 8.0) + at.normalized().to_v3() * (2.0 if air else 0.0))),
			randf_range(3.0, 6.0) if air else randf_range(0.8, 1.5), size * 1.2, size * (4.0 if air else 2.8),
			Color(0.18, 0.16, 0.15, 0.75), 0.8 if air else 0.0, false, 0.4, lift)
	# Fragments: small hot sparks on ballistic paths.
	for i in 40:
		var dir3 := _rand_dir()
		fx.emit(b, at, base.add(DVec3.from_v3(dir3 * randf_range(15.0, 45.0))),
			randf_range(1.0, 2.5), 0.25, 0.15, Color(0.35, 0.2, 0.1, 1.0), 0.0, true, 1.0)
	if on_ground:
		_dust_burst(1.0)
	# Flash of light.
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.6, 0.3)
	flash.omni_range = size * 25.0
	flash.light_energy = 12.0
	flash.shadow_enabled = false
	add_child(flash)
	flash.global_position = at.sub(vessel.pos).to_v3()
	var tw := create_tween()
	tw.tween_property(flash, "light_energy", 0.0, 0.7).set_ease(Tween.EASE_OUT)
	tw.tween_callback(flash.queue_free)


func _on_staged(_dropped: Dictionary) -> void:
	var node: Node3D = rocket.detach_bottom_stage()
	if node == null:
		return
	add_child(node)
	node.top_level = true
	node.global_transform = node.get_meta("global")
	if vessel.landed:
		# Left standing on the ground (e.g. the descent stage on the Moon).
		_debris.append({
			"node": node, "body": vessel.body, "basis": node.global_transform.basis,
			"fixed": vessel.body.inertial_to_fixed(vessel.pos.add(DVec3.from_v3(node.global_position)), sim_time),
			"pos": DVec3.new(), "vel": DVec3.new(), "life": INF,
		})
		Log.info("Flight: stage left on the surface, %d stage(s) left" % vessel.stages.size())
		return
	_debris.append({
		"node": node,
		"pos": vessel.pos.add(DVec3.from_v3(node.global_position)),
		"vel": vessel.vel.sub(DVec3.from_v3(vessel.up_world() * Vessel.STAGE_SEPARATION_DV * 2.0)),
		"basis": node.global_transform.basis,
		"body": vessel.body,
		"life": 25.0,
	})
	Log.info("Flight: stage separated, %d stage(s) left" % vessel.stages.size())
	sfx.event("staging")


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
	sfx.event("crash")
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


var fx: Node   ## smoke / dust / sparks
var prof_off := {}   ## debug profiler: features switched off ("shadows", ...)
var _fx_acc := 0.0
var _trail_acc := 0.0
var _smoke_acc := 0.0
var _flame_light: OmniLight3D
var _last_ground_event := -100000
var _engine_recent := 99.0  ## seconds since the engine last ran (for scorch marks)


## Touchdown or liftoff on the engine: leave a scorch mark on the ground.
func _on_landed_changed(now_landed: bool) -> void:
	# Tiny moons: contact can flicker every frame; one puff / mark per 2 s.
	var now := Time.get_ticks_msec()
	if now - _last_ground_event < 2000:
		return
	_last_ground_event = now
	if now_landed and has_solid_surface(vessel.body):
		_dust_burst(clampf(vessel.touchdown_speed / 6.0, 0.3, 1.0))
	if _engine_recent > 2.5 or not has_solid_surface(vessel.body):
		return
	if vessel.body == home and vessel.pos.sub(_pad_position()).length() < 60.0:
		return   # the launch pad has its own scorched concrete
	var d := 0.0
	for st in vessel.stages:
		d = maxf(d, float(st.diameter))
	var size := d * (6.0 if now_landed else 4.0)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	mi.mesh = pm
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/scorch.gdshader")
	m.set_shader_parameter("seed", randf() * 100.0)
	m.set_shader_parameter("strength", 0.85 if vessel.body.has_atmosphere() else 0.7)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.top_level = true
	var ground := vessel.pos.normalized().mul(vessel.body.radius + vessel.ground_height(sim_time) + 0.06)
	_debris.append({
		"node": mi, "body": vessel.body, "basis": Basis(), "scorch": true,
		"fixed": vessel.body.inertial_to_fixed(ground, sim_time),
		"pos": DVec3.new(), "vel": DVec3.new(), "life": INF,
	})


# --- Smoke & dust -----------------------------------------------------------------

func _rand_dir() -> Vector3:
	return Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()


func _air_velocity(b: CelestialBody, p: DVec3) -> DVec3:
	return DVec3.new(0, b.angular_velocity(), 0).cross(p)


var _dust_cache := {}


func _dust_color(b: CelestialBody, alpha: float) -> Color:
	var c: Color = _dust_cache.get(b, Color(0.62, 0.6, 0.56))
	if not _dust_cache.has(b) and planets.has(b):
		c = (planets[b] as Node3D).call("surface_style").get("dust_color", c)
		_dust_cache[b] = c
	if b == home:
		c = Color(0.7, 0.68, 0.64)   # exhaust smoke + dust on Earth: grey-beige clouds
	return Color(c.r, c.g, c.b, alpha)


## Ground point under the vessel (relative to the body centre).
func _ground_under() -> DVec3:
	var b := vessel.body
	return vessel.pos.normalized().mul(b.radius + vessel.ground_height(sim_time))


func _update_fx(delta: float) -> void:
	var w := warp()
	if w > PHYSICS_WARP_MAX or map_mode:
		fx.clear()
		_flame_light.visible = false
		return
	var b := vessel.body
	var v := vessel
	var low := Graphics.quality == Graphics.LOW
	# Engine blast on the ground: billowing clouds in air, a ballistic spray in vacuum.
	if v.last_thrust > 0.0 and has_solid_surface(b) and not v.destroyed_flag:
		var agl := v.altitude_above_ground(sim_time) - v.height_offset
		if agl < 60.0:
			var thr := v.last_thrust / maxf(v.current_thrust_max(), 1.0)
			var k := (1.0 - agl / 60.0) * clampf(thr * 2.0, 0.6, 1.0)
			var air := b.has_atmosphere()
			_fx_acc += delta * k * ((16.0 if low else 30.0) if air else (32.0 if low else 60.0))
			var g := _ground_under()
			var up := g.normalized().to_v3()
			while _fx_acc >= 1.0:
				_fx_acc -= 1.0
				var d := _rand_dir()
				d = (d - up * d.dot(up)).normalized()
				var at := g.add(DVec3.from_v3(d * randf_range(0.5, 2.0) + up * 0.3))
				if air:
					# Thick clouds rolling out along the ground, then rising.
					var sp := randf_range(10.0, 34.0) * k
					fx.emit(b, at, _air_velocity(b, at).add(DVec3.from_v3(d * sp + up * randf_range(1.0, 5.0))),
						randf_range(8.0, 13.0), randf_range(6.0, 9.0), randf_range(20.0, 34.0), _dust_color(b, 0.97), 0.35, false, 0.0, 0.22)
				else:
					# Vacuum: a low, fast sheet of dust skimming outward (Apollo landings).
					# Regolith: a thick, low cloud skimming out along the ground (as
					# dense as in air, but it hugs the surface).
					var sp2 := randf_range(8.0, 30.0) * maxf(k, 0.4)
					fx.emit(b, at, _air_velocity(b, at).add(DVec3.from_v3(d * sp2 + up * randf_range(0.1, 0.8))),
						randf_range(3.0, 5.0), randf_range(3.0, 5.0), randf_range(11.0, 18.0), _dust_color(b, 0.92).lightened(0.12), 0.35, false, 0.0, 0.4)
	# Ascent in thick air: a column of exhaust smoke left behind the engines.
	if v.last_thrust > 0.0 and b.has_atmosphere() and not v.destroyed_flag:
		var dens := b.density_at(v.altitude()) / b.sea_level_density
		if dens > 0.05:
			_smoke_acc += delta * clampf(dens, 0.0, 1.0) * (10.0 if low else 24.0)
			var down := -v.up_world()
			while _smoke_acc >= 1.0:
				_smoke_acc -= 1.0
				var at := v.pos.add(DVec3.from_v3(down * randf_range(4.0, 9.0) + _rand_dir() * 0.8))
				fx.emit(b, at, _air_velocity(b, at).add(DVec3.from_v3(down * randf_range(15.0, 30.0) + _rand_dir() * 3.0)),
					randf_range(6.0, 10.0), 3.0, randf_range(12.0, 22.0), Color(0.86, 0.85, 0.83, 0.7), 0.5, false, 0.5)
	# Re-entry: glowing smoke left in the air behind the leading end.
	if v.heat_flux > 40_000.0 and not v.destroyed_flag:
		var q := clampf(v.heat_flux / 300_000.0, 0.15, 1.0)
		_trail_acc += delta * q * (20.0 if low else 45.0)
		var total := 0.0
		var r := 0.5
		for st in v.stages:
			total += float(st.length)
			r = maxf(r, float(st.diameter) * 0.5)
		var lead_h := total if v.heat_lead == "nose" else (v.com_height() if v.heat_lead == "side" else 0.0)
		var lead := v.pos.add(DVec3.from_v3(v.up_world() * lead_h))
		while _trail_acc >= 1.0:
			_trail_acc -= 1.0
			var at := lead.add(DVec3.from_v3(_rand_dir() * r * 0.8))
			fx.emit(b, at, _air_velocity(b, at).add(DVec3.from_v3(_rand_dir() * 4.0)),
				randf_range(3.0, 5.0), r * 2.0, r * randf_range(6.0, 10.0), Color(0.3, 0.27, 0.25, 0.7), 0.25, false, q)
	fx.set_light(lerpf(1.0, 0.12, rocket.night))
	var near_g := has_solid_surface(b) and v.altitude_above_ground(sim_time) < 3000.0 and not map_mode
	if near_g:
		var gp := _ground_under()
		fx.set_ground(gp.sub(v.pos).to_v3(), gp.normalized().to_v3(), true)
	else:
		fx.set_ground(Vector3.ZERO, Vector3.UP, false)
	var thr_f := v.last_thrust / maxf(v.current_thrust_max(), 1.0) if v.last_thrust > 0.0 else 0.0
	var nozzle := rocket.global_transform * Vector3(0, -3.0, 0)
	# A vacuum plume is thin and faint: it barely lights the dust.
	var pr_f := clampf(b.pressure_at(v.altitude()), 0.0, 1.0) if b.has_atmosphere() else 0.0
	fx.set_flame(nozzle, thr_f * lerpf(lerpf(0.12, 0.4, rocket.night), 1.0, pr_f), 22.0)
	fx.set_lamp(rocket.global_transform * Vector3(0, 2.0, 0), rocket.night)
	# The flame lights up the ground and the pad near it.
	var agl_f := v.altitude_above_ground(sim_time)
	_flame_light.visible = thr_f > 0.0 and agl_f < 200.0
	if _flame_light.visible:
		# Near the ground, where the flame hits it: lights the pad and the clouds.
		var up_f := v.pos.normalized().to_v3()
		# Never under the terrain (near touchdown the nozzle point is below it).
		var nozzle_agl := agl_f - 3.0
		_flame_light.global_position = nozzle - up_f * maxf(agl_f - 6.0, 0.0) * 0.8 + up_f * maxf(2.5 - nozzle_agl, 0.0)
		# A burning engine is about as bright at any throttle; dark regolith needs more.
		var dark_ground := 1.0 if b.has_atmosphere() else 3.2
		_flame_light.omni_range = 110.0 if b.has_atmosphere() else 150.0
		_flame_light.light_energy = lerpf(0.65, 1.0, thr_f) * (1.0 - agl_f / 200.0) * randf_range(6.5, 8.0) * dark_ground
	fx.step(delta * w, render_origin(), sim_time)


## Touchdown: a puff of dust around the feet.
func _dust_burst(k: float) -> void:
	var b := vessel.body
	var g := _ground_under()
	var up := g.normalized().to_v3()
	var air := b.has_atmosphere()
	for i in int(lerpf(8.0, 26.0, k)):
		var d := _rand_dir()
		d = (d - up * d.dot(up)).normalized()
		var at := g.add(DVec3.from_v3(d * randf_range(0.5, 1.8)))
		if air:
			fx.emit(b, at, _air_velocity(b, at).add(DVec3.from_v3(d * randf_range(2.0, 7.0) * k + up * 0.8)),
				randf_range(2.0, 3.5), 1.2, randf_range(4.0, 7.0), _dust_color(b, 0.45), 0.9)
		else:
			fx.emit(b, at, _air_velocity(b, at).add(DVec3.from_v3(d * randf_range(3.0, 10.0) * k + up * randf_range(0.5, 2.5))),
				randf_range(0.8, 1.6), 0.3, 1.0, _dust_color(b, 0.5), 0.0, true)


## A stage burning off on entry: a spray of glowing fragments and smoke.
func _sparks(st: Dictionary) -> void:
	var b := vessel.body
	var at := vessel.pos
	var base := vessel.vel
	for i in 34:
		var spark := i % 2 == 0
		fx.emit(b, at.add(DVec3.from_v3(_rand_dir() * float(st.diameter) * 0.6)),
			base.add(DVec3.from_v3(_rand_dir() * randf_range(10.0, 60.0))),
			randf_range(0.8, 2.0) if spark else randf_range(2.0, 3.5),
			0.4 if spark else 2.0, 0.7 if spark else 8.0,
			Color(0.35, 0.2, 0.1, 0.95) if spark else Color(0.2, 0.18, 0.17, 0.6), 0.4, false, 1.0 if spark else 0.6)


func _pad_position() -> DVec3:
	var n := CelestialBody.surface_normal(SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON)
	return home.fixed_to_inertial(n.mul(home.radius + home.surface_height(n)), sim_time)


func _step_debris(dt: float) -> void:
	for i in range(_debris.size() - 1, -1, -1):
		var d: Dictionary = _debris[i]
		if d.has("fixed"):
			# Static on the surface: rotates with the body; dropped when far away.
			d.pos = (d.body as CelestialBody).fixed_to_inertial(d.fixed, sim_time)
			if d.body != vessel.body or (d.pos as DVec3).sub(vessel.pos).length() > 50_000.0:
				(d.node as Node3D).queue_free()
				_debris.remove_at(i)
			continue
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


# --- Save / load ------------------------------------------------------------------

const AUTOSAVE_EVERY := 120.0
var _autosave_t := AUTOSAVE_EVERY


## Cargo can move between suit and ship inside, or right next to the ship.
func can_transfer_cargo() -> bool:
	return not eva_mode or entry_distance() < 4.0


## Where we are, for the save slot list.
func where_text() -> String:
	var v := vessel
	if v.landed:
		return "%s · на поверхности" % v.body.name
	var el := OrbitMath.elements(v.pos, v.vel, v.body.mu)
	if el.periapsis - v.body.radius > v.body.atmosphere_height and el.apoapsis > 0.0:
		return "%s · орбита %s × %s" % [v.body.name, TrajectoryView.fmt_dist(el.periapsis - v.body.radius), TrajectoryView.fmt_dist(el.apoapsis - v.body.radius)]
	return "%s · в полёте" % v.body.name


func save_state() -> Dictionary:
	return {"sim_time": sim_time, "vessel": vessel.to_data(), "cam": [cam_yaw, cam_pitch, cam_dist]}


func apply_state(d: Dictionary) -> bool:
	var vd: Dictionary = d.get("vessel", {})
	var b := SolarSystem.find(root_body, str(vd.get("body", "")))
	if b == null or vd.is_empty():
		Log.warn("Flight: save has no usable vessel, starting on the pad")
		return false
	abort_eva()
	sim_time = float(d.get("sim_time", 0.0))
	_set_vessel(Vessel.from_data(vd, b))
	if vessel.landed:
		vessel._stick_to_surface(sim_time)
	rocket.build(vessel)
	set_warp(0)
	var cam: Array = d.get("cam", [cam_yaw, cam_pitch, cam_dist])
	cam_yaw = float(cam[0])
	cam_pitch = float(cam[1])
	cam_dist = float(cam[2])
	hud.on_vessel_reset()
	_traj_timer = 0.0
	Log.info("Flight: loaded, %s" % where_text())
	return true


## Autosave (also on minimise / quit). Not after a crash, not in a test run.
func autosave() -> void:
	if not Game.has_game() or vessel == null or vessel.destroyed_flag:
		return
	Game.save_to(Game.AUTOSAVE, self)
	_autosave_t = AUTOSAVE_EVERY


func _process(delta: float) -> void:
	ApPlan.reap()
	vessel.cargo_mass = Game.ship_inv.mass()
	_autosave_t -= delta
	if _autosave_t <= 0.0:
		autosave()
	# Floating origin: the vessel at 0 (or the focused body on the map), everything
	# else relative to it in doubles.
	var vabs := render_origin()
	_update_sun_light()
	# Detailed ground patch under a low vessel (any body).
	var agl := vessel.altitude_above_ground(sim_time) if vessel.altitude() < 30_000.0 else INF
	if agl < 12_000.0:
		var fixed_n := vessel.body.inertial_to_fixed(vessel.pos, sim_time).normalized()
		(planets[vessel.body] as Node3D).call("ensure_patch", fixed_n, agl)
		hd_tiles.call("want", vessel.body, fixed_n)
	for b in bodies:
		var rel := b.absolute_position(sim_time).sub(vabs)
		(planets[b] as Node3D).call("update_view", rel, sim_time, 1.0 if map_mode else _view_scale(rel.length(), b.radius))
	rocket.basis = Basis(vessel.attitude)
	rocket.update_visual(delta)
	_update_sound(delta)
	_engine_recent = 0.0 if vessel.last_thrust > 0.0 else _engine_recent + delta
	_update_fx(delta)
	for d in _debris:
		var n: Node3D = d.node
		var dabs := (d.body as CelestialBody).absolute_position(sim_time).add(d.pos)
		var bas: Basis = d.basis
		if d.has("scorch"):
			# Flat on the ground: rebuilt from the local vertical (the body turns).
			var up := (d.pos as DVec3).normalized().to_v3()
			var x := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
			bas = Basis(x, up, x.cross(up))
		n.global_transform = Transform3D(bas, dabs.sub(vabs).to_v3())

	_update_sky()
	if map_mode:
		_update_map_camera()
	elif eva_mode:
		_update_eva_camera()
		if not is_surface_eva():
			tether.update_visual(hatch_world(), astronaut.global_position + astronaut.global_transform.basis * Vector3(0, 0.15, 0.32), camera.global_position, delta)
	else:
		_update_flight_camera()
	traj_view.visible = map_mode
	if map_mode:
		_traj_timer -= delta
		if _traj_timer <= 0.0:
			# Coasting: the conic barely changes, refresh it less often (saves CPU).
			_traj_timer = 0.25 if vessel.throttle > 0.0 or vessel.landed or autopilot.active() else 1.0
			refresh_trajectory()
		var node_pos = null
		var shown: ManeuverNode = maneuver if maneuver != null else autopilot.node
		if shown != null and shown.body == vessel.body and shown.t > sim_time:
			var st := shown.state_before(vessel.pos, vessel.vel, sim_time)
			node_pos = body_render_pos(vessel.body) + (st[0] as DVec3).to_v3()
		traj_view.focus = map_focus if map_mode else vessel.body
		traj_view.update_view(_body_pos_at, sim_time, camera, vessel.up_world(), vessel.vel.to_v3(), node_pos, ship_render_pos())


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
		return ""
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
	rocket.set_hatch_open(true)
	sfx.event("hatch_open")
	astronaut = AstronautScript.new()
	add_child(astronaut)
	if vessel.landed:
		_start_surface_eva()
		return
	var hatch: Vector3 = hatch_world()
	var out: Vector3 = (hatch - rocket.global_transform * (rocket.hatch_local() - Vector3(0, 0, 0.35))).normalized()
	astronaut.global_transform = Transform3D(Basis.looking_at(-out, rocket.global_transform.basis.y), hatch + out * 0.3)
	astronaut.linear_velocity = out * 0.15
	tether = TetherScript.new()
	add_child(tether)
	tether.length = 12.0
	tether.reset_chain(Vector3.ZERO, astronaut.global_position - hatch)
	eva_mode = true
	_tether_broken_reported = false
	hud.visible = false
	eva_hud = EvaHudScript.new()
	eva_hud.flight = self
	add_child(eva_hud)
	eva_cam_dist = 5.0
	Log.info("EVA: started at %s, alt %.0f m" % [vessel.body.name, vessel.altitude()])
	message.emit("Выход в открытый космос. Трос 12 м")


## Surface EVA: down the ladder to the ground next to the rocket, walking mode.
func _start_surface_eva() -> void:
	var up := vessel.pos.normalized().to_v3()
	var side := Vector3.UP.cross(up)
	side = side.normalized() if side.length() > 1e-3 else Vector3.RIGHT
	var rocket_r := 1.3
	_ground = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	_ground.add_child(cs)
	add_child(_ground)
	_update_ground()
	astronaut.global_position = side * (rocket_r + 1.5) + up * 1.0
	astronaut.linear_velocity = Vector3.ZERO
	var b := vessel.body
	# Only Earth's air is breathable: elsewhere the suit uses oxygen.
	astronaut.set_surface_mode(true, up, b.surface_gravity(), b.id == "earth")
	astronaut.cam_forward = -side
	tether = TetherScript.new()
	add_child(tether)
	tether.attached = false
	eva_mode = true
	_tether_broken_reported = true
	hud.visible = false
	eva_hud = EvaHudScript.new()
	eva_hud.flight = self
	eva_hud.surface = true
	add_child(eva_hud)
	eva_cam_dist = 6.0
	cam_yaw = 0.0
	Log.info("EVA: surface walk on %s, g=%.2f" % [vessel.body.name, b.surface_gravity()])
	message.emit("Выход на поверхность: %s" % vessel.body.name)


var _ground: StaticBody3D = null


## Ground plane under the astronaut: tangent to the terrain (height and slope
## from the body's relief map), so walking follows hills and crater walls.
func _update_ground() -> void:
	if _ground == null:
		return
	var at := astronaut.global_position if astronaut != null and is_instance_valid(astronaut) else Vector3.ZERO
	var c := _terrain_point(vessel.pos.add(DVec3.from_v3(at)))
	# The boots stand on the highest bump under them, not on the point under
	# the body centre (else they sink into small rises and crater rims).
	var up0 := vessel.pos.add(DVec3.from_v3(at)).normalized().to_v3()
	var side0 := up0.cross(Vector3.FORWARD if absf(up0.z) < 0.9 else Vector3.RIGHT).normalized()
	var fwd0 := side0.cross(up0)
	for off in [side0 * 0.35, -side0 * 0.35, fwd0 * 0.35, -fwd0 * 0.35]:
		var q := _terrain_point(vessel.pos.add(DVec3.from_v3(at + off)))
		var dh: float = (q - c).dot(up0)
		if dh > 0.0:
			c += up0 * dh
	# Slope from two neighbours ~2 m away along the local horizon.
	var up := vessel.pos.add(DVec3.from_v3(at)).normalized().to_v3()
	var e := Vector3.UP.cross(up)
	e = e.normalized() if e.length() > 1e-3 else Vector3.RIGHT
	var nrt := up.cross(e)
	var pe := _terrain_point(vessel.pos.add(DVec3.from_v3(at + e * 2.0)))
	var pn := _terrain_point(vessel.pos.add(DVec3.from_v3(at + nrt * 2.0)))
	var n := (pe - c).cross(pn - c).normalized()
	if n.dot(up) < 0.0:
		n = -n
	if n.dot(up) < 0.5:   # steeper than 60 deg: treat as a wall-ish slope, keep it walkable
		n = (n + up).normalized()
	var x := n.cross(Vector3.FORWARD if absf(n.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(n)
	_ground.global_transform = Transform3D(Basis(x, n, z), c)


## Terrain surface point (scene coordinates, relative to the vessel) under an
## inertial body-centred position.
func _terrain_point(p: DVec3) -> Vector3:
	var b := vessel.body
	var nf := b.inertial_to_fixed(p, sim_time).normalized()
	var r := b.radius + b.surface_height(nf)
	return p.normalized().mul(r).sub(vessel.pos).to_v3()


func is_surface_eva() -> bool:
	return eva_mode and astronaut != null and astronaut.surface_mode


## Distance used for "back inside": hatch in space, rocket base on the ground.
func entry_distance() -> float:
	if not is_surface_eva():
		return astronaut_hatch_distance()
	var up := vessel.pos.normalized().to_v3()
	var p: Vector3 = astronaut.global_position
	var horiz := p - up * p.dot(up)
	return maxf(horiz.length() - 1.3, 0.0)


func end_eva(forced_reason := "") -> void:
	if not eva_mode:
		return
	if forced_reason == "" and entry_distance() > 2.5:
		message.emit("Слишком далеко от %s" % ("ракеты" if is_surface_eva() else "люка"))
		return
	if _ground:
		_ground.queue_free()
		_ground = null
	astronaut.queue_free()
	tether.queue_free()
	eva_hud.queue_free()
	astronaut = null
	tether = null
	eva_hud = null
	eva_mode = false
	rocket.set_hatch_open(false)
	sfx.event("hatch_close")
	hud.visible = true
	if forced_reason != "":
		Log.warn("EVA: " + forced_reason)
		hud.show_destroyed(forced_reason, "Космонавт погиб")
	else:
		Log.info("EVA: back inside")
		message.emit("Космонавт в корабле")


## Removes the astronaut without checks (reset / teleport).
func abort_eva() -> void:
	if not eva_mode:
		return
	if _ground:
		_ground.queue_free()
		_ground = null
	astronaut.queue_free()
	tether.queue_free()
	eva_hud.queue_free()
	astronaut = null
	tether = null
	eva_hud = null
	eva_mode = false
	rocket.set_hatch_open(false)
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
	tether.reset_chain(Vector3.ZERO, astronaut.global_position - hatch_world())
	_tether_broken_reported = false


## Debug: fire the ship's engine for 2 s during EVA (to test tether loads).
func debug_ship_kick() -> void:
	_ship_kick = 2.0
	message.emit("Корабль: тяга 2 с")


func _eva_physics(dt: float) -> void:
	if is_surface_eva():
		_update_ground()
		astronaut.up_dir = vessel.pos.normalized().to_v3()
		astronaut.cam_forward = -camera.global_transform.basis.z
		astronaut.physics_tick(dt, Vector3.ZERO)
		_drill_tick(dt)
		if astronaut.oxygen <= 0.0:
			end_eva("Космонавт погиб: кончился кислород")
		return
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

# --- Drill (surface EVA) ------------------------------------------------------------

const DRILL_PERIOD := 0.7   ## seconds per unit pulled at full richness
var drill_held := false
var _drill_acc := 0.0
var _drill_rng := RandomNumberGenerator.new()


## Lat/lon (degrees) of a scene point on the current body.
func lat_lon_at(scene_pos: Vector3) -> Vector2:
	var p := vessel.pos.add(DVec3.from_v3(scene_pos))
	return CelestialBody.lat_lon(vessel.body.inertial_to_fixed(p, sim_time))


func resources_here() -> Dictionary:
	if astronaut == null:
		return {}
	var ll := lat_lon_at(astronaut.global_position)
	return Resources.at(vessel.body.id, ll.x, ll.y)


func _drill_tick(dt: float) -> void:
	var on: bool = drill_held and astronaut.on_ground and astronaut.walk_input.length() < 0.1
	astronaut.drilling = on
	if not on:
		_drill_acc = 0.0
		return
	var r := resources_here()
	var best := 0.0
	for k in r:
		best = maxf(best, float(r[k]))
	_drill_acc += dt * maxf(best, 0.15)
	# Dust and grit thrown up at the bit, every few frames.
	if Engine.get_physics_frames() % 4 == 0:
		var up: Vector3 = astronaut.up_dir
		var bit: Vector3 = astronaut.global_position + (-astronaut.global_transform.basis.z) * 0.6 - up * 0.85
		var at := vessel.pos.add(DVec3.from_v3(bit))
		var d := _rand_dir()
		fx.emit(vessel.body, at, _air_velocity(vessel.body, at).add(DVec3.from_v3((d - up * d.dot(up)) * 1.2 + up * randf_range(0.6, 1.6))),
			randf_range(0.6, 1.2), 0.15, 0.6, _dust_color(vessel.body, 0.7), 0.6 if vessel.body.has_atmosphere() else 0.0,
			not vessel.body.has_atmosphere())
	if _drill_acc < DRILL_PERIOD:
		return
	_drill_acc -= DRILL_PERIOD
	sfx.event("step", -6.0, randf_range(0.6, 0.8))
	var id := Resources.pick(r, _drill_rng)
	if id == "":
		message.emit("Голая скала: здесь ничего не добыть")
		return
	if Game.astro_inv.add(id, 1) > 0:
		drill_held = false
		message.emit("Скафандр полон: перенеси груз в корабль")


## Breathes from an oxygen cylinder in the suit inventory.
func use_oxygen_item() -> String:
	if astronaut == null:
		return "Только при выходе наружу"
	if astronaut.oxygen > astronaut.OXYGEN_MAX - 60.0:
		return "Баллон и так полон"
	if Game.astro_inv.remove("oxygen", 1) == 0 and (not can_transfer_cargo() or Game.ship_inv.remove("oxygen", 1) == 0):
		return "Нет кислорода в скафандре"
	astronaut.oxygen = minf(astronaut.oxygen + Crafting.O2_PER_UNIT, astronaut.OXYGEN_MAX)
	return ""


func _update_eva_camera() -> void:
	# Chase camera behind the astronaut's back, up = astronaut up.
	var b := astronaut.global_transform.basis
	var target := astronaut.global_position + b.y * 0.4
	var cam_pos := target + b.z * eva_cam_dist + b.y * eva_cam_dist * 0.25
	if is_surface_eva():
		# On the ground: orbit camera around the astronaut in the horizon frame
		# (drag on the empty screen turns it), so walking is camera-relative.
		var up: Vector3 = astronaut.up_dir
		var ref := Vector3.UP.cross(up)
		ref = ref.normalized() if ref.length() > 1e-3 else Vector3.RIGHT
		var ref2 := ref.cross(up)
		var horiz := ref2 * cos(cam_yaw) + ref * sin(cam_yaw)
		var pitch := clampf(cam_pitch, -0.2, 1.2)
		target = astronaut.global_position + up * 0.6
		cam_pos = _keep_above_ground(target + (horiz * cos(pitch) + up * sin(pitch)) * eva_cam_dist, 0.6)
		b = Basis(ref, up, ref2)
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


## Absolute point drawn at the scene origin: the vessel, or on the map the focused
## body (so a small moon far from the vessel keeps float precision).
func render_origin() -> DVec3:
	if map_mode and not map_focus_ship and map_focus != null:
		return map_focus.absolute_position(sim_time)
	return vessel_absolute()


## Render position of a body's centre (relative to the render origin).
func body_render_pos(b: CelestialBody) -> Vector3:
	return b.absolute_position(sim_time).sub(render_origin()).to_v3()


## Vessel position in render coordinates (zero unless the map is focused elsewhere).
func ship_render_pos() -> Vector3:
	return vessel_absolute().sub(render_origin()).to_v3()


## Render position of a body at time t (t < 0 = now), relative to the render origin now.
func _body_pos_at(b: CelestialBody, t: float) -> Vector3:
	var tt := sim_time if t < 0.0 else t
	return b.absolute_position(tt).sub(render_origin()).to_v3()


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


## Ambient colour a sunlit body casts on things orbiting low above it (albedo-ish).
const PLANET_SHINE := {
	"earth": Color(0.2, 0.25, 0.34), "moon": Color(0.11, 0.11, 0.11), "mars": Color(0.24, 0.15, 0.1),
	"venus": Color(0.4, 0.37, 0.3), "mercury": Color(0.11, 0.105, 0.1),
	"jupiter": Color(0.3, 0.27, 0.22), "saturn": Color(0.3, 0.28, 0.22),
	"uranus": Color(0.22, 0.3, 0.32), "neptune": Color(0.18, 0.24, 0.36),
}


func _update_sky() -> void:
	var alt := vessel.altitude()
	var up := vessel.pos.normalized().to_v3()
	var dens := body.density_at(alt) / body.sea_level_density if body.has_atmosphere() else 0.0
	var sun_elev := up.dot(sun_dir())
	var daylight := smoothstep(-0.15, 0.2, sun_elev)
	var day := clampf(pow(dens, 0.35), 0.0, 1.0) * daylight
	if map_mode:
		day = 0.0
	sky_mat.set_shader_parameter("day_amount", day)
	sky_mat.set_shader_parameter("local_up", up)
	var sky: Array = SKY_COLORS.get(body.id, SKY_COLORS["earth"])
	sky_mat.set_shader_parameter("day_zenith", sky[0])
	sky_mat.set_shader_parameter("day_horizon", sky[1])
	# Aerial perspective: haze in the air near the ground, coloured like the sky.
	var near_ground := 1.0 - smoothstep(body.scale_height * 0.5, body.scale_height * 3.0, vessel.altitude_above_ground(sim_time))
	var haze: float = sky[2] * near_ground * clampf(dens * 4.0, 0.0, 1.0) if body.has_atmosphere() and not map_mode else 0.0
	env.fog_enabled = haze > 0.0
	if env.fog_enabled:
		env.fog_light_color = (sky[1] as Color) * lerpf(0.15, 1.0, daylight)
		env.fog_density = haze
		env.fog_sky_affect = 0.0
	# Daytime ambient: the sky's own colour (blue on Earth, dusty on Mars).
	var amb_day: Color = (sky[0] as Color).lerp(sky[1], 0.5).lerp(Color(0.6, 0.6, 0.6), 0.45) * 0.55
	var amb := Color(0.06, 0.07, 0.1).lerp(amb_day, day)
	var agl := vessel.altitude_above_ground(sim_time)
	var near := 1.0 - smoothstep(2000.0, 40_000.0, agl)
	var airless_day := 0.0
	if not body.has_atmosphere() and not map_mode:
		# Airless surface in sunlight: no sky light, shadows almost black (as on the
		# Apollo photos); the eye adapts to the bright ground, the stars fade.
		airless_day = near * daylight
		amb = amb.lerp(Color(0.012, 0.012, 0.013), airless_day)
	# Planet-shine in orbit: the sunlit body below fills much of the sky and
	# lights everything from beneath (else a backlit astronaut is pitch black).
	if not map_mode and not body.is_star:
		var r := vessel.pos.length()
		var cover := 1.0 - sqrt(maxf(1.0 - pow(body.radius / r, 2.0), 0.0))
		var space := smoothstep(5000.0, 60_000.0, agl)
		var shine: Color = PLANET_SHINE.get(body.id, Color(0.2, 0.2, 0.2))
		amb += shine * cover * space * smoothstep(-0.2, 0.3, sun_elev)
	env.ambient_light_color = amb
	sky_mat.set_shader_parameter("star_gain", lerpf(1.0, 0.4, airless_day))
	# Camera exposure for a low sun on airless ground (no sky light to help).
	var expo := clampf(0.6 / sqrt(maxf(sun_elev, 0.05)), 1.0, 1.6)
	env.tonemap_exposure = lerpf(1.0, expo, airless_day)
	# No atmosphere: full sunlight (Earth's surface gets ~1.5 after the air).
	sun.light_energy = 2.6 if not body.has_atmosphere() and not body.is_star else 1.5
	# The light does not know about the planet: near the ground after sunset it
	# would shine up through it (lit rocket, glowing slopes). Fade it with the
	# local sun elevation; from orbit the night side is already dark by itself.
	if not map_mode and not body.is_star:
		var ground_w := 1.0 - smoothstep(2000.0, 30_000.0, agl)
		sun.light_energy *= lerpf(1.0, smoothstep(-0.05, 0.03, sun_elev), ground_w)
	# In the planet's shadow (night side of an orbit): no sunlight either.
	if not body.is_star:
		var pv := vessel.pos.to_v3()
		var along := pv.dot(sun_dir())
		if along < 0.0:
			var perp := (pv - sun_dir() * along).length()
			sun.light_energy *= smoothstep(body.radius * 0.995, body.radius * 1.02, perp)
	var full_sun := 2.6 if not body.has_atmosphere() and not body.is_star else 1.5
	rocket.night = 1.0 - smoothstep(0.15, 0.6, sun.light_energy / full_sun)
	if astronaut != null and is_instance_valid(astronaut) and astronaut.model:
		astronaut.model.lamps = rocket.night
	sun.visible = sun.light_energy > 0.001
	# Sun shadows (rocks, rocket, crater walls) only near the ground, high preset.
	var shadows := Graphics.quality == Graphics.HIGH and agl < 3000.0 and not map_mode and not prof_off.has("shadows")
	if shadows != sun.shadow_enabled:
		sun.shadow_enabled = shadows
	_update_reflection_env(up, sun_elev, day, agl)


func _update_sound(delta: float) -> void:
	var alt := vessel.altitude()
	var thr := vessel.last_thrust / maxf(vessel.current_thrust_max(), 1.0) if vessel.last_thrust > 0.0 else 0.0
	var pressure := clampf(vessel.body.pressure_at(alt), 0.0, 1.0) if vessel.body.has_atmosphere() else 0.0
	var sv := vessel.surface_velocity().length()
	var q := 0.5 * vessel.body.density_at(alt) * sv * sv if vessel.body.has_atmosphere() else 0.0
	var turning := not vessel.landed and (vessel.ang_vel - _prev_ang_vel).length() / maxf(delta, 1e-4) > 0.03
	_prev_ang_vel = vessel.ang_vel
	if vessel.landed and not _was_landed and not vessel.destroyed_flag:
		sfx.event("touchdown")
	_was_landed = vessel.landed
	var walk := 0.0
	var ground := false
	var jet := false
	if eva_mode and astronaut:
		var up: Vector3 = astronaut.up_dir
		var v: Vector3 = astronaut.linear_velocity
		walk = (v - up * v.dot(up)).length()
		ground = astronaut.on_ground
		jet = (astronaut.last_thrust as Vector3).length() > 0.01
	sfx.update(delta, thr if not vessel.destroyed_flag else 0.0, pressure, q, turning, eva_mode, walk, ground, jet)


## Global shader environment for metal reflections (hull.gdshader): sky colour
## above, sunlit ground below, local up.
func _update_reflection_env(up: Vector3, sun_elev: float, day: float, agl: float) -> void:
	var sky_lin := Vector3(0.004, 0.005, 0.008)
	if body.has_atmosphere():
		var sky: Array = SKY_COLORS.get(body.id, SKY_COLORS["earth"])
		var c := ((sky[0] as Color).lerp(sky[1], 0.4)).srgb_to_linear()
		sky_lin = sky_lin.lerp(Vector3(c.r, c.g, c.b) * 0.9, day)
	var g := Color(0.35, 0.33, 0.29)
	var pv = planets.get(body)
	if pv != null and pv.has_method("surface_style"):
		var st: Dictionary = pv.surface_style()
		if float(st.albedo) > 0.0:
			g = st.ground
	var gl := g.srgb_to_linear()
	# Lit ground seen from close by; from orbit the planet fills less of the view.
	var near := 1.0 - smoothstep(5000.0, 200_000.0, agl)
	var lit := sun.light_energy * clampf(sun_elev + 0.15, 0.0, 1.0) * lerpf(0.35, 1.0, near)
	RenderingServer.global_shader_parameter_set("env_sky", sky_lin)
	RenderingServer.global_shader_parameter_set("env_ground", Vector3(gl.r, gl.g, gl.b) * lit * 0.8 + sky_lin * 0.3)
	RenderingServer.global_shader_parameter_set("env_up", up)


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
	# Orbit the centre of mass: that is also the point the vessel turns about.
	var center := Basis(vessel.attitude) * Vector3(0, vessel.com_height(), 0)
	var offset := (horiz * cos(cam_pitch) + up * sin(cam_pitch)) * cam_dist
	var cam_pos := _keep_above_ground(center + offset, 2.0)
	camera.global_transform = Transform3D(Basis(), cam_pos).looking_at(center, up)


## Lifts a camera position (scene coordinates) so it stays `clearance` metres above
## the terrain — otherwise the ground is seen from below (it is invisible from there).
func _keep_above_ground(p: Vector3, clearance: float) -> Vector3:
	if map_mode or vessel.altitude_above_ground(sim_time) > 5000.0:
		return p
	var up := vessel.pos.add(DVec3.from_v3(p)).normalized().to_v3()
	var ground := _terrain_point(vessel.pos.add(DVec3.from_v3(p)))
	var h := (p - ground).dot(up)
	return p + up * (clearance - h) if h < clearance else p


var map_focus_ship := true          ## map centred on the rocket (else on map_focus)
var map_pan := Vector3.ZERO         ## two-finger pan offset from the focus point
var _pan_mid := Vector2.ZERO


func _update_map_camera() -> void:
	var center := map_pan   # the focus (ship or body) is the render origin
	var offset := Vector3(
		sin(map_yaw) * cos(map_pitch),
		sin(map_pitch),
		cos(map_yaw) * cos(map_pitch)) * map_dist
	# Depth range follows the zoom (a far plane out to Neptune breaks the depth
	# buffer); what lies beyond ~200 zoom distances is too small to see anyway.
	camera.far = map_dist * 200.0
	camera.near = maxf(map_dist * 0.001, 10.0)
	camera.global_transform = Transform3D(Basis(), center + offset).looking_at(center, Vector3.UP)


func _map_zoom_limits() -> Vector2:
	if map_focus_ship:
		return Vector2(2000.0, 1.0e13)
	return Vector2(map_focus.radius * 1.2, maxf(map_focus.radius * 200.0, 1.0e13 if map_focus.parent == null else map_focus.soi_radius * 3.0))


func toggle_map() -> void:
	map_mode = not map_mode
	rocket.visible = not map_mode and not vessel.destroyed_flag
	if map_mode:
		map_focus = vessel.body
		map_focus_ship = true
		map_pan = Vector3.ZERO
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
func cycle_map_focus(dir := 1) -> void:
	var i := bodies.find(map_focus)
	if map_focus_ship:
		i = bodies.find(vessel.body) - dir   # first press: the body we are at
	map_focus = bodies[posmod(i + dir, bodies.size())]
	map_focus_ship = false
	map_pan = Vector3.ZERO
	map_dist = map_focus.radius * (12.0 if map_focus.parent != null else 80.0)
	if map_focus.parent == root_body:
		map_dist = maxf(map_dist, map_focus.radius * 6.0)


## Map: back to following the rocket.
func focus_map_on_ship() -> void:
	map_focus_ship = true
	map_pan = Vector3.ZERO
	map_focus = vessel.body
	map_dist = maxf(vessel.pos.length() * 3.2, vessel.body.radius * 3.2)


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
			_pan_mid = ((ps[0] as Vector2) + (ps[1] as Vector2)) * 0.5
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
				# Two fingers moving together pan the map (in the screen plane).
				var mid := ((ps[0] as Vector2) + (ps[1] as Vector2)) * 0.5
				var d := mid - _pan_mid
				_pan_mid = mid
				var px := map_dist * 2.0 * tan(deg_to_rad(camera.fov) * 0.5) / maxf(get_viewport().get_visible_rect().size.y, 1.0)
				var b := camera.global_transform.basis
				map_pan += (-b.x * d.x + b.y * d.y) * px
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
