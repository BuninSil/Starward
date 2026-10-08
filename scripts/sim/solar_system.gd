class_name SolarSystem
extends RefCounted
## Body catalogue. Scale rule (see CLAUDE.md): sizes and distances are 1/10 of real,
## surface gravity is kept real (mu = g * R^2), atmospheres are scaled with sizes.
## Stage 1 has Earth only; other bodies come in later stages.

const SCALE := 0.1
const G0 := 9.80665


static func earth() -> CelestialBody:
	var b := CelestialBody.new()
	b.name = "Земля"
	b.radius = 6_371_000.0 * SCALE
	b.mu = 9.81 * b.radius * b.radius
	b.rotation_period = 86_164.1
	b.soi_radius = 924_000_000.0 * SCALE
	b.sea_level_pressure = 1.0
	b.sea_level_density = 1.225
	b.scale_height = 8_500.0 * SCALE
	b.atmosphere_height = 100_000.0 * SCALE
	b.color = Color(0.2, 0.4, 0.8)
	b.atmosphere_color = Color(0.35, 0.6, 1.0)
	return b


static func moon() -> CelestialBody:
	var b := CelestialBody.new()
	b.name = "Луна"
	b.radius = 1_737_400.0 * SCALE
	b.mu = 1.62 * b.radius * b.radius
	b.orbit_a = 384_400_000.0 * SCALE
	b.orbit_e = 0.0549
	# 5.145° to the ecliptic + 23.44° Earth axial tilt, fixed (no nodal precession).
	b.orbit_inc = deg_to_rad(28.58)
	b.orbit_lan = deg_to_rad(0.0)
	b.orbit_argp = deg_to_rad(0.0)
	b.orbit_m0 = deg_to_rad(250.0)
	b.color = Color(0.6, 0.6, 0.6)
	return b


## Earth with its Moon. Returns the root body.
static func build() -> CelestialBody:
	var e := earth()
	var m := moon()
	e.add_child_body(m)
	# Tidally locked: one rotation per orbit, near side facing Earth at t = 0.
	m.rotation_period = m.orbital_period()
	var p: DVec3 = m.state_at(0.0)[0]
	m.rotation_offset = atan2(p.x, p.z) + PI * 0.5
	return e


static func find(root: CelestialBody, name: String) -> CelestialBody:
	if root.name == name:
		return root
	for c in root.children:
		var f := find(c, name)
		if f != null:
			return f
	return null


## Launch site: Baikonur.
const LAUNCH_LAT := 45.965
const LAUNCH_LON := 63.305
