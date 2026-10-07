class_name OrbitMath
extends RefCounted
## Two-body (patched conics) helpers on DVec3 state vectors relative to the body centre.


## Orbital elements from state. Returns a Dictionary:
## a (m, negative for hyperbolic), e, inc (rad), apoapsis/periapsis (radius, m;
## apoapsis = INF if unbound), period (s, INF if unbound), h (DVec3), e_vec (DVec3),
## energy, true_anomaly (rad).
static func elements(r: DVec3, v: DVec3, mu: float) -> Dictionary:
	var rl := r.length()
	var v2 := v.length_squared()
	var h := r.cross(v)
	var energy := v2 * 0.5 - mu / rl
	# e = ((v^2 - mu/r) r - (r.v) v) / mu
	var e_vec := r.mul(v2 - mu / rl).sub(v.mul(r.dot(v))).mul(1.0 / mu)
	var e := e_vec.length()
	var a := INF if absf(energy) < 1e-9 else -mu / (2.0 * energy)
	var hl := h.length()
	var inc := acos(clampf(h.y / hl, -1.0, 1.0)) if hl > 0.0 else 0.0
	var p := hl * hl / mu
	var peri := p / (1.0 + e)
	var apo := INF
	var period := INF
	if e < 1.0 and a > 0.0:
		apo = a * (1.0 + e)
		period = TAU * sqrt(a * a * a / mu)
	var nu := 0.0
	if e > 1e-8:
		nu = acos(clampf(e_vec.dot(r) / (e * rl), -1.0, 1.0))
		if r.dot(v) < 0.0:
			nu = TAU - nu
	return {
		"a": a, "e": e, "inc": inc, "apoapsis": apo, "periapsis": peri,
		"period": period, "h": h, "e_vec": e_vec, "energy": energy,
		"true_anomaly": nu, "p": p,
	}


# --- Kepler propagation (universal variables, Curtis alg. 3.3/3.4) -----------

static func _stumpff_c(z: float) -> float:
	if z > 1e-6:
		return (1.0 - cos(sqrt(z))) / z
	if z < -1e-6:
		return (cosh(sqrt(-z)) - 1.0) / -z
	return 0.5 - z / 24.0


static func _stumpff_s(z: float) -> float:
	if z > 1e-6:
		var sz := sqrt(z)
		return (sz - sin(sz)) / (sz * sz * sz)
	if z < -1e-6:
		var sz := sqrt(-z)
		return (sinh(sz) - sz) / (sz * sz * sz)
	return 1.0 / 6.0 - z / 120.0


## Propagates (r0, v0) by dt seconds on a pure Kepler orbit. Returns [r, v].
static func propagate(r0: DVec3, v0: DVec3, mu: float, dt: float) -> Array:
	if dt == 0.0:
		return [r0.copy(), v0.copy()]
	var smu := sqrt(mu)
	var r0l := r0.length()
	var vr0 := r0.dot(v0) / r0l
	var alpha := 2.0 / r0l - v0.length_squared() / mu  # 1/a

	# Initial guess
	var chi := smu * absf(alpha) * dt
	if absf(alpha) < 1e-12 or chi == 0.0:
		chi = smu * dt / r0l
	for _i in 60:
		var z := alpha * chi * chi
		var c := _stumpff_c(z)
		var s := _stumpff_s(z)
		var f := r0l * vr0 / smu * chi * chi * c + (1.0 - alpha * r0l) * chi * chi * chi * s \
			+ r0l * chi - smu * dt
		var fp := r0l * vr0 / smu * chi * (1.0 - alpha * chi * chi * s) \
			+ (1.0 - alpha * r0l) * chi * chi * c + r0l
		var step := f / fp
		chi -= step
		if absf(step) < 1e-9:
			break

	var z2 := alpha * chi * chi
	var c2 := _stumpff_c(z2)
	var s2 := _stumpff_s(z2)
	var fl := 1.0 - chi * chi / r0l * c2
	var gl := dt - chi * chi * chi / smu * s2
	var r := r0.mul(fl).add(v0.mul(gl))
	var rl := r.length()
	var fdot := smu / (rl * r0l) * (alpha * chi * chi * chi * s2 - chi)
	var gdot := 1.0 - chi * chi / rl * c2
	var v := r0.mul(fdot).add(v0.mul(gdot))
	return [r, v]


## Points of the orbit (relative to body centre) for drawing, in the orbit plane.
## For bound orbits: full ellipse. For unbound: the arc up to max_radius.
static func orbit_points(el: Dictionary, count: int, max_radius: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var e: float = el.e
	var p: float = el.p
	var h: DVec3 = el.h
	if h.length() <= 0.0:
		return pts
	var w := h.normalized()
	var u: DVec3
	if e > 1e-8:
		u = (el.e_vec as DVec3).normalized()
	else:
		# Circular: any in-plane reference direction.
		var ref := DVec3.new(1, 0, 0) if absf(w.x) < 0.9 else DVec3.new(0, 0, 1)
		u = w.cross(ref).cross(w).normalized()
	var vdir := w.cross(u)
	var nu_max := PI
	if e >= 1.0:
		# r(nu) = p / (1 + e cos nu) <= max_radius
		var cmin := (p / max_radius - 1.0) / e
		nu_max = acos(clampf(cmin, -1.0, 1.0))
	for i in count + 1:
		var nu := lerpf(-nu_max, nu_max, float(i) / count)
		var rr := p / (1.0 + e * cos(nu))
		if rr <= 0.0 or rr > max_radius:
			rr = max_radius
		var pt := u.mul(rr * cos(nu)).add(vdir.mul(rr * sin(nu)))
		pts.append(pt.to_v3())
	return pts
