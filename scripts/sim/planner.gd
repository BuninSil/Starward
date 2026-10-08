class_name Planner
extends RefCounted
## Maneuver planning on top of Trajectory prediction. Pure functions on copies of
## state, safe to run on a worker thread. All return a ManeuverNode or null.


## Circularize at the next apoapsis ("apo") or periapsis ("peri").
static func circularize(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, where := "apo") -> ManeuverNode:
	var el := OrbitMath.elements(r, v, b.mu)
	if el.e >= 1.0 and where == "apo":
		return null
	var dt := time_to_anomaly(el, PI if where == "apo" else 0.0)
	var st := OrbitMath.propagate(r, v, b.mu, dt)
	var rl := (st[0] as DVec3).length()
	var dv := sqrt(b.mu / rl) - (st[1] as DVec3).length()
	return ManeuverNode.new(t_now + dt, b, dv)


## Change the opposite apsis: burn at the next apsis `where` so that the other apsis
## gets altitude `target_alt`.
static func set_opposite_apsis(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, where: String, target_alt: float) -> ManeuverNode:
	var el := OrbitMath.elements(r, v, b.mu)
	var dt := time_to_anomaly(el, PI if where == "apo" else 0.0) if el.e > 1e-3 else 60.0
	var st := OrbitMath.propagate(r, v, b.mu, dt)
	var r1 := (st[0] as DVec3).length()
	var r2 := b.radius + target_alt
	var a := (r1 + r2) * 0.5
	var v_needed := sqrt(b.mu * (2.0 / r1 - 1.0 / a))
	return ManeuverNode.new(t_now + dt, b, v_needed - (st[1] as DVec3).length())


## Time from the current state until true anomaly `nu` (0 = periapsis, PI = apoapsis).
static func time_to_anomaly(el: Dictionary, nu_target: float) -> float:
	var e: float = el.e
	if e >= 1.0:
		# Hyperbola: only periapsis makes sense, and only if still ahead.
		return maxf(_hyperbolic_time_to_peri(el), 0.0)
	var n: float = TAU / el.period
	var m_now := _mean_from_true(el.true_anomaly, e)
	var m_tgt := _mean_from_true(nu_target, e)
	var dm := fposmod(m_tgt - m_now, TAU)
	return dm / n


static func _mean_from_true(nu: float, e: float) -> float:
	var ea := 2.0 * atan(sqrt((1.0 - e) / (1.0 + e)) * tan(nu * 0.5))
	return fposmod(ea - e * sin(ea), TAU)


static func _hyperbolic_time_to_peri(el: Dictionary) -> float:
	var e: float = el.e
	var nu: float = el.true_anomaly
	if nu > PI:
		nu -= TAU   # approaching: negative anomaly
	var hf := 2.0 * atanh(sqrt((e - 1.0) / (e + 1.0)) * tan(nu * 0.5))
	var mh := e * sinh(hf) - hf
	var a: float = absf(el.a)
	var n := sqrt(_mu_from(el) / (a * a * a))
	return -mh / n


static func _mu_from(el: Dictionary) -> float:
	# p = h^2 / mu  ->  mu = h^2 / p
	var h: float = (el.h as DVec3).length()
	return h * h / el.p


# --- Moon transfer ------------------------------------------------------------------

## Finds the next Hohmann-like transfer from the current (near-circular) orbit to
## `target`, refined so that the periapsis at the target is `target_alt`.
## Returns {node, peri_alt, t_arrive} or {}.
static func plan_transfer(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, target: CelestialBody,
		target_alt: float, horizon_days := 12.0) -> Dictionary:
	var el := OrbitMath.elements(r, v, b.mu)
	if el.e >= 1.0:
		return {}
	var period: float = el.period
	var step := period / 48.0
	var t_end := t_now + horizon_days * 86400.0
	var t_b := t_now + 120.0
	var best := {}
	var tol := asin(clampf(target.soi_radius / target.orbit_a, 0.0, 1.0)) * 0.8
	while t_b < t_end:
		var st := OrbitMath.propagate(r, v, b.mu, t_b - t_now)
		var rb: DVec3 = st[0]
		var vb: DVec3 = st[1]
		var r1 := rb.length()
		var r_m := target.orbit_a
		var tof := 0.0
		var m_pos := DVec3.new()
		for _k in 3:
			var a_t := (r1 + r_m) * 0.5
			tof = PI * sqrt(a_t * a_t * a_t / b.mu)
			m_pos = target.state_at(t_b + tof)[0]
			r_m = m_pos.length()
		var ang := rb.mul(-1.0).normalized().dot(m_pos.normalized())
		if ang > cos(tol):
			var a_t2 := (r1 + r_m) * 0.5
			var dv := sqrt(b.mu * (2.0 / r1 - 1.0 / a_t2)) - vb.length()
			var node := ManeuverNode.new(t_b, b, dv)
			var refined := _refine_transfer(r, v, t_now, node, target, target_alt, step)
			if not refined.is_empty():
				return refined
			t_b += period * 0.5   # skip this pass
			continue
		t_b += step
	return best


