class_name Vessel
extends RefCounted
## Rigid rocket as a point mass with attitude. Inertial state (DVec3) relative to the
## centre of the current SOI body. Stage 0 is the top (capsule side), stages are
## dropped from the end of the array.

signal staged(dropped: Dictionary)
signal destroyed(reason: String)
signal landed_changed(landed: bool)

const SAS_ACCEL := 1.2          ## rad/s^2 max angular acceleration from control
const CRASH_SPEED := 12.0       ## m/s impact speed that destroys the craft
const STAGE_SEPARATION_DV := 1.5

var body: CelestialBody
var pos := DVec3.new()          ## inertial, body-centred
var vel := DVec3.new()
var attitude := Quaternion.IDENTITY   ## rocket +Y = nose
var ang_vel := Vector3.ZERO           ## rad/s, world frame

var throttle := 0.0
var infinite_fuel := false
var landed := true
var destroyed_flag := false
var height_offset := 0.0        ## distance from vessel origin to its lowest point

## Each stage: {name, dry_mass, fuel, fuel_max, thrust_vac, isp_sl, isp_vac,
##              diameter, length, has_engine}
var stages: Array[Dictionary] = []

# Attitude input (-1..1) and hold mode.
var input_pitch := 0.0
var input_yaw := 0.0
var input_roll := 0.0
var sas := true
var hold_mode := ""   ## "", prograde, retrograde, normal, antinormal, radial_out, radial_in, target
var target_dir := Vector3.UP   ## world direction for hold_mode "target" (autopilot)

# Telemetry from the last step.
var last_thrust := 0.0
var last_drag := 0.0
var last_g := 0.0


func mass() -> float:
	var m := 0.0
	for s in stages:
		m += s.dry_mass + s.fuel
	return m


func active_stage() -> Dictionary:
	return stages[stages.size() - 1] if not stages.is_empty() else {}


func altitude() -> float:
	return pos.length() - body.radius


## Velocity relative to the rotating atmosphere / surface.
func surface_velocity() -> DVec3:
	var omega := DVec3.new(0, body.angular_velocity(), 0)
	return vel.sub(omega.cross(pos))


func up_world() -> Vector3:
	return attitude * Vector3.UP


func current_isp(stage: Dictionary) -> float:
	var p := clampf(body.pressure_at(altitude()) / maxf(body.sea_level_pressure, 1e-6), 0.0, 1.0)
	return lerpf(stage.isp_vac, stage.isp_sl, p)


func current_thrust_max() -> float:
	var s := active_stage()
	if s.is_empty() or not s.has_engine:
		return 0.0
	# Fixed mass flow: thrust scales with Isp.
	return s.thrust_vac * current_isp(s) / s.isp_vac


func has_fuel() -> bool:
	var s := active_stage()
	return not s.is_empty() and s.has_engine and (s.fuel > 0.0 or infinite_fuel)


## Delta-v per stage (top..bottom order as in `stages`) at current pressure.
func stage_delta_v() -> Array[float]:
	var out: Array[float] = []
	var above := 0.0
	for i in stages.size():
		var s := stages[i]
		var m_full: float = above + s.dry_mass + s.fuel
		var m_dry: float = above + s.dry_mass
		var dv := 0.0
		if s.has_engine and s.fuel > 0.0:
			dv = current_isp(s) * SolarSystem.G0 * log(m_full / m_dry)
		out.append(dv)
		above += s.dry_mass + s.fuel
	return out


func total_delta_v() -> float:
	var t := 0.0
	for dv in stage_delta_v():
		t += dv
	return t


func twr() -> float:
	var g := body.mu / pos.length_squared()
	return current_thrust_max() / (mass() * g)


## Drops the bottom stage. Returns false if only one stage left.
func stage() -> bool:
	if stages.size() <= 1 or destroyed_flag:
		return false
	var dropped: Dictionary = stages.pop_back()
	# Small separation kick along the nose.
	var kick := up_world() * STAGE_SEPARATION_DV
	vel.add_scaled(DVec3.from_v3(kick), 1.0)
	staged.emit(dropped)
	return true


# --- Simulation ---------------------------------------------------------------

