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
## Landing target (a base's landing pad): lat/lon in degrees; none = anywhere.
var has_target := false
var target_lat := 0.0
var target_lon := 0.0
var miss := INF   ## horizontal distance to the target at touchdown, m


func _init(lat := INF, lon := INF, name := "") -> void:
	title = "Посадка на двигателях"
	if lat != INF:
		has_target = true
		target_lat = lat
		target_lon = lon
		title = "Посадка на %s" % name if name != "" else "Посадка в точку"


## Horizontal vector from the craft to the target (inertial, in the local
## horizontal plane).
func _to_target(v: Vessel, t: float, up: Vector3) -> Vector3:
	var b := v.body
	var f := CelestialBody.surface_normal(target_lat, target_lon)
	var site := b.fixed_to_inertial(f.mul(b.radius + b.surface_height(f)), t)
	var d := site.sub(v.pos).to_v3()
	return d - up * d.dot(up)


## Distance to the target along the ground track (arc, m), forward in the
## direction of motion; negative when it is behind.
func _arc_to_target(v: Vessel, t: float) -> float:
	var b := v.body
	var site := b.fixed_to_inertial(CelestialBody.surface_normal(target_lat, target_lon), t)
	var p := v.pos.normalized()
	var hn := v.pos.cross(v.surface_velocity()).normalized()
	var ang := atan2(p.cross(site).dot(hn), p.dot(site))
	return ang * b.radius


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
		if has_target:
			miss = _to_target(v, t, v.pos.normalized().to_v3()).length()
			message = "посадка в %d м от цели, касание %.1f м/с" % [int(miss), v.touchdown_speed]
		else:
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
		var go := h < START_ALT or to_peri < 60.0 or v.vel.dot(v.pos) > 0.0 and to_peri > 0.5 * TAU * sqrt(pow(el.a, 3) / b.mu) - 5.0
		if has_target:
			# Start braking when the stopping distance reaches the target.
			var along := _arc_to_target(v, t)
			var a_dec := 0.55 * v.current_thrust_max() / maxf(v.mass(), 1.0)
			var need := vh * vh / (2.0 * maxf(a_dec, 0.3))
			status = "до цели %s, торможение через %s" % [ApCoast._km(along), ApCoast._km(maxf(along - need, 0.0))]
			go = (along <= need * 1.08 and along > -need) or h < 2500.0
		if go:
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
	var r := v.pos.length()
	var g_eff := b.mu / (r * r) - vh * vh / r     # gravity minus "orbital" relief
	var a_max := v.current_thrust_max() / v.mass()

	# Target: horizontal velocity wanted to arrive over the pad and stop there.
	var tt := Vector3.ZERO
	var rng := 0.0
	if has_target:
		tt = _to_target(v, t, up)
		rng = tt.length()
		if rng > 5000.0:
			# Far: the straight line cuts under the curve; use the arc length.
			rng = maxf(absf(_arc_to_target(v, t)), rng)
		if phase == Phase.BRAKE and rng < 25.0 and vh < 3.0 and h < 300.0:
			phase = Phase.FINAL
		elif phase == Phase.FINAL and rng > 60.0:
			phase = Phase.BRAKE
	elif phase == Phase.BRAKE and vh < 3.0 and h < 300.0:
		phase = Phase.FINAL
	# Vertical speed target from the height above the terrain.
	var vs_target := -clampf(h * 0.12, TOUCHDOWN_SPEED, 45.0)
	if vh > 30.0:
		vs_target = -clampf(h / 60.0, 3.0, 40.0)
	if vh > 4.0 and h < 200.0:
		vs_target = maxf(vs_target, 0.5 if h < 60.0 else -1.0)   # kill the drift before going lower
	if has_target and rng > 120.0 and h < 350.0:
		vs_target = maxf(vs_target, (220.0 - h) * 0.05)   # stay clear of the ground while flying over
	var a_v := g_eff + 0.8 * (vs_target - vs)
	a_v = clampf(a_v, 0.0, a_max * 0.98)
	var a_h_room := sqrt(maxf(a_max * a_max - a_v * a_v, 0.0))
	var cmd := up * a_v
	if has_target:
		# Follow a braking curve to the pad: v_wanted = sqrt(2 a d) toward it,
		# which also takes out the cross-track drift.
		var dir := tt / rng if rng > 0.01 else Vector3.ZERO
		var a_dec := 0.55 * a_max
		var v_want := sqrt(2.0 * a_dec * maxf(rng - 3.0, 0.0))
		if phase == Phase.FINAL:
			v_want = minf(0.25 * rng, 2.5)
		elif vh < 80.0:
			v_want = minf(v_want, 40.0)
		var a_hv := (dir * v_want - vh_vec) * (1.0 if phase == Phase.FINAL else 1.4)
		if a_hv.length() > a_h_room:
			a_hv = a_hv.normalized() * a_h_room
		cmd += a_hv
	else:
		# Horizontal: brake whatever is left with the remaining thrust.
		var a_h_want := vh * (0.8 if phase == Phase.FINAL else 2.0)
		var a_h := minf(a_h_want, a_h_room)
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
	if has_target:
		status = "к цели %s · %d м/с вбок · высота %s" % [ApCoast._km(rng), int(vh), ApCoast._km(h)]
	elif phase == Phase.BRAKE:
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
