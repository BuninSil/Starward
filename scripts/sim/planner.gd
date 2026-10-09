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
			for delta in [[st[0], 0, 0, 0], [-st[0], 0, 0, 0], [0, st[1], 0, 0], [0, -st[1], 0, 0],
					[0, 0, st[2], 0], [0, 0, -st[2], 0], [0, 0, 0, st[2]], [0, 0, 0, -st[2]]]:
				var cand := ManeuverNode.new(node.t + delta[0], node.body, node.prograde + delta[1],
					node.normal + delta[2], node.radial + delta[3])
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
	# Segments up to the target's SOI only: a miss would go on around the Sun,
	# which is expensive to sample and useless here. Moon: ours + target (2);
	# planet from a planet's orbit: ours + the Sun + target (3).
	var max_segs := 2 if node.body == target.parent else 3
	var segs := node.predict_after(r, v, t_now, max_segs)
	for i in segs.size():
		var s: Dictionary = segs[i]
		if s.body == target:
			var pa: float = s.el.periapsis - target.radius
			return {"score": absf(pa - target_alt), "encounter": true, "peri_alt": pa, "t_arrive": s.t0}
	# No encounter: closest approach on the segment around the target's parent.
	var s0: Dictionary = segs[0]
	for s in segs:
		if s.body == target.parent:
			s0 = s
	var dmin := INF
	var pts: PackedVector3Array = s0.points
	var n := pts.size()
	for i in range(0, n, 2):
		var tt: float = lerpf(s0.t0, s0.t1, float(i) / maxf(n - 1, 1))
		var d := DVec3.from_v3(pts[i]).sub(target.state_at(tt)[0]).length()
		dmin = minf(dmin, d)
	return {"score": 1.0e12 + dmin, "encounter": false, "peri_alt": INF, "t_arrive": 0.0}


# --- Interplanetary transfer -----------------------------------------------------------

## From a closed orbit around planet `b` to `target` (another planet, same parent).
## The departure date and excess velocity come from a small Lambert search around
## the Hohmann window. The ejection burn is prograde in the parking orbit's plane
## at the point where the escape asymptote matches the excess velocity's in-plane
## direction; the out-of-plane part (parking orbit vs. transfer plane) is left to
## the mid-course correction, which is far cheaper than a plane change here.
## Returns {node, miss, t_window, t_arrive, v_inf} (node may not reach the SOI yet).
static func plan_interplanetary(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, target: CelestialBody,
		_target_alt: float) -> Dictionary:
	var sun := b.parent
	if sun == null or target.parent != sun:
		return {}
	var el := OrbitMath.elements(r, v, b.mu)
	if el.e >= 1.0:
		return {}
	var win := transfer_window(b, target, t_now + 3600.0)
	if win.is_empty() or not win.has("v_inf"):
		return {}
	var t_d: float = win.t_depart
	var v_inf: DVec3 = win.v_inf
	var vinf := v_inf.length()
	var h: DVec3 = (el.h as DVec3).normalized()
	var s_p := v_inf.sub(h.mul(v_inf.dot(h))).normalized()
	var period: float = el.period
	# Burn point: periapsis of the escape hyperbola, θ∞ behind the asymptote.
	var rp: float = el.a
	var theta := acos(-1.0 / (1.0 + rp * vinf * vinf / b.mu))
	var burn_dir := _rotate_about(s_p, h, -theta)
	var best_t := t_now + 600.0
	var best_dot := -2.0
	for k in 360:
		var tt := t_d - period + period * k / 360.0
		if tt < t_now + 300.0:
			continue
		var pp: DVec3 = OrbitMath.propagate(r, v, b.mu, tt - t_now)[0]
		var dd := pp.normalized().dot(burn_dir)
		if dd > best_dot:
			best_dot = dd
			best_t = tt
	var st := OrbitMath.propagate(r, v, b.mu, best_t - t_now)
	var rb := (st[0] as DVec3).length()
	var dv := sqrt(vinf * vinf + 2.0 * b.mu / rb) - (st[1] as DVec3).length()
	var node := ManeuverNode.new(best_t, b, dv)
	# Refine time and prograde Δv on the real trajectory (closest approach).
	var best := _transfer_score(r, v, t_now, node, target, 0.0)
	for step in [[period / 60.0, 10.0], [period / 240.0, 2.0], [period / 960.0, 0.5]]:
		var improved := true
		var guard := 0
		while improved and guard < 16:
			improved = false
			guard += 1
			for d in [[step[0], 0.0], [-step[0], 0.0], [0.0, step[1]], [0.0, -step[1]]]:
				var cand := ManeuverNode.new(node.t + d[0], b, node.prograde + d[1])
				if cand.t < t_now + 300.0:
					continue
				var sc := _transfer_score(r, v, t_now, cand, target, 0.0)
				if sc.score < best.score:
					best = sc
					node = cand
					improved = true
	return {"node": node, "encounter": best.encounter, "peri_alt": best.peri_alt,
		"miss": best.score - 1.0e12 if not best.encounter else 0.0,
		"t_window": t_d, "t_arrive": t_d + float(win.tof), "v_inf": vinf}