## One physics step of dt seconds at time t (time after the step is t + dt).
func step(dt: float, t: float) -> void:
	if destroyed_flag:
		return
	_step_attitude(dt)

	var m := mass()
	var s := active_stage()
	var thrust := 0.0
	if throttle > 0.0 and has_fuel():
		thrust = current_thrust_max() * throttle
		var mdot := thrust / (current_isp(s) * SolarSystem.G0)
		if not infinite_fuel:
			var burn := minf(mdot * dt, s.fuel)
			s.fuel -= burn
	last_thrust = thrust

	if landed:
		if thrust / m <= body.mu / pos.length_squared() * 1.0001:
			_stick_to_surface(t + dt)
			ang_vel = Vector3.ZERO
			last_drag = 0.0
			return
		_set_landed(false)

	# Velocity Verlet with forces evaluated at both ends (thrust/drag treated as
	# constant over the step).
	var a0 := _accel(pos, vel, thrust, m)
	pos.add_scaled(vel, dt)
	pos.add_scaled(a0, 0.5 * dt * dt)
	var a1 := _accel(pos, vel, thrust, m)
	vel.add_scaled(a0.add(a1), 0.5 * dt)

	_check_ground(t + dt)


func _accel(p: DVec3, v: DVec3, thrust: float, m: float) -> DVec3:
	var r2 := p.length_squared()
	var r := sqrt(r2)
	var a := p.mul(-body.mu / (r2 * r))
	last_g = body.mu / r2
	if thrust > 0.0:
		a.add_scaled(DVec3.from_v3(up_world()), thrust / m)
	var rho := body.density_at(r - body.radius)
	last_drag = 0.0
	if rho > 0.0:
		var omega := DVec3.new(0, body.angular_velocity(), 0)
		var vrel := v.sub(omega.cross(p))
		var sp := vrel.length()
		if sp > 0.01:
			var area := PI * pow(_max_diameter() * 0.5, 2)
			var drag := 0.5 * rho * sp * sp * 0.5 * area
			last_drag = drag
			a.add_scaled(vrel, -drag / (m * sp))
	return a


func _max_diameter() -> float:
	var d := 0.0
	for s in stages:
		d = maxf(d, s.diameter)
	return d


func _step_attitude(dt: float) -> void:
	var has_input := absf(input_pitch) + absf(input_yaw) + absf(input_roll) > 0.01
	var accel := Vector3.ZERO
	if has_input:
		# Local axes: pitch about X, yaw about Z, roll about Y (nose).
		var local := Vector3(input_pitch, input_roll, -input_yaw) * SAS_ACCEL
		accel = attitude * local
	elif hold_mode != "" and not landed:
		var target := hold_direction()
		if target != Vector3.ZERO:
			var up := up_world()
			var axis := up.cross(target)
			var angle := asin(clampf(axis.length(), 0.0, 1.0))
			if up.dot(target) < 0.0:
				angle = PI - angle
			if axis.length() < 1e-6:
				axis = attitude * Vector3.RIGHT
			# PD: aim, and damp everything (incl. roll).
			var desired := axis.normalized() * angle * 2.0 - ang_vel * 2.5
			accel = desired.limit_length(SAS_ACCEL)
	elif sas:
		accel = (-ang_vel / maxf(dt, 1e-4)).limit_length(SAS_ACCEL)
	ang_vel += accel * dt
	if landed:
		ang_vel = Vector3.ZERO
	var w := ang_vel.length()
	if w > 1e-9:
		attitude = (Quaternion(ang_vel / w, w * dt) * attitude).normalized()


func hold_direction() -> Vector3:
	var prograde := (vel.normalized()).to_v3()
	if altitude() < body.atmosphere_height * 0.5:
		prograde = surface_velocity().normalized().to_v3()
	var radial := pos.normalized().to_v3()
	var normal := pos.cross(vel).normalized().to_v3()
	match hold_mode:
		"prograde": return prograde
		"retrograde": return -prograde
		"normal": return normal
		"antinormal": return -normal
		"radial_out": return radial
		"radial_in": return -radial
		"target": return target_dir.normalized()
	return Vector3.ZERO


# --- Surface ------------------------------------------------------------------

