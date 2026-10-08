class_name ApDescent
extends ApTask
## Powered landing on an airless body, started after the deorbit burn.
## Coasts to the low part of the orbit, then steers the thrust vector with two
## loops: horizontal speed is braked to zero, vertical speed follows a profile
## that shrinks with height above the terrain (looking ahead along the track).

enum Phase { COAST, BRAKE, FINAL }

const START_ALT := 9000.0      ## begin braking below this height (or near periapsis)
const TOUCHDOWN_SPEED := 1.2   ## m/s at the surface
const ALIGN_COS := 0.82        ## no thrust until the nose is within ~35° of the command

var phase := Phase.COAST
var _min_fuel_warned := false


func _init() -> void:
	title = "Посадка на двигателях"


func start(_ap: Autopilot, v: Vessel, _t: float) -> void:
	phase = Phase.COAST
	v.sas = true
	v.hold_mode = "retrograde"
	v.throttle = 0.0


func stop(v: Vessel) -> void:
	v.throttle = 0.0


func update(ap: Autopilot, v: Vessel, t: float) -> int:
	var b := v.body
	if v.landed:
		v.throttle = 0.0
		message = "посадка, касание %.1f м/с" % v.touchdown_speed
		return DONE
	if b.has_atmosphere():
		message = "посадка на двигателях — только на тело без атмосферы"
		return FAILED
	auto_stage(v)
	var up := v.pos.normalized().to_v3()
	var vs_vec := v.surface_velocity().to_v3()
	var vs := vs_vec.dot(up)
	var vh_vec := vs_vec - up * vs
	var vh := vh_vec.length()
	var h := _height(v, t, vh_vec)

	if phase == Phase.COAST:
		v.throttle = 0.0
		v.hold_mode = "retrograde"
		var el := OrbitMath.elements(v.pos, v.vel, b.mu)
		var to_peri := Planner.time_to_anomaly(el, 0.0) if el.e < 1.0 else 0.0
		if el.periapsis - b.radius > START_ALT * 2.0:
			message = "перицентр слишком высоко (%.0f км) — нужен сход с орбиты" % ((el.periapsis - b.radius) / 1000.0)
			return FAILED
		status = "снижение к началу торможения, высота %s" % ApCoast._km(h)
		if h < START_ALT or to_peri < 60.0 or v.vel.dot(v.pos) > 0.0 and to_peri > 0.5 * TAU * sqrt(pow(el.a, 3) / b.mu) - 5.0:
			phase = Phase.BRAKE
			ap.wants_warp_reset = true
			print("[I] Descent: braking from h=%.0f m, vh=%.0f, vs=%.0f" % [h, vh, vs])
		else:
			ap.requested_warp = warp_for(minf(to_peri - 60.0, 1.0e6))
		return RUNNING

	ap.requested_warp = 1
	if not v.has_fuel():
		v.throttle = 0.0
		message = "кончилось топливо на высоте %d м" % int(h)
		return FAILED
	if phase == Phase.BRAKE and vh < 3.0 and h < 300.0:
		phase = Phase.FINAL

	var r := v.pos.length()
	var g_eff := b.mu / (r * r) - vh * vh / r     # gravity minus "orbital" relief
	var a_max := v.current_thrust_max() / v.mass()

	# Vertical speed target from the height above the terrain.
	var vs_target := -clampf(h * 0.12, TOUCHDOWN_SPEED, 45.0)
	if vh > 30.0:
		vs_target = -clampf(h / 60.0, 3.0, 40.0)
	if vh > 4.0 and h < 200.0:
		vs_target = maxf(vs_target, 0.5 if h < 60.0 else -1.0)   # kill the drift before going lower
	var a_v := g_eff + 0.8 * (vs_target - vs)
	a_v = clampf(a_v, 0.0, a_max * 0.98)
	# Horizontal: brake whatever is left with the remaining thrust.
	var a_h_want := vh * (0.8 if phase == Phase.FINAL else 2.0)
	var a_h := minf(a_h_want, sqrt(maxf(a_max * a_max - a_v * a_v, 0.0)))
	var cmd := up * a_v
	if vh > 0.05:
		cmd -= vh_vec / vh * a_h
	var a_cmd := cmd.length()
	v.hold_mode = "target"
	v.target_dir = cmd / a_cmd if a_cmd > 1e-3 else up
	if phase == Phase.FINAL and a_cmd < 1e-3:
		v.target_dir = up
	# Only push when the nose points roughly where we want.
	var align := v.up_world().dot(v.target_dir)
	v.throttle = clampf(a_cmd / maxf(a_max, 1e-3), 0.0, 1.0) if align > ALIGN_COS else 0.0
	if phase == Phase.BRAKE:
		status = "торможение: %d м/с вбок, %d м/с вниз, высота %s" % [int(vh), int(-vs), ApCoast._km(h)]
	else:
		status = "вертикальный спуск: %.1f м/с, высота %d м" % [-vs, int(h)]
	return RUNNING


## Height above the terrain, taking the highest ground along the track ahead
## (where we will be in the next ~40 s at the current horizontal speed).
func _height(v: Vessel, t: float, vh_vec: Vector3) -> float:
	var b := v.body
	var alt := v.altitude() - v.height_offset
	var ground := v.ground_height(t)
	if vh_vec.length() > 5.0:
		for dt in [5.0, 12.0, 25.0, 40.0]:
			var ahead := v.pos.add(DVec3.from_v3(vh_vec * dt))
			var gh := b.surface_height(b.inertial_to_fixed(ahead, t + dt))
			# Weight the far samples less: they matter only while we are fast and high.
			ground = maxf(ground, gh - dt * 2.0)
	return alt - ground
