class_name ApPlan
extends ApTask
## Plans a maneuver on a worker thread (so the phone doesn't freeze), then inserts
## an ApExecute for it. Kinds: transfer, correction, circularize, return, deorbit.

var kind := ""
var params := {}
var _task_id := -1
var _result := {}
var _started_at := 0


func _init(k: String, p: Dictionary) -> void:
	kind = k
	params = p
	match k:
		"transfer": title = "Перелёт к %s (орбита %d км)" % [_target_name_gen(), int(p.alt / 1000.0)]
		"correction": title = "Коррекция траектории"
		"circularize": title = "Скругление в %s" % ("апоцентре" if p.where == "apo" else "перицентре")
		"return": title = "Отлёт домой (перицентр %d км)" % int(p.alt / 1000.0)
		"deorbit": title = "Сход с орбиты"
		"peri_correction": title = "Коррекция перицентра (%d км)" % int(p.alt / 1000.0)
		_: title = "Расчёт манёвра"


func _target_name_gen() -> String:
	var tb: CelestialBody = params.get("target")
	return "Луне" if tb != null and tb.name == "Луна" else (tb.name if tb else "цели")


func start(_ap: Autopilot, v: Vessel, t: float) -> void:
	status = "расчёт…"
	var r := v.pos.copy()
	var vel := v.vel.copy()
	var b := v.body
	_result = {}
	_started_at = Time.get_ticks_msec()
	var job := func() -> void:
		_result = _compute(r, vel, b, t)
	_task_id = WorkerThreadPool.add_task(job, false, "autopilot plan")


func stop(_v: Vessel) -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1


func update(ap: Autopilot, v: Vessel, _t: float) -> int:
	v.throttle = 0.0
	ap.requested_warp = 1
	if _task_id >= 0:
		if not WorkerThreadPool.is_task_completed(_task_id):
			return RUNNING
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
		print("[I] ", "Autopilot: plan '%s' took %d ms" % [kind, Time.get_ticks_msec() - _started_at])
	if _result.get("skip", false):
		message = _result.get("msg", "не нужно")
		return DONE
	var n: ManeuverNode = _result.get("node")
	if n == null:
		message = _result.get("msg", "не удалось рассчитать")
		return FAILED
	message = _result.get("msg", "")
	ap.insert_next([ApExecute.new(n)])
	return DONE


## Runs on a worker thread: only pure math on copies.
func _compute(r: DVec3, vel: DVec3, b: CelestialBody, t: float) -> Dictionary:
	match kind:
		"transfer":
			var target: CelestialBody = params.target
			if b != target.parent:
				return {"msg": "сначала нужна орбита вокруг %s" % target.parent.name}
			var el := OrbitMath.elements(r, vel, b.mu)
			if el.e >= 1.0 or el.periapsis - b.radius < b.atmosphere_height:
				return {"msg": "сначала нужна устойчивая орбита"}
			var plan := Planner.plan_transfer(r, vel, b, t, target, params.alt)
			if plan.is_empty():
				return {"msg": "окно перелёта не найдено в ближайшие 12 суток"}
			return {"node": plan.node, "msg": "окно через %s, у Луны %.0f км" % [ApExecute._fmt(plan.node.t - t), plan.peri_alt / 1000.0]}
		"correction":
			var target2: CelestialBody = params.target
			var segs := Trajectory.predict(r, vel, b, t)
			var enc := Trajectory.find_encounter(segs, target2)
			if not enc.is_empty() and absf(enc.el.periapsis - target2.radius - params.alt) < 3000.0:
				return {"skip": true, "msg": "коррекция не нужна"}
			var n := Planner.plan_correction(r, vel, b, t, target2, params.alt)
			if n == null:
				return {"msg": "коррекция не нашлась"}
			if n.total() < 0.5:
				return {"skip": true, "msg": "коррекция не нужна"}
			return {"node": n}
		"circularize":
			var c := Planner.circularize(r, vel, b, t, params.where)
			if c == null:
				return {"msg": "орбита незамкнута — скругление невозможно"}
			return {"node": c}
		"return":
			if b.parent == null:
				return {"msg": "уже у главного тела"}
			var ret := Planner.plan_return(r, vel, b, t, params.alt)
			if ret.is_empty():
				return {"msg": "траектория домой не найдена"}
			return {"node": ret.node, "msg": "перицентр у %s %.1f км" % [b.parent.name, ret.peri_alt / 1000.0]}
		"deorbit":
			return {"node": Planner.deorbit(r, vel, b, t, params.alt)}
		"peri_correction":
			var el2 := OrbitMath.elements(r, vel, b.mu)
			if absf(el2.periapsis - b.radius - params.alt) < 300.0:
				return {"skip": true, "msg": "перицентр уже %.1f км" % ((el2.periapsis - b.radius) / 1000.0)}
			var pc := Planner.plan_periapsis_correction(r, vel, b, t, params.alt)
			if pc.total() < 0.05:
				return {"skip": true, "msg": "коррекция не нужна"}
			return {"node": pc}
	return {"msg": "неизвестная задача"}