## Coordinate search over (time, prograde, normal) for the target periapsis.
static func _refine_transfer(r: DVec3, v: DVec3, t_now: float, node: ManeuverNode, target: CelestialBody,
		target_alt: float, t_step: float) -> Dictionary:
	var best := _transfer_score(r, v, t_now, node, target, target_alt)
	var steps := [[t_step, 20.0, 20.0], [t_step * 0.25, 5.0, 5.0], [t_step * 0.06, 1.0, 1.0], [t_step * 0.015, 0.25, 0.25]]
	for st in steps:
		var improved := true
		var guard := 0
		while improved and guard < 12:
			improved = false
			guard += 1
			for delta in [[st[0], 0, 0], [-st[0], 0, 0], [0, st[1], 0], [0, -st[1], 0], [0, 0, st[2]], [0, 0, -st[2]]]:
				var cand := ManeuverNode.new(node.t + delta[0], node.body, node.prograde + delta[1], node.normal + delta[2])
				if cand.t < t_now + 60.0:
					continue
				var sc := _transfer_score(r, v, t_now, cand, target, target_alt)
				if sc.score < best.score:
					best = sc
					node = cand
					improved = true
	if best.score > 2000.0:   # no encounter or > 2 km off
		if best.encounter:
			return {"node": node, "peri_alt": best.peri_alt, "t_arrive": best.t_arrive}
		return {}
	return {"node": node, "peri_alt": best.peri_alt, "t_arrive": best.t_arrive}


static func _transfer_score(r: DVec3, v: DVec3, t_now: float, node: ManeuverNode, target: CelestialBody, target_alt: float) -> Dictionary:
	var segs := node.predict_after(r, v, t_now)
	for i in segs.size():
		var s: Dictionary = segs[i]
		if s.body == target:
			var pa: float = s.el.periapsis - target.radius
			return {"score": absf(pa - target_alt), "encounter": true, "peri_alt": pa, "t_arrive": s.t0}
	# No encounter: distance of closest approach on the first segment.
	var s0: Dictionary = segs[0]
	var dmin := INF
	var pts: PackedVector3Array = s0.points
	var n := pts.size()
	for i in range(0, n, 4):
		var tt: float = lerpf(s0.t0, s0.t1, float(i) / maxf(n - 1, 1))
		var d := DVec3.from_v3(pts[i]).sub(target.state_at(tt)[0]).length()
		dmin = minf(dmin, d)
	return {"score": 1.0e9 + dmin, "encounter": false, "peri_alt": INF, "t_arrive": 0.0}


# --- Return to the parent body -------------------------------------------------------

