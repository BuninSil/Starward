class_name Trajectory
extends RefCounted
## Patched-conic trajectory prediction: follows the Kepler orbit in the current SOI,
## detects SOI exit / child SOI entry / surface impact and continues in the new body.
## Each segment: {body, t0, t1, r0, v0 (state at t0 relative to body), el, end,
## points (PackedVector3Array relative to body), next_body}
## end: "loop" (closed orbit), "exit", "enter", "impact", "horizon".

const SAMPLES := 360
const MAX_SEGMENTS := 4
const MAX_HORIZON := 40.0 * 86400.0


static func predict(r: DVec3, v: DVec3, body: CelestialBody, t0: float, max_segments := MAX_SEGMENTS) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cur_r := r.copy()
	var cur_v := v.copy()
	var cur_b := body
	var t := t0
	for _s in max_segments:
		var seg := _segment(cur_r, cur_v, cur_b, t)
		out.append(seg)
		if seg.end != "exit" and seg.end != "enter":
			break
		# Continue in the next body with the state at the transition time.
		var rv := OrbitMath.propagate(seg.r0, seg.v0, cur_b.mu, seg.t1 - seg.t0)
		var nb: CelestialBody = seg.next_body
		var pr: DVec3 = rv[0]
		var pv: DVec3 = rv[1]
		if seg.end == "exit":
			var st: Array = cur_b.state_at(seg.t1)
			pr = pr.add(st[0])
			pv = pv.add(st[1])
		else:
			var st2: Array = nb.state_at(seg.t1)
			pr = pr.sub(st2[0])
			pv = pv.sub(st2[1])
		cur_r = pr
		cur_v = pv
		cur_b = nb
		t = seg.t1
	return out


static func _segment(r: DVec3, v: DVec3, b: CelestialBody, t0: float) -> Dictionary:
	var el := OrbitMath.elements(r, v, b.mu)
	var bound: bool = el.e < 1.0 and (b.parent == null or el.apoapsis < b.soi_radius)
	var horizon := MAX_HORIZON
	if bound:
		horizon = minf(el.period, MAX_HORIZON)
	else:
		horizon = _time_to_radius(r, v, b, minf(b.soi_radius, b.radius * 400.0))
	var seg := {
		"body": b, "t0": t0, "t1": t0 + horizon, "r0": r.copy(), "v0": v.copy(),
		"el": el, "end": "loop" if bound else ("exit" if b.parent != null else "horizon"),
		"next_body": b.parent, "points": PackedVector3Array(),
	}
	var dt := horizon / SAMPLES
	# Periapsis below the surface: find the exact closest approach, so a fast
	# pass between samples is not missed.
	var impact_limit := horizon
	if el.periapsis < b.radius and r.dot(v) < 0.0:
		var search_hi := horizon if el.e >= 1.0 else minf(horizon, el.period * 0.5)
		var t_min := _golden_min_radius(r, v, b, 0.0, search_hi)
		if (OrbitMath.propagate(r, v, b.mu, t_min)[0] as DVec3).length() < b.radius:
			impact_limit = t_min
	var prev_t := 0.0
	var pts := PackedVector3Array()
	pts.append(r.to_v3())
	for i in range(1, SAMPLES + 1):
		var tt := minf(dt * i, impact_limit)
		var rv := OrbitMath.propagate(r, v, b.mu, tt)
		var p: DVec3 = rv[0]
		# Surface impact
		if p.length() < b.radius or tt >= impact_limit:
			var ti := _bisect(r, v, b, prev_t, tt, func(q: DVec3, _t: float) -> bool: return q.length() < b.radius)
			seg.t1 = t0 + ti
			seg.end = "impact"
			pts.append((OrbitMath.propagate(r, v, b.mu, ti)[0] as DVec3).to_v3())
			break
		# Child SOI entry
		var entered: CelestialBody = null
		for c in b.children:
			if p.sub(c.state_at(t0 + tt)[0]).length() < c.soi_radius:
				entered = c
				break
		if entered != null:
			var cc := entered
			var ti2 := _bisect(r, v, b, prev_t, tt, func(q: DVec3, abs_t: float) -> bool:
				return q.sub(cc.state_at(abs_t)[0]).length() < cc.soi_radius, t0)
			seg.t1 = t0 + ti2
			seg.end = "enter"
			seg.next_body = entered
			pts.append((OrbitMath.propagate(r, v, b.mu, ti2)[0] as DVec3).to_v3())
			break
		pts.append(p.to_v3())
		prev_t = tt
	seg.points = pts
	return seg


## Time of minimum radius in [lo, hi] (radius is unimodal there for an approaching orbit).
static func _golden_min_radius(r: DVec3, v: DVec3, b: CelestialBody, lo: float, hi: float) -> float:
	# For an approaching orbit the periapsis is ahead; restrict hi to the first rise.
	var gr := 0.618033988
	var a := lo
	var c := hi
	for _i in 80:
		var x1 := c - gr * (c - a)
		var x2 := a + gr * (c - a)
		var f1 := (OrbitMath.propagate(r, v, b.mu, x1)[0] as DVec3).length()
		var f2 := (OrbitMath.propagate(r, v, b.mu, x2)[0] as DVec3).length()
		if f1 < f2:
			c = x2
		else:
			a = x1
		if c - a < 0.5:
			break
	return (a + c) * 0.5


## Earliest time in (lo, hi] where pred is true (pred false at lo), by bisection.
static func _bisect(r: DVec3, v: DVec3, b: CelestialBody, lo: float, hi: float, pred: Callable, t_base := 0.0) -> float:
	for _i in 30:
		var mid := (lo + hi) * 0.5
		var q: DVec3 = OrbitMath.propagate(r, v, b.mu, mid)[0]
		if pred.call(q, t_base + mid):
			hi = mid
		else:
			lo = mid
		if hi - lo < 0.5:
			break
	return hi


## Time until the orbit reaches radius R (for escaping / hyperbolic orbits).
static func _time_to_radius(r: DVec3, v: DVec3, b: CelestialBody, target: float) -> float:
	if r.length() >= target:
		return 1.0
	var lo := 0.0
	var hi := 600.0
	while (OrbitMath.propagate(r, v, b.mu, hi)[0] as DVec3).length() < target and hi < MAX_HORIZON:
		lo = hi
		hi *= 2.0
	for _i in 40:
		var mid := (lo + hi) * 0.5
		if (OrbitMath.propagate(r, v, b.mu, mid)[0] as DVec3).length() < target:
			lo = mid
		else:
			hi = mid
	return hi


## Closest approach / periapsis info of the first segment in `body` (or null).
static func find_encounter(segs: Array[Dictionary], body: CelestialBody) -> Dictionary:
	for s in segs:
		if s.body == body:
			return s
	return {}
