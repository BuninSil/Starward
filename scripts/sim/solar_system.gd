class_name SolarSystem
extends RefCounted
## Body catalogue. Scale rule (see CLAUDE.md): sizes and distances are 1/10 of real,
## surface gravity is kept real (mu = g * R^2), atmospheres are scaled with sizes.
##
## Inertial frame: Earth's equator (game Y = Earth's spin axis, all bodies spin
## about Y for simplicity). Planet orbits are given in the ecliptic and tilted by
## the obliquity into this frame. Root body = the Sun.
## Epoch t = 0: 2000-06-21 (J2000 elements advanced by 172.5 days: northern summer).

const SCALE := 0.1
const G0 := 9.80665
const OBLIQUITY := 23.44           ## deg, ecliptic -> Earth equator
const EPOCH_DAYS := 172.5          ## days after J2000 at t = 0

## Launch site: Baikonur.
const LAUNCH_LAT := 45.965
const LAUNCH_LON := 63.305

## Planets: id, name, radius km, surface g, sidereal rotation h (negative =
## retrograde), a AU, e, i deg, Ω deg, ϖ deg, L deg (J2000), period days,
## atmosphere [pressure atm, density kg/m³, scale height km, top km] or [],
## colour, atmosphere colour.
const PLANETS := [
	["mercury", "Меркурий", 2439.7, 3.70, 1407.6, 0.387098, 0.205630, 7.005, 48.331, 77.456, 252.251, 87.969,
		[], Color(0.55, 0.53, 0.5), Color.BLACK],
	["venus", "Венера", 6051.8, 8.87, -5832.5, 0.723332, 0.006772, 3.39458, 76.680, 131.533, 181.980, 224.701,
		[92.0, 65.0, 15.9, 250.0], Color(0.9, 0.82, 0.6), Color(1.0, 0.88, 0.6)],
	["earth", "Земля", 6371.0, 9.81, 23.9345, 1.000001, 0.016709, 0.0, -11.261, 102.947, 100.464, 365.256,
		[1.0, 1.225, 8.5, 100.0], Color(0.2, 0.4, 0.8), Color(0.35, 0.6, 1.0)],
	["mars", "Марс", 3389.5, 3.72, 24.6229, 1.523679, 0.0934, 1.850, 49.558, 336.04, 355.453, 686.98,
		[0.006, 0.020, 11.1, 125.0], Color(0.75, 0.42, 0.25), Color(0.85, 0.6, 0.45)],
	["jupiter", "Юпитер", 69911.0, 24.79, 9.925, 5.2026, 0.048498, 1.303, 100.464, 14.331, 34.351, 4332.59,
		[1.0, 0.16, 27.0, 400.0], Color(0.8, 0.7, 0.55), Color(0.85, 0.75, 0.6)],
	["saturn", "Сатурн", 58232.0, 10.44, 10.656, 9.5549, 0.05555, 2.489, 113.665, 93.057, 50.077, 10759.22,
		[1.0, 0.19, 59.5, 700.0], Color(0.88, 0.8, 0.6), Color(0.9, 0.85, 0.65)],
	["uranus", "Уран", 25362.0, 8.69, -17.24, 19.2184, 0.046381, 0.773, 74.006, 173.005, 314.055, 30688.5,
		[1.0, 0.42, 27.7, 350.0], Color(0.6, 0.85, 0.9), Color(0.6, 0.9, 0.95)],
	["neptune", "Нептун", 24622.0, 11.15, 16.11, 30.1104, 0.009456, 1.770, 131.784, 48.124, 304.349, 60182.0,
		[1.0, 0.45, 19.7, 250.0], Color(0.3, 0.45, 0.9), Color(0.35, 0.5, 1.0)],
]
const AU := 149_597_870_700.0


static func sun() -> CelestialBody:
	var b := CelestialBody.new()
	b.id = "sun"
	b.name = "Солнце"
	b.radius = 695_700_000.0 * SCALE
	b.mu = 274.0 * b.radius * b.radius
	b.rotation_period = 25.38 * 86400.0
	b.is_star = true
	b.color = Color(1.0, 0.95, 0.85)
	return b


static func planet(row: Array) -> CelestialBody:
	var b := CelestialBody.new()
	b.id = row[0]
	b.name = row[1]
	b.radius = float(row[2]) * 1000.0 * SCALE
	b.mu = float(row[3]) * b.radius * b.radius
	b.rotation_period = float(row[4]) * 3600.0
	b.orbit_a = float(row[5]) * AU * SCALE
	b.orbit_e = row[6]
	b.orbit_inc = deg_to_rad(row[7])
	b.orbit_lan = deg_to_rad(row[8])
	b.orbit_argp = deg_to_rad(float(row[9]) - float(row[8]))
	var mean_lon := float(row[10]) + 360.0 * EPOCH_DAYS / float(row[11])
	b.orbit_m0 = deg_to_rad(fposmod(mean_lon - float(row[9]), 360.0))
	b.orbit_tilt = deg_to_rad(OBLIQUITY)
	var atm: Array = row[12]
	if not atm.is_empty():
		b.sea_level_pressure = atm[0]
		b.sea_level_density = atm[1]
		b.scale_height = float(atm[2]) * 1000.0 * SCALE
		b.atmosphere_height = float(atm[3]) * 1000.0 * SCALE
	b.color = row[13]
	b.atmosphere_color = row[14]
	return b