## Mid-course correction around the Sun towards `target`: Lambert to the target's
## position at the planned arrival, then a fine search for the periapsis altitude.
static func plan_helio_correction(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, target: CelestialBody,
		target_alt: float, t_arrive_hint: float) -> ManeuverNode:
	var t_c := t_now + 300.0
	var st := OrbitMath.propagate(r, v, b.mu, t_c - t_now)
	var rc: DVec3 = st[0]
	var vc: DVec3 = st[1]
	var hn := rc.cross(vc).normalized()
	# Arrival time: the hint, or the current closest approach.
	var t_a := t_arrive_hint
	if t_a <= t_c + 86400.0:
		t_a = _closest_approach_time(rc, vc, b, t_c, target)
	var best_node: ManeuverNode = null
	var best_cost := INF
	# Small scan of arrival times: cheapest Lambert correction wins.
	for f in [0.9, 0.95, 1.0, 1.05, 1.1]:
		var ta: float = t_c + (t_a - t_c) * f
		var tp: DVec3 = target.state_at(ta)[0]
		var sol := OrbitMath.lambert(rc, tp, ta - t_c, b.mu, hn)
		if sol.is_empty():
			continue
		var dvv := (sol[0] as DVec3).sub(vc)
		if dvv.length() < best_cost:
			best_cost = dvv.length()
			var pro_b := vc.normalized()
			var nor_b := rc.cross(vc).normalized()
			var rad_b := pro_b.cross(nor_b)
			if rad_b.dot(rc) < 0.0:
				rad_b = rad_b.mul(-1.0)
			best_node = ManeuverNode.new(t_c, b, dvv.dot(pro_b), dvv.dot(nor_b), dvv.dot(rad_b))
	if best_node == null:
		return null
	# Lambert aims at the centre: nudge the burn so the pass has the wanted periapsis.
	var node := best_node
	var best := _transfer_score(r, v, t_now, node, target, target_alt)
	for stp in [2.0, 0.5, 0.1, 0.02, 0.005]:
		var improved := true
		var guard := 0
		while improved and guard < 25:
			improved = false
			guard += 1
			for d in [[stp, 0, 0], [-stp, 0, 0], [0, stp, 0], [0, -stp, 0], [0, 0, stp], [0, 0, -stp]]:
				var cand := ManeuverNode.new(node.t, b, node.prograde + d[0], node.normal + d[1], node.radial + d[2])
				var sc := _transfer_score(r, v, t_now, cand, target, target_alt)
				if sc.score < best.score:
					best = sc
					node = cand
					improved = true
	return node if best.encounter else best_node


static func _closest_approach_time(r: DVec3, v: DVec3, b: CelestialBody, t0: float, target: CelestialBody) -> float:
	var el := OrbitMath.elements(r, v, b.mu)
	var span: float = el.period if el.e < 1.0 else 400.0 * 86400.0
	var best_t := t0 + span * 0.5
	var best_d := INF
	for k in 721:
		var tt := span * k / 720.0
		var p: DVec3 = OrbitMath.propagate(r, v, b.mu, tt)[0]
		var d := p.sub(target.state_at(t0 + tt)[0]).length()
		if d < best_d:
			best_d = d
			best_t = t0 + tt
	return best_t


