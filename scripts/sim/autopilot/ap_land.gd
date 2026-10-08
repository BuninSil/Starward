class_name ApLand
extends ApTask
## Atmospheric landing of the capsule: drops all lower stages, holds retrograde,
## deploys the parachute low and slow enough, waits for touchdown.

const CHUTE_ALT := 2500.0
const CHUTE_SPEED := 300.0

var _stage_timer := 0.0


func _init() -> void:
	title = "Посадка на парашюте"


func start(_ap: Autopilot, v: Vessel, _t: float) -> void:
	v.throttle = 0.0
	v.sas = true
	v.hold_mode = "retrograde"


func update(ap: Autopilot, v: Vessel, _t: float) -> int:
	ap.requested_warp = 1
	v.throttle = 0.0
	var b := v.body
	if not v.landed and v.altitude() > b.atmosphere_height:
		# Skipped out of the atmosphere: coast to the next pass with time warp.
		var el := OrbitMath.elements(v.pos, v.vel, b.mu)
		if el.periapsis - b.radius > b.atmosphere_height:
			message = "капсулу выбросило из атмосферы на орбиту"
			return FAILED
		var vs := -v.vel.dot(v.pos.normalized())
		var dt := Planner.time_to_anomaly(el, 0.0) if vs <= 0.0 else (v.altitude() - b.atmosphere_height) / maxf(vs, 1.0)
		status = "отскок от атмосферы, ждём следующий заход"
		ap.requested_warp = warp_for(dt - 120.0)
		return RUNNING
	if v.landed:
		message = "капсула на поверхности, скорость касания %.1f м/с" % v.touchdown_speed
		return DONE
	# Drop everything below the capsule, one stage per second.
	if v.stages.size() > 1:
		status = "сброс ступеней"
		_stage_timer -= 1.0 / 60.0
		if _stage_timer <= 0.0:
			v.stage()
			_stage_timer = 1.0
		return RUNNING
	v.hold_mode = "retrograde"
	var speed := v.surface_velocity().length()
	if not v.chute_deployed:
		status = "торможение в атмосфере, %d м/с" % int(speed)
		if v.altitude() < CHUTE_ALT and speed < CHUTE_SPEED or v.altitude() < 800.0:
			var err := v.deploy_chute()
			if err != "":
				message = err
				return FAILED
	else:
		status = "спуск на парашюте, %d м/с, высота %d м" % [int(speed), int(v.altitude())]
	return RUNNING
