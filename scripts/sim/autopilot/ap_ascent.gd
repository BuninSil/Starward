class_name ApAscent
extends ApTask
## Ascent to a circular orbit: vertical climb -> gravity turn east -> coast to
## apoapsis -> horizon-hold circularization, with auto-staging.

enum Phase { VERTICAL, TURN, COAST, CIRCULARIZE }

const PHASE_NAMES := {
	Phase.VERTICAL: "вертикальный подъём",
	Phase.TURN: "гравитационный разворот",
	Phase.COAST: "полёт к апоцентру",
	Phase.CIRCULARIZE: "скругление орбиты",
}

var target_altitude := 20_000.0
var phase := Phase.VERTICAL
var turn_end_fraction := 0.75   ## turn ends at this fraction of the target altitude
var vertical_until := 400.0
## Optional orbit plane (inertial normal) to launch into instead of due east.
var plane_normal := Vector3.ZERO


func _init(alt := 20_000.0) -> void:
	target_altitude = alt
	title = "Выход на орбиту %d км" % int(alt / 1000.0)


func start(_ap: Autopilot, v: Vessel, _t: float) -> void:
	phase = Phase.VERTICAL if v.landed or v.altitude() < v.body.atmosphere_height else Phase.COAST
	v.sas = true
	v.hold_mode = "target"
	v.target_dir = v.pos.normalized().to_v3()


func stop(v: Vessel) -> void:
	v.throttle = 0.0


func update(ap: Autopilot, v: Vessel, _t: float) -> int:
	var b := v.body
	var alt := v.altitude()
	var up := v.pos.normalized().to_v3()
	var east := Vector3.UP.cross(up)
	east = east.normalized() if east.length() > 1e-6 else Vector3.RIGHT
	if plane_normal != Vector3.ZERO:
		# Heading along the wanted plane (prograde in it) from this site.
		var hd := plane_normal.cross(up)
		if hd.length() > 1e-3:
			east = hd.normalized()
	var el := OrbitMath.elements(v.pos, v.vel, b.mu)
	var apo_alt: float = el.apoapsis - b.radius
	var peri_alt: float = el.periapsis - b.radius
	status = PHASE_NAMES[phase]
	ap.requested_warp = 1
	auto_stage(v)

	match phase:
		Phase.VERTICAL:
			v.hold_mode = "target"
			v.target_dir = up
			v.throttle = 1.0
			if alt > vertical_until:
				phase = Phase.TURN
		Phase.TURN:
			var turn_end := target_altitude * turn_end_fraction
			var f := clampf((alt - vertical_until) / (turn_end - vertical_until), 0.0, 1.0)
			var pitch := deg_to_rad(85.0) * pow(f, 0.55)   # angle from vertical
			v.hold_mode = "target"
			v.target_dir = (up * cos(pitch) + east * sin(pitch)).normalized()
			v.throttle = 1.0
			# Overshoot a little: the horizon-hold circularization trims apoapsis.
			var vs_turn := v.vel.to_v3().dot(up)
			if apo_alt >= target_altitude * 1.12:
				v.throttle = 0.0
				phase = Phase.COAST
			elif apo_alt >= target_altitude * 0.97 and vs_turn < 25.0 and alt > b.atmosphere_height:
				# Strong rocket: already at the target height and flying level —
				# circularize right here instead of sagging back down.
				phase = Phase.CIRCULARIZE
		Phase.COAST:
			v.throttle = 0.0
			v.hold_mode = "prograde"
			var tta := Planner.time_to_anomaly(el, PI) if el.e < 1.0 else 0.0
			var burn := _circularize_burn_time(v, el)
			if alt > b.atmosphere_height and tta > burn * 0.5 + 20.0:
				ap.requested_warp = warp_for(tta - burn * 0.5 - 20.0)
			elif tta < burn * 0.5 + 15.0:
				ap.wants_warp_reset = true
			if tta <= burn * 0.5 or v.vel.dot(v.pos) < 0.0:
				phase = Phase.CIRCULARIZE
				ap.wants_warp_reset = true
			elif alt < b.atmosphere_height and apo_alt < target_altitude * 0.97:
				v.hold_mode = "target"
				v.target_dir = (v.vel.normalized().to_v3() + up * 0.15).normalized()
				v.throttle = 0.5
		Phase.CIRCULARIZE:
			var horiz := v.vel.to_v3() - up * v.vel.to_v3().dot(up)
			horiz = horiz.normalized() if horiz.length() > 1e-3 else east
			var vs := v.vel.to_v3().dot(up)
			# Hold near the apoapsis, but never chase it above the target.
			var hold_alt := maxf(minf(apo_alt, target_altitude * 1.05), b.atmosphere_height * 1.1)
			# Vertical acceleration needed: gravity minus centrifugal relief, plus a
			# soft altitude/vertical-speed hold; the pitch gives it from the thrust.
			var r := v.pos.length()
			var vh2 := (v.vel.to_v3() - up * vs).length_squared()
			var a_need := b.mu / (r * r) - vh2 / r + (hold_alt - alt) * 0.004 - vs * 0.15
			var a_thr := maxf(v.current_thrust_max() / v.mass(), 0.1)
			var pitch_up := asin(clampf(a_need / a_thr, -0.35, 0.9))
			v.hold_mode = "target"
			v.target_dir = (horiz * cos(pitch_up) + up * sin(pitch_up)).normalized()
			v.throttle = 1.0
			var overshoot: bool = apo_alt > target_altitude * 1.5 and peri_alt > maxf(b.atmosphere_height, target_altitude * 0.5)
			if peri_alt >= target_altitude * 0.95 or (el.e < 0.003 and peri_alt > b.atmosphere_height) or overshoot:
				v.throttle = 0.0
				message = "орбита %.1f × %.1f км" % [apo_alt / 1000.0, peri_alt / 1000.0]
				return DONE
			elif not v.has_fuel() and v.stages.size() <= 2:
				v.throttle = 0.0
				if peri_alt > b.atmosphere_height:
					message = "топливо кончилось, перицентр %.1f км" % (peri_alt / 1000.0)
					return DONE
				message = "не хватило топлива для орбиты"
				return FAILED
	return RUNNING


func _circularize_burn_time(v: Vessel, el: Dictionary) -> float:
	var b := v.body
	var ra: float = el.apoapsis
	if is_inf(ra):
		return 0.0
	var a: float = el.a
	var v_apo := sqrt(maxf(b.mu * (2.0 / ra - 1.0 / a), 0.0))
	var dv := maxf(sqrt(b.mu / ra) - v_apo, 0.0)
	return ManeuverNode.burn_time(v, dv)