var _surface_fixed := DVec3.new()   ## body-fixed position while landed


func place_on_surface(lat_deg: float, lon_deg: float, t: float) -> void:
	var n := CelestialBody.surface_normal(lat_deg, lon_deg)
	_surface_fixed = n.mul(body.radius + height_offset)
	_set_landed(true)
	destroyed_flag = false
	_stick_to_surface(t)
	# Nose along local vertical.
	var up := body.fixed_to_inertial(n, t).to_v3()
	attitude = Quaternion(Vector3.UP, up).normalized()
	ang_vel = Vector3.ZERO


func _stick_to_surface(t: float) -> void:
	pos = body.fixed_to_inertial(_surface_fixed, t)
	var omega := DVec3.new(0, body.angular_velocity(), 0)
	vel = omega.cross(pos)


func _check_ground(t: float) -> void:
	var alt := altitude() - height_offset
	if alt > 0.0:
		return
	var vs := surface_velocity()
	var speed := vs.length()
	if speed > CRASH_SPEED:
		destroyed_flag = true
		throttle = 0.0
		var radial := pos.normalized()
		var v_vert := vs.dot(radial)
		var v_horiz := sqrt(maxf(speed * speed - v_vert * v_vert, 0.0))
		var path_angle := rad_to_deg(atan2(-v_vert, v_horiz))   # 90 = straight down
		var nose_angle := rad_to_deg(up_world().angle_to(radial.to_v3()))  # 0 = nose up
		destroyed.emit("Удар о поверхность: %d м/с (вниз %d, вбок %d), угол падения %d°, нос от вертикали %d°, газ %d%%, ступеней %d" % [
			int(speed), int(-v_vert), int(v_horiz), int(path_angle), int(nose_angle),
			int(last_thrust > 0.0) * 100, stages.size()])
		_surface_fixed = body.inertial_to_fixed(pos.normalized().mul(body.radius + height_offset), t)
		_stick_to_surface(t)
		return
	_surface_fixed = body.inertial_to_fixed(pos.normalized().mul(body.radius + height_offset), t)
	_set_landed(true)
	_stick_to_surface(t)


func _set_landed(v: bool) -> void:
	if landed != v:
		landed = v
		landed_changed.emit(v)


# --- Time warp on rails ---------------------------------------------------------

func can_rails_warp() -> bool:
	if destroyed_flag:
		return true
	if landed:
		return throttle == 0.0
	return throttle == 0.0 and altitude() > body.atmosphere_height


## Advances the state analytically by dt (no thrust, no drag).
func rails_step(dt: float, t: float) -> void:
	if landed or destroyed_flag:
		_stick_to_surface(t + dt)
		return
	var rv := OrbitMath.propagate(pos, vel, body.mu, dt)
	pos = rv[0]
	vel = rv[1]
	ang_vel = Vector3.ZERO
	if altitude() < body.atmosphere_height:
		# Entered the atmosphere during warp; caller drops warp to 1x.
		pass
	_check_ground(t + dt)


# --- Prebuilt rocket ------------------------------------------------------------

static func make_stage(name: String, dry: float, fuel: float, thrust: float,
		isp_sl: float, isp_vac: float, diameter: float, length: float) -> Dictionary:
	return {
		"name": name, "dry_mass": dry, "fuel": fuel, "fuel_max": fuel,
		"thrust_vac": thrust, "isp_sl": isp_sl, "isp_vac": isp_vac,
		"diameter": diameter, "length": length, "has_engine": thrust > 0.0,
	}


## Two-stage rocket for stage 1 of the game: ~4.4 km/s total, TWR ~1.5 at liftoff.
static func default_rocket(b: CelestialBody) -> Vessel:
	var v := Vessel.new()
	v.body = b
	v.stages = [
		make_stage("Капсула", 1200.0, 0.0, 0.0, 1.0, 1.0, 1.8, 2.2),
		make_stage("Вторая ступень", 800.0, 2000.0, 60_000.0, 300.0, 340.0, 2.0, 4.0),
		make_stage("Первая ступень", 2500.0, 9000.0, 270_000.0, 280.0, 310.0, 2.5, 9.0),
	]
	v.height_offset = 0.0
	return v