## Next Hohmann window from planet `a` to planet `b` (same parent) after t_from:
## departure time when `b` will be opposite to `a` after the transfer time.
## Returns {t_depart, tof, r2, dv_hint} or {}.
static func transfer_window(a: CelestialBody, b: CelestialBody, t_from: float) -> Dictionary:
	var sun := a.parent
	var pa := a.orbital_period()
	var pb := b.orbital_period()
	var synodic := absf(1.0 / (1.0 / pa - 1.0 / pb)) if absf(pa - pb) > 1.0 else pa
	var t_end := t_from + synodic * 1.05
	var steps := 720
	var best := {}
	var best_err := INF
	for k in steps + 1:
		var t_d := lerpf(t_from, t_end, float(k) / steps)
		var r1v: DVec3 = a.state_at(t_d)[0]
		var r1 := r1v.length()
		var r2 := b.orbit_a
		var tof := 0.0
		var bp := DVec3.new()
		for _i in 3:
			var at := (r1 + r2) * 0.5
			tof = PI * sqrt(at * at * at / sun.mu)
			bp = b.state_at(t_d + tof)[0]
			r2 = bp.length()
		var err := acos(clampf(r1v.mul(-1.0).normalized().dot(bp.normalized()), -1.0, 1.0))
		if err < best_err:
			best_err = err
			best = {"t_depart": t_d, "tof": tof, "r2": r2}
	if best.is_empty():
		return {}
	# Lambert around the Hohmann guess: cheapest departure + arrival excess speed.
	var h_ref: DVec3 = (a.state_at(best.t_depart)[0] as DVec3).cross(a.state_at(best.t_depart)[1]).normalized()
	var day := 86400.0
	var t0d: float = best.t_depart
	var tof0: float = best.tof
	var best_cost := INF
	for dd in range(-12, 13, 2):
		for ff in [0.85, 0.9, 0.95, 1.0, 1.05, 1.1, 1.15]:
			var td: float = t0d + dd * day * maxf(tof0 / (100.0 * day), 0.5)
			if td < t_from:
				continue
			var tf: float = tof0 * ff
			var sa: Array = a.state_at(td)
			var sb: Array = b.state_at(td + tf)
			var sol := OrbitMath.lambert(sa[0], sb[0], tf, sun.mu, h_ref)
			if sol.is_empty():
				continue
			var vi1 := (sol[0] as DVec3).sub(sa[1])
			var vi2 := (sol[1] as DVec3).sub(sb[1])
			var cost := vi1.length() + 0.5 * vi2.length()
			if cost < best_cost:
				best_cost = cost
				best["t_depart"] = td
				best["tof"] = tf
				best["v_inf"] = vi1
				best["v_inf_arrive"] = vi2.length()
	# Rough Δv from a low circular orbit (for the window hint).
	var vinf: float = (best.v_inf as DVec3).length() if best.has("v_inf") else 0.0
	var r_low := a.radius + maxf(a.atmosphere_height * 1.5, 20_000.0)
	best["dv_hint"] = sqrt(vinf * vinf + 2.0 * a.mu / r_low) - sqrt(a.mu / r_low)
	return best


static func _rotate_about(vv: DVec3, axis: DVec3, ang: float) -> DVec3:
	# Rodrigues' rotation formula.
	var c := cos(ang)
	var sn := sin(ang)
	return vv.mul(c).add(axis.cross(vv).mul(sn)).add(axis.mul(axis.dot(vv) * (1.0 - c)))


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


## Deorbit for a landing in daylight on an airless body: picks the burn time
## within one orbit so the point half an orbit later (≈ the new periapsis, where
## the powered descent ends) has the sun ~35° above the horizon.
static func deorbit_sunlit(r: DVec3, v: DVec3, b: CelestialBody, t_now: float, target_alt: float) -> ManeuverNode:
	var el := OrbitMath.elements(r, v, b.mu)
	var period: float = TAU * sqrt(pow(el.a, 3) / b.mu) if el.e < 1.0 else 3600.0
	var sun := DVec3.from_v3(SolarSystem.sun_dir(b, t_now + period * 0.75))
	var best_delay := 60.0
	var best := INF
	for i in 96:
		var delay := 60.0 + period * i / 96.0
		var st := OrbitMath.propagate(r, v, b.mu, delay + period * 0.5)
		var n := (st[0] as DVec3).normalized()
		var elev := n.dot(sun)
		var score := absf(elev - 0.57) + (5.0 if elev < 0.2 else 0.0)
		if score < best:
			best = score
			best_delay = delay
	return deorbit(r, v, b, t_now, target_alt, best_delay)


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
	# Cheapest single-axis fix first: scan radial (moves the pass sideways, very
	# effective far out on an approach) and prograde, bisect the zero crossing.
	var signed := func(n: ManeuverNode) -> float:
		var st2 := n.state_before(r, v, t_now)
		var dv2 := ManeuverNode.dv_vector(st2[0], st2[1], n.prograde, n.normal, n.radial)
		var el2 := OrbitMath.elements(st2[0], (st2[1] as DVec3).add(dv2), b.mu)
		return el2.periapsis - b.radius - target_alt
	var best_axis: ManeuverNode = null
	for axis in ["radial", "prograde"]:
		var mk := func(x: float) -> ManeuverNode:
			return ManeuverNode.new(t_now + 120.0, b, x if axis == "prograde" else 0.0, 0.0, x if axis == "radial" else 0.0)
		var f0: float = signed.call(mk.call(0.0))
		for sgn in [1.0, -1.0]:
			var prev_x := 0.0
			var prev_f := f0
			var x := 0.0
			var stp := 0.05
			while absf(x) < 400.0:
				x += sgn * stp
				stp *= 1.15
				var fx: float = signed.call(mk.call(x))
				if signf(fx) != signf(prev_f):
					var lo := prev_x
					var hi := x
					for _i in 50:
						var mid := (lo + hi) * 0.5
						if signf(float(signed.call(mk.call(mid)))) == signf(prev_f):
							lo = mid
						else:
							hi = mid
					var cand: ManeuverNode = mk.call(hi)
					if best_axis == null or cand.total() < best_axis.total():
						best_axis = cand
					break
				prev_x = x
				prev_f = fx
	if best_axis != null and absf(float(signed.call(best_axis))) < 500.0:
		return best_axis
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
