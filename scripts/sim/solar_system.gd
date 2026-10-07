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


## Launch site: Baikonur.
const LAUNCH_LAT := 45.965
const LAUNCH_LON := 63.305
