extends Node3D
## Flight scene controller: owns simulation time, time warp, the active vessel,
## floating origin (vessel always at the scene origin), cameras and map mode.

const PlanetView := preload("res://scripts/flight/planet_view.gd")
const RocketView := preload("res://scripts/flight/rocket_view.gd")
const OrbitLine := preload("res://scripts/flight/orbit_line.gd")
const HudScript := preload("res://scripts/flight/flight_hud.gd")
const SKY_SHADER := preload("res://shaders/starfield.gdshader")

const DT := 1.0 / 60.0
const WARPS: Array[int] = [1, 2, 4, 10, 50, 100, 1000, 10000]
const PHYSICS_WARP_MAX := 4
const SUN_DIR := Vector3(0.62, 0.35, 0.7)   ## towards the sun, inertial

signal message(text: String)

var body: CelestialBody
var vessel: Vessel
var sim_time := 0.0
var warp_index := 0
var map_mode := false

var planet: Node3D
var rocket: Node3D
var orbit_line: Node3D
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

var _debris: Array[Dictionary] = []
var _touches := {}
var _pinch_start := 0.0
var _pinch_dist0 := 0.0


func _ready() -> void:
	body = SolarSystem.earth()
	_set_morning_at_site()
	_build_environment()
	planet = PlanetView.new()
	add_child(planet)
	planet.setup(body, SolarSystem.LAUNCH_LAT, SolarSystem.LAUNCH_LON, SUN_DIR.normalized())
	rocket = RocketView.new()
	add_child(rocket)
	orbit_line = OrbitLine.new()
	add_child(orbit_line)
	camera = Camera3D.new()
	camera.near = 0.3
	camera.far = 3.0e7
	camera.fov = 60.0
	add_child(camera)
	camera.make_current()
	hud = HudScript.new()
	hud.flight = self
	add_child(hud)
	reset_to_pad()
	Log.info("Flight: scene ready, body=%s R=%.0f m g=%.2f" % [body.name, body.radius, body.surface_gravity()])


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
	body.rotation_offset = best


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
	for d in _debris:
		d.node.queue_free()
	_debris.clear()
	var inf_fuel := vessel.infinite_fuel if vessel else false
	vessel = Vessel.default_rocket(body)
	vessel.infinite_fuel = inf_fuel
	vessel.staged.connect(_on_staged)
	vessel.destroyed.connect(_on_destroyed)
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
		"life": 25.0,
	})
	Log.info("Flight: stage separated, %d stage(s) left" % vessel.stages.size())


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
	if WARPS[i] > PHYSICS_WARP_MAX and not vessel.can_rails_warp():
		var why := "двигатель работает" if vessel.throttle > 0.0 else "в атмосфере"
		message.emit("Ускорение > %dx недоступно: %s" % [PHYSICS_WARP_MAX, why])
		i = WARPS.find(PHYSICS_WARP_MAX)
	warp_index = i


# --- Main loop -----------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if is_rails():
		if not vessel.can_rails_warp():
			set_warp(WARPS.find(PHYSICS_WARP_MAX))
		else:
			var step := DT * warp()
			vessel.rails_step(step, sim_time)
			sim_time += step
			if not vessel.landed and vessel.altitude() < body.atmosphere_height:
				message.emit("Вход в атмосферу — ускорение времени сброшено")
				set_warp(0)
			_step_debris(step)
			return
	for _k in warp():
		vessel.step(DT, sim_time)
		sim_time += DT
	_step_debris(DT * warp())


func _step_debris(dt: float) -> void:
	for i in range(_debris.size() - 1, -1, -1):
		var d: Dictionary = _debris[i]
		d.life -= dt
		var p: DVec3 = d.pos
		var r2 := p.length_squared()
		var acc := p.mul(-body.mu / (r2 * sqrt(r2)))
		var v: DVec3 = d.vel
		v.add_scaled(acc, dt)
		var alt := sqrt(r2) - body.radius
		var rho := body.density_at(alt)
		if rho > 0.0:
			v.add_scaled(v, -minf(rho * v.length() * 0.0004 * dt, 0.5))
		p.add_scaled(v, dt)
		if d.life <= 0.0 or alt < 0.0:
			(d.node as Node3D).queue_free()
			_debris.remove_at(i)


func _process(delta: float) -> void:
	# Floating origin: vessel at 0; everything else relative to it in doubles.
	var planet_rel := vessel.pos.mul(-1.0)
	planet.update_view(planet_rel, sim_time)
	orbit_line.position = planet_rel.to_v3()
	rocket.basis = Basis(vessel.attitude)
	rocket.update_visual(delta)
	for d in _debris:
		var n: Node3D = d.node
		n.global_transform = Transform3D(d.basis, (d.pos as DVec3).sub(vessel.pos).to_v3())

	_update_sky()
	if map_mode:
		_update_map_camera()
	else:
		_update_flight_camera()
	orbit_line.visible = map_mode
	if map_mode:
		var el := OrbitMath.elements(vessel.pos, vessel.vel, body.mu)
		orbit_line.rebuild(el, body, vessel.pos, camera.global_position.distance_to(orbit_line.global_position))


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
	# Keep far/near sane for depth precision and culling: far just covers the planet.
	camera.near = 0.5
	camera.far = vessel.pos.length() + body.radius * 1.05
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
	camera.far = map_dist + body.radius * 2.0 + vessel.pos.length()
	camera.near = maxf(map_dist * 0.001, 10.0)
	var center := orbit_line.position
	var offset := Vector3(
		sin(map_yaw) * cos(map_pitch),
		sin(map_pitch),
		cos(map_yaw) * cos(map_pitch)) * map_dist
	camera.global_transform = Transform3D(Basis(), center + offset).looking_at(center, Vector3.UP)


func toggle_map() -> void:
	map_mode = not map_mode
	rocket.visible = not map_mode and not vessel.destroyed_flag
	if map_mode:
		map_dist = maxf(vessel.pos.length() * 3.0, body.radius * 3.0)
		var p := vessel.pos.to_v3().normalized()
		map_yaw = atan2(p.x, p.z)
		map_pitch = 0.6


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
			_pinch_start = map_dist if map_mode else cam_dist
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			var rel: Vector2 = event.relative * 0.006
			if map_mode:
				map_yaw -= rel.x
				map_pitch = clampf(map_pitch + rel.y, -1.45, 1.45)
			else:
				cam_yaw -= rel.x
				cam_pitch = clampf(cam_pitch + rel.y, -1.45, 1.45)
		elif _touches.size() == 2 and _pinch_dist0 > 0.0:
			var ps: Array = _touches.values()
			var dnow := (ps[0] as Vector2).distance_to(ps[1])
			var k := _pinch_dist0 / maxf(dnow, 1.0)
			if map_mode:
				map_dist = clampf(_pinch_start * k, body.radius * 1.2, body.radius * 60.0)
			else:
				cam_dist = clampf(_pinch_start * k, 8.0, 2000.0)
	elif event is InputEventMouseButton and event.pressed:
		# Desktop testing: wheel zoom.
		var f := 0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else (1.1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 1.0)
		if map_mode:
			map_dist = clampf(map_dist * f, body.radius * 1.2, body.radius * 60.0)
		else:
			cam_dist = clampf(cam_dist * f, 8.0, 2000.0)


func zoom(f: float) -> void:
	if map_mode:
		map_dist = clampf(map_dist * f, body.radius * 1.2, body.radius * 60.0)
	else:
		cam_dist = clampf(cam_dist * f, 8.0, 2000.0)
