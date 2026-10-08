class_name ApCoast
extends ApTask
## Coasts with time warp until an event: entering a body's SOI ("soi"), leaving to
## the parent ("soi_parent"), or reaching the atmosphere ("atmosphere").

var until := ""
var params := {}
var _from: CelestialBody


func _init(u: String, p: Dictionary) -> void:
	until = u
	params = p
	match u:
		"soi": title = "Полёт до сферы влияния: %s" % (p.body as CelestialBody).name
		"soi_parent": title = "Полёт домой до сферы влияния Земли"
		"atmosphere": title = "Полёт до атмосферы"
		"altitude": title = "Полёт до высоты %d км" % int(p.alt / 1000.0)


func start(_ap: Autopilot, v: Vessel, _t: float) -> void:
	_from = v.body
	v.throttle = 0.0
	v.sas = true
	v.hold_mode = "prograde"


func update(ap: Autopilot, v: Vessel, t: float) -> int:
	v.throttle = 0.0
	match until:
		"soi":
			if v.body == params.body:
				ap.wants_warp_reset = true
				return DONE
			var segs := Trajectory.predict(v.pos, v.vel, v.body, t, 2)
			var enc := Trajectory.find_encounter(segs, params.body)
			if enc.is_empty():
				message = "траектория не ведёт в сферу влияния %s" % (params.body as CelestialBody).name
				return FAILED
			status = "до входа %s" % ApExecute._fmt(enc.t0 - t)
			ap.requested_warp = warp_for(enc.t0 - t + 600.0)
		"soi_parent":
			if v.body != _from:
				ap.wants_warp_reset = true
				return DONE
			status = "высота %s" % _km(v.altitude())
			ap.requested_warp = 10000
		"altitude":
			if v.altitude() < params.alt:
				ap.wants_warp_reset = true
				return DONE
			var vs2 := -v.vel.dot(v.pos.normalized())
			var dt2: float = (v.altitude() - params.alt) / maxf(vs2, 1.0) if vs2 > 0.0 else 1.0e6
			status = "высота %s" % _km(v.altitude())
			ap.requested_warp = warp_for(dt2)
		"atmosphere":
			var b := v.body
			if not b.has_atmosphere():
				message = "у %s нет атмосферы" % b.name
				return FAILED
			if v.altitude() < b.atmosphere_height:
				ap.wants_warp_reset = true
				return DONE
			var el := OrbitMath.elements(v.pos, v.vel, b.mu)
			if el.periapsis - b.radius > b.atmosphere_height:
				message = "перицентр выше атмосферы — вход не состоится"
				return FAILED
			status = "высота %s" % _km(v.altitude())
			# Time to atmosphere: rough, by vertical speed; keep warp moderate near it.
			var vs := -v.vel.dot(v.pos.normalized())
			var dt := (v.altitude() - b.atmosphere_height) / maxf(vs, 1.0) if vs > 0.0 else 1.0e6
			ap.requested_warp = warp_for(dt)
	return RUNNING


static func _km(m: float) -> String:
	return "%d м" % int(m) if m < 10000.0 else "%.0f км" % (m / 1000.0)
