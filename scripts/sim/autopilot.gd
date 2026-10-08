class_name Autopilot
extends RefCounted
## Ascent autopilot: flies the vessel to a circular orbit using only the normal
## controls (attitude hold toward a direction, throttle, staging). Phases:
## vertical climb -> gravity turn east -> coast to apoapsis -> circularize.

signal finished(success: bool, message: String)

enum Phase { IDLE, VERTICAL, TURN, COAST, CIRCULARIZE, DONE }

const PHASE_NAMES := {
	Phase.IDLE: "выключен",
	Phase.VERTICAL: "вертикальный подъём",
	Phase.TURN: "гравитационный разворот",
	Phase.COAST: "полёт к апоцентру",
	Phase.CIRCULARIZE: "скругление орбиты",
	Phase.DONE: "орбита достигнута",
}

var target_altitude := 20_000.0
var phase := Phase.IDLE
var wants_warp_reset := false   ## flight controller drops time warp to 1x when set

## Altitude where the turn ends (fraction of the target orbit altitude).
var turn_end_fraction := 0.75
var vertical_until := 400.0     ## m


func active() -> bool:
	return phase != Phase.IDLE and phase != Phase.DONE


func status() -> String:
	return PHASE_NAMES.get(phase, "")


func engage(v: Vessel, altitude: float) -> void:
	target_altitude = altitude
	phase = Phase.VERTICAL if v.landed or v.altitude() < v.body.atmosphere_height else Phase.COAST
	v.sas = true
	v.hold_mode = "target"
	v.target_dir = v.pos.normalized().to_v3()


func disengage(v: Vessel) -> void:
	if phase == Phase.IDLE:
		return
	phase = Phase.IDLE
	if v.hold_mode == "target":
		v.hold_mode = ""


## Called every physics tick before the vessel step (also during rails warp).
func update(v: Vessel) -> void:
	if not active():
		return
	if v.destroyed_flag:
		_finish(v, false, "Ракета разрушена")
		return
	var b := v.body
	var alt := v.altitude()
	var up := v.pos.normalized().to_v3()
	var east := Vector3.UP.cross(up)
	east = east.normalized() if east.length() > 1e-6 else Vector3.RIGHT
	var el := OrbitMath.elements(v.pos, v.vel, b.mu)
	var apo_alt: float = el.apoapsis - b.radius
	var peri_alt: float = el.periapsis - b.radius

	_auto_stage(v)

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
			if apo_alt >= target_altitude * 1.12:
				v.throttle = 0.0
				phase = Phase.COAST
		Phase.COAST:
			v.throttle = 0.0
			v.hold_mode = "prograde"
			# Burn centred on apoapsis.
			var tta := _time_to_apoapsis(v, el)
			var burn := _circularize_burn_time(v, el)
			if tta < burn * 0.5 + 15.0:
				wants_warp_reset = true
			# Burn when close to apoapsis, or right away if already past it.
			if tta <= burn * 0.5 or v.vel.dot(v.pos) < 0.0:
				phase = Phase.CIRCULARIZE
			# Drag ate some apoapsis while still in the air: top it up.
			elif alt < b.atmosphere_height and apo_alt < target_altitude * 0.97:
				v.hold_mode = "target"
				v.target_dir = (v.vel.normalized().to_v3() + up * 0.15).normalized()
				v.throttle = 0.5
		Phase.CIRCULARIZE:
			# Thrust along the local horizon (in the orbit plane), pitching a bit
			# up or down to keep the vertical speed near zero.
			var horiz := v.vel.to_v3() - up * v.vel.to_v3().dot(up)
			horiz = horiz.normalized() if horiz.length() > 1e-3 else east
			var vs := v.vel.to_v3().dot(up)
			var hold_alt := maxf(apo_alt, b.atmosphere_height * 1.1)
			var pitch_up := clampf((hold_alt - alt) * 0.0004 - vs * 0.01, -0.35, 0.35)
			v.hold_mode = "target"
			v.target_dir = (horiz * cos(pitch_up) + up * sin(pitch_up)).normalized()
			v.throttle = 1.0
			if peri_alt >= target_altitude * 0.95 or (el.e < 0.003 and peri_alt > b.atmosphere_height):
				v.throttle = 0.0
				_finish(v, true, "Орбита: апоцентр %.1f км, перицентр %.1f км" % [apo_alt / 1000.0, peri_alt / 1000.0])
			elif not v.has_fuel() and v.stages.size() <= 2:
				v.throttle = 0.0
				if peri_alt > b.atmosphere_height:
					_finish(v, true, "Орбита (топливо кончилось): перицентр %.1f км" % (peri_alt / 1000.0))
				else:
					_finish(v, false, "Не хватило топлива для орбиты")


func _auto_stage(v: Vessel) -> void:
	var s := v.active_stage()
	if s.is_empty():
		return
	# Only drop a spent engine stage if something with an engine remains above.
	if s.has_engine and s.fuel <= 0.0 and not v.infinite_fuel and v.stages.size() > 2:
		v.stage()


func _time_to_apoapsis(v: Vessel, el: Dictionary) -> float:
	if el.e >= 1.0 or is_inf(el.period):
		return 0.0
	var nu: float = el.true_anomaly
	var e: float = el.e
	# Mean anomaly from true anomaly.
	var ea := 2.0 * atan(sqrt((1.0 - e) / (1.0 + e)) * tan(nu * 0.5))
	var m := ea - e * sin(ea)
	if m < 0.0:
		m += TAU
	var n: float = TAU / el.period
	var dm := PI - m
	if dm < 0.0:
		dm += TAU
	return dm / n


func _circularize_burn_time(v: Vessel, el: Dictionary) -> float:
	var b := v.body
	var ra: float = el.apoapsis
	if is_inf(ra):
		return 0.0
	var a: float = el.a
	var v_apo := sqrt(maxf(b.mu * (2.0 / ra - 1.0 / a), 0.0))
	var v_circ := sqrt(b.mu / ra)
	var dv := maxf(v_circ - v_apo, 0.0)
	var thrust := maxf(v.current_thrust_max(), 1.0)
	if not v.has_fuel() and v.stages.size() > 2:
		thrust = maxf(v.stages[v.stages.size() - 2].thrust_vac, 1.0)
	return dv * v.mass() / thrust


func _finish(v: Vessel, ok: bool, msg: String) -> void:
	phase = Phase.DONE if ok else Phase.IDLE
	v.throttle = 0.0
	v.hold_mode = ""
	v.sas = true
	finished.emit(ok, msg)
