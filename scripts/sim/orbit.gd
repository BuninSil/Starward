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


## State [r, v] from classical elements. Frame: Y = north (spin axis), orbits with
## inc = 0 lie in the XZ plane and are prograde (counter-clockwise seen from +Y).
static func state_from_elements(a: float, e: float, inc: float, lan: float, argp: float,
		mean_anomaly: float, mu: float) -> Array:
	var m := fmod(mean_anomaly, TAU)
	var ea := m if e < 0.8 else PI
	for _i in 30:
		var d := (ea - e * sin(ea) - m) / (1.0 - e * cos(ea))
		ea -= d
		if absf(d) < 1e-12:
			break
	var cos_e := cos(ea)
	var sin_e := sin(ea)
	var r := a * (1.0 - e * cos_e)
	# Perifocal coordinates.
	var px := a * (cos_e - e)
	var py := a * sqrt(1.0 - e * e) * sin_e
	var k := sqrt(mu * a) / r
	var vx := -k * sin_e
	var vy := k * sqrt(1.0 - e * e) * cos_e
	var rp := _perifocal_to_frame(px, py, inc, lan, argp)
	var vp := _perifocal_to_frame(vx, vy, inc, lan, argp)
	return [rp, vp]


## Standard z-up rotation (Ω, i, ω), then mapped to the game frame (x, z, -y).
static func _perifocal_to_frame(px: float, py: float, inc: float, lan: float, argp: float) -> DVec3:
	var co := cos(lan)
	var so := sin(lan)
	var ci := cos(inc)
	var si := sin(inc)
	var cw := cos(argp)
	var sw := sin(argp)
	var x := (co * cw - so * sw * ci) * px + (-co * sw - so * cw * ci) * py
	var y := (so * cw + co * sw * ci) * px + (-so * sw + co * cw * ci) * py
	var z := (sw * si) * px + (cw * si) * py
	return DVec3.new(x, z, -y)


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


# --- Lambert's problem -------------------------------------------------------------

## Velocities [v1, v2] of the conic from r1 to r2 in time tof (single revolution,
## universal variables, Curtis alg. 5.2). `normal`: reference orbit normal that
## picks the prograde direction. Returns [] if it does not converge.
static func lambert(r1: DVec3, r2: DVec3, tof: float, mu: float, normal: DVec3) -> Array:
	var r1n := r1.length()
	var r2n := r2.length()
	var cos_dt := clampf(r1.dot(r2) / (r1n * r2n), -1.0, 1.0)
	var dtheta := acos(cos_dt)
	if r1.cross(r2).dot(normal) < 0.0:
		dtheta = TAU - dtheta
	var a := sin(dtheta) * sqrt(r1n * r2n / (1.0 - cos_dt))
	if absf(a) < 1e-9:
		return []
	var sq_mu := sqrt(mu)
	# F(z) increases with z; bracket the root and bisect (robust), then Newton polish.
	var y_of := func(z: float) -> float:
		return r1n + r2n + a * (z * _stumpff_s(z) - 1.0) / sqrt(_stumpff_c(z))
	var f_of := func(z: float) -> float:
		var y: float = y_of.call(z)
		if y < 0.0:
			return -INF
		return pow(y / _stumpff_c(z), 1.5) * _stumpff_s(z) + a * sqrt(y) - sq_mu * tof
	var lo := -4.0 * PI * PI
	var hi := 4.0 * PI * PI - 1e-6
	# Move lo up until y > 0 there.
	var guard := 0
	while float(y_of.call(lo)) < 0.0 and guard < 200:
		lo = lerpf(lo, hi, 0.05)
		guard += 1
	if float(f_of.call(lo)) > 0.0 or float(f_of.call(hi)) < 0.0:
		return []
	for _i in 200:
		var mid := (lo + hi) * 0.5
		if float(f_of.call(mid)) > 0.0:
			hi = mid
		else:
			lo = mid
		if hi - lo < 1e-12:
			break
	var z := (lo + hi) * 0.5
	var yv: float = y_of.call(z)
	var f := 1.0 - yv / r1n
	var g := a * sqrt(yv / mu)
	var gdot := 1.0 - yv / r2n
	var v1 := r2.sub(r1.mul(f)).mul(1.0 / g)
	var v2 := r2.mul(gdot).sub(r1).mul(1.0 / g)
	return [v1, v2]