static func earth() -> CelestialBody:
	for row in PLANETS:
		if row[0] == "earth":
			var e := planet(row)
			e.soi_radius = 924_000_000.0 * SCALE   # until attached to the Sun (standalone tests)
			return e
	return null


static func moon() -> CelestialBody:
	var b := CelestialBody.new()
	b.id = "moon"
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


## Small moon of Mars: radius km, g, a km, e, i deg (to the ecliptic, simplified), M0 deg.
static func small_moon(id: String, name: String, r_km: float, g: float, a_km: float, e: float,
		i_deg: float, m0_deg: float) -> CelestialBody:
	var b := CelestialBody.new()
	b.id = id
	b.name = name
	b.radius = r_km * 1000.0 * SCALE
	b.mu = g * b.radius * b.radius
	b.orbit_a = a_km * 1000.0 * SCALE
	b.orbit_e = e
	b.orbit_inc = deg_to_rad(i_deg)
	b.orbit_m0 = deg_to_rad(m0_deg)
	b.orbit_tilt = deg_to_rad(OBLIQUITY + 1.85)
	b.min_soi = b.radius * 4.0
	b.color = Color(0.45, 0.4, 0.36)
	return b


## The whole system. Returns the root (the Sun).
static func build() -> CelestialBody:
	var s := sun()
	for row in PLANETS:
		s.add_child_body(planet(row))
	var e := find(s, "Земля")
	var m := moon()
	e.add_child_body(m)
	var mars := find(s, "Марс")
	var phobos := small_moon("phobos", "Фобос", 11.27, 0.0057, 9376.0, 0.0151, 1.08, 40.0)
	var deimos := small_moon("deimos", "Деймос", 6.2, 0.003, 23463.0, 0.00033, 1.79, 200.0)
	mars.add_child_body(phobos)
	mars.add_child_body(deimos)
	# Synchronous rotation for the small moons and the Moon.
	for c in [m, phobos, deimos]:
		var cb: CelestialBody = c
		cb.rotation_period = cb.orbital_period()
		var p: DVec3 = cb.state_at(0.0)[0]
		cb.rotation_offset = atan2(p.z, -p.x)   # body-fixed +X (lon 0) faces the parent

	# Relief: NASA maps where present (else flat), plus procedural detail.
	e.terrain = Terrain.load_for("earth", 15.0, 3, true)
	e.terrain.add_flat_spot(CelestialBody.surface_normal(LAUNCH_LAT, LAUNCH_LON), 1500.0, e.radius)
	m.terrain = Terrain.load_for("moon", 25.0, 21)
	m.terrain.set_crater_field([[3200.0, 0.5], [1000.0, 0.55], [320.0, 0.6], [100.0, 0.7], [32.0, 0.75]], 31)
	m.terrain.set_hills(45.0, 900.0, 49)
	var merc := find(s, "Меркурий")
	merc.terrain = Terrain.load_for("mercury", 25.0, 61)
	merc.terrain.set_crater_field([[3600.0, 0.55], [1100.0, 0.6], [350.0, 0.6], [110.0, 0.7], [35.0, 0.7]], 63)
	merc.terrain.set_hills(35.0, 1500.0, 69)
	find(s, "Венера").terrain = Terrain.load_for("venus", 30.0, 71)
	mars.terrain = Terrain.load_for("mars", 30.0, 81)
	mars.terrain.add_crater_layer(1200.0, 0.06, 83)
	mars.terrain.set_hills(60.0, 1800.0, 85)
	phobos.terrain = Terrain.load_for("phobos", 12.0, 91)
	phobos.terrain.set_crater_field([[600.0, 0.6], [180.0, 0.65], [55.0, 0.7], [18.0, 0.7]], 93)
	deimos.terrain = Terrain.load_for("deimos", 8.0, 97)
	deimos.terrain.set_crater_field([[400.0, 0.5], [120.0, 0.6], [40.0, 0.65]], 99)
	return s


static func find(root: CelestialBody, name: String) -> CelestialBody:
	if root.name == name or root.id == name:
		return root
	for c in root.children:
		var f := find(c, name)
		if f != null:
			return f
	return null


## Unit vector from `b`'s centre towards the Sun at time t (inertial frame).
static func sun_dir(b: CelestialBody, t: float) -> Vector3:
	var p := b.absolute_position(t)
	if p.length() < 1.0:
		return Vector3(0.62, 0.35, 0.7).normalized()   # the Sun itself: any direction
	return p.mul(-1.0).normalized().to_v3()
