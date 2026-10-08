class_name ApExecute
extends ApTask
## Executes a maneuver node: warps close to it, turns to the burn vector and burns
## centred on the node time, steering by the remaining Δv to the planned orbit.

const ALIGN_DEG := 4.0

var node: ManeuverNode
var _r_after: DVec3      ## planned post-burn state at node time (relative to node.body)
var _v_after: DVec3
var _burn_dir := Vector3.FORWARD
var _burn_time := 0.0
var _burning := false
var _min_rem := INF


func _init(n: ManeuverNode) -> void:
	node = n
	title = "Манёвр %d м/с" % int(round(n.total()))


func start(ap: Autopilot, v: Vessel, t: float) -> void:
	ap.node = node
	if v.body != node.body:
		return
	var st := node.state_before(v.pos, v.vel, t)
	var dv := ManeuverNode.dv_vector(st[0], st[1], node.prograde, node.normal, node.radial)
	_r_after = st[0]
	_v_after = (st[1] as DVec3).add(dv)
	_burn_dir = dv.normalized().to_v3()
	_burn_time = ManeuverNode.burn_time(v, node.total())
	v.sas = true
	v.hold_mode = "target"
	v.target_dir = _burn_dir


func stop(v: Vessel) -> void:
	v.throttle = 0.0


func update(ap: Autopilot, v: Vessel, t: float) -> int:
	if v.body != node.body:
		message = "манёвр рассчитан для другой сферы влияния"
		return FAILED
	if is_inf(_burn_time):
		message = "нет двигателя с топливом"
		return FAILED
	auto_stage(v)
	var t_start := node.t - _burn_time * 0.5
	if not _burning:
		var wait := t_start - t
		v.hold_mode = "target"
		v.target_dir = _burn_dir
		v.throttle = 0.0
		if wait > 0.0:
			status = "ждём %s, импульс %d м/с · %d с" % [_fmt(wait), int(node.total()), int(_burn_time)]
			# Coast with time warp, back to 1x ~45 s before the burn to turn around.
			ap.requested_warp = warp_for(wait - 45.0)
			if wait < 50.0:
				ap.wants_warp_reset = true
			return RUNNING
		ap.wants_warp_reset = true
		ap.requested_warp = 1
		_burning = true

	# Remaining Δv to the planned orbit at the current time.
	var target := OrbitMath.propagate(_r_after, _v_after, node.body.mu, t - node.t)
	var rem := (target[1] as DVec3).sub(v.vel)
	var rem_len := rem.length()
	_min_rem = minf(_min_rem, rem_len)
	status = "импульс: осталось %.1f м/с" % rem_len
	var done_tol := maxf(0.05, node.total() * 0.0005)
	if rem_len < done_tol or (rem_len > _min_rem + 0.5 and _min_rem < 5.0):
		v.throttle = 0.0
		message = "выполнен, ошибка %.2f м/с" % rem_len
		ap.node = null
		return DONE
	if rem_len > 5.0:
		_burn_dir = rem.normalized().to_v3()
	v.hold_mode = "target"
	v.target_dir = _burn_dir
	var aligned := rad_to_deg(v.up_world().angle_to(_burn_dir)) < ALIGN_DEG
	var thrust_max := maxf(v.current_thrust_max(), 1.0)
	var thr := clampf(rem_len * v.mass() / thrust_max / 1.5, 0.005, 1.0)
	v.throttle = thr if aligned else 0.0
	if not v.has_fuel() and v.stages.size() <= 2:
		v.throttle = 0.0
		message = "кончилось топливо, недобрано %.0f м/с" % rem_len
		return FAILED
	return RUNNING


static func _fmt(s: float) -> String:
	var i := int(s)
	if i >= 3600:
		return "%dч %02dм" % [i / 3600, (i / 60) % 60]
	if i >= 60:
		return "%dм %02dс" % [i / 60, i % 60]
	return "%dс" % i