## From an orbit around a moon: escape burn so that the periapsis around the parent
## gets `parent_peri_alt` (e.g. inside the atmosphere for reentry). Returns {node, peri_alt} or {}.
static func plan_return(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, parent_peri_alt: float) -> Dictionary:
	var parent := b.parent
	if parent == null:
		return {}
	var el := OrbitMath.elements(r, v, b.mu)
	if el.e >= 1.0:
		return {}
	# Return ellipse: apo at the moon's distance, peri at target.
	var ra := b.orbit_a
	var rp := parent.radius + parent_peri_alt
	var a_ret := (ra + rp) * 0.5
	var v_apo := sqrt(parent.mu * (2.0 / ra - 1.0 / a_ret))
	var v_moon := sqrt(parent.mu / ra)
	var v_inf := absf(v_moon - v_apo)
	var r0 := r.length()
	var dv0 := sqrt(v_inf * v_inf + 2.0 * b.mu / r0) - v.length()
	var period: float = el.period
	var best := {"score": INF}
	var n := 72
	for i in n:
		var node := ManeuverNode.new(t_now + 120.0 + period * i / n, b, dv0)
		var sc := _return_score(r, v, t_now, node, parent, parent_peri_alt)
		if sc.score < best.score:
			best = sc
			best["node"] = node
	if is_inf(best.score):
		return {}
	var node: ManeuverNode = best.node
	var t_step := period / n
	for st in [[t_step * 0.5, 10.0], [t_step * 0.12, 2.0], [t_step * 0.03, 0.5], [t_step * 0.008, 0.1]]:
		var improved := true
		var guard := 0
		while improved and guard < 15:
			improved = false
			guard += 1
			for d in [[st[0], 0.0], [-st[0], 0.0], [0.0, st[1]], [0.0, -st[1]]]:
				var cand := ManeuverNode.new(node.t + d[0], b, node.prograde + d[1])
				if cand.t < t_now + 60.0:
					continue
				var sc := _return_score(r, v, t_now, cand, parent, parent_peri_alt)
				if sc.score < best.score:
					best = sc
					node = cand
					improved = true
	return {"node": node, "peri_alt": best.peri_alt}


static func _return_score(r: DVec3, v: DVec3, t_now: float, node: ManeuverNode, parent: CelestialBody, target_alt: float) -> Dictionary:
	var segs := node.predict_after(r, v, t_now)
	for s in segs:
		if s.body == parent:
			var pa: float = s.el.periapsis - parent.radius
			return {"score": absf(pa - target_alt), "peri_alt": pa}
	return {"score": INF, "peri_alt": INF}


## Lower the periapsis to `target_alt` with a retrograde burn ~`delay` s from now.
static func deorbit(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, target_alt: float, delay := 60.0) -> ManeuverNode:
	var st := OrbitMath.propagate(r, v, b.mu, delay)
	var r1 := (st[0] as DVec3).length()
	var rp := b.radius + target_alt
	var a := (r1 + rp) * 0.5
	# Burn at the current point: keep r1 as apoapsis.
	var v_needed := sqrt(b.mu * (2.0 / r1 - 1.0 / a))
	return ManeuverNode.new(t_now + delay, b, v_needed - (st[1] as DVec3).length())


## Small mid-course correction ~2 minutes from now to hit `target_alt` at `target`.
static func plan_correction(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, target: CelestialBody,
		target_alt: float) -> ManeuverNode:
	var node := ManeuverNode.new(t_now + 120.0, b)
	var best := _transfer_score(r, v, t_now, node, target, target_alt)
	for st in [20.0, 5.0, 1.0, 0.2, 0.05]:
		var improved := true
		var guard := 0
		while improved and guard < 20:
			improved = false
			guard += 1
			for d in [[st, 0, 0], [-st, 0, 0], [0, st, 0], [0, -st, 0], [0, 0, st], [0, 0, -st]]:
				var cand := ManeuverNode.new(node.t, b, node.prograde + d[0], node.normal + d[1], node.radial + d[2])
				var sc := _transfer_score(r, v, t_now, cand, target, target_alt)
				if sc.score < best.score:
					best = sc
					node = cand
					improved = true
	if not best.encounter:
		return null
	return node


## Correction burn ~2 minutes from now (prograde/radial) so the periapsis in the
## current SOI gets `target_alt`. Used on the way back from the Moon.
static func plan_periapsis_correction(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, target_alt: float) -> ManeuverNode:
	var node := ManeuverNode.new(t_now + 120.0, b)
	var score := func(n: ManeuverNode) -> float:
		var st := n.state_before(r, v, t_now)
		var dv := ManeuverNode.dv_vector(st[0], st[1], n.prograde, n.normal, n.radial)
		var el := OrbitMath.elements(st[0], (st[1] as DVec3).add(dv), b.mu)
		return absf(el.periapsis - b.radius - target_alt)
	var best: float = score.call(node)
	for stp in [20.0, 5.0, 1.0, 0.2, 0.05, 0.01]:
		var improved := true
		var guard := 0
		while improved and guard < 40:
			improved = false
			guard += 1
			for d in [[stp, 0.0], [-stp, 0.0], [0.0, stp], [0.0, -stp]]:
				var cand := ManeuverNode.new(node.t, b, node.prograde + d[0], 0.0, node.radial + d[1])
				var sc: float = score.call(cand)
				if sc < best:
					best = sc
					node = cand
					improved = true
	return node
