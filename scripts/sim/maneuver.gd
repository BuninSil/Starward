class_name ManeuverNode
extends RefCounted
## Planned impulsive burn at absolute time `t` in the vessel's current SOI.
## Δv components in the orbital frame at the node: prograde (along velocity),
## normal (along orbit angular momentum), radial (outward, ⟂ to velocity in-plane).

var t := 0.0
var prograde := 0.0
var normal := 0.0
var radial := 0.0
var body: CelestialBody


func _init(at: float = 0.0, b: CelestialBody = null, pro := 0.0, nor := 0.0, rad := 0.0) -> void:
	t = at
	body = b
	prograde = pro
	normal = nor
	radial = rad


func total() -> float:
	return sqrt(prograde * prograde + normal * normal + radial * radial)


## Vessel state at the node time, [r, v], relative to `body`. Assumes no SOI change before.
func state_before(r_now: DVec3, v_now: DVec3, t_now: float) -> Array:
	return OrbitMath.propagate(r_now, v_now, body.mu, t - t_now)


## World Δv vector for an orbit state at the node.
static func dv_vector(r: DVec3, v: DVec3, pro: float, nor: float, rad: float) -> DVec3:
	var p := v.normalized()
	var n := r.cross(v).normalized()
	var rr := p.cross(n)   # in-plane, perpendicular to velocity, pointing outward
	if rr.dot(r) < 0.0:
		rr = rr.mul(-1.0)
	return p.mul(pro).add(n.mul(nor)).add(rr.mul(rad))


func dv_world(r_now: DVec3, v_now: DVec3, t_now: float) -> DVec3:
	var st := state_before(r_now, v_now, t_now)
	return dv_vector(st[0], st[1], prograde, normal, radial)


## Predicted trajectory after the burn.
func predict_after(r_now: DVec3, v_now: DVec3, t_now: float) -> Array[Dictionary]:
	var st := state_before(r_now, v_now, t_now)
	var dv := dv_vector(st[0], st[1], prograde, normal, radial)
	return Trajectory.predict(st[0], (st[1] as DVec3).add(dv), body, t)


## Burn duration estimate with the current engine (Tsiolkovsky), seconds.
static func burn_time(v: Vessel, dv: float) -> float:
	var s := v.active_stage()
	var thrust := v.current_thrust_max()
	if s.is_empty() or thrust <= 0.0:
		# Next stage with an engine.
		for i in range(v.stages.size() - 2, -1, -1):
			if v.stages[i].has_engine:
				s = v.stages[i]
				thrust = s.thrust_vac
				break
	if thrust <= 0.0:
		return INF
	var isp: float = v.current_isp(s) if s.has_engine else 300.0
	var m0 := v.mass()
	var mdot := thrust / (isp * SolarSystem.G0)
	var m1 := m0 / exp(dv / (isp * SolarSystem.G0))
	return (m0 - m1) / mdot
