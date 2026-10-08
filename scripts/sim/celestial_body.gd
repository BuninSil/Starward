class_name CelestialBody
extends RefCounted
## Physical data of one body. Distances in metres (already scaled 1:10), time in seconds.

var name: String
var radius: float
var mu: float                       ## gravitational parameter G*M, m^3/s^2
var rotation_period: float          ## sidereal, seconds; spin axis is +Y
var rotation_offset: float = 0.0    ## spin angle at t = 0, radians
var soi_radius: float = INF

# Atmosphere (0 sea_level_density = none)
var sea_level_pressure: float = 0.0     ## atm
var sea_level_density: float = 0.0      ## kg/m^3
var scale_height: float = 1.0           ## m
var atmosphere_height: float = 0.0      ## m, above it density is treated as 0

# Orbit around the parent (patched conics). Root body has parent == null.
var parent: CelestialBody = null
var children: Array[CelestialBody] = []
var orbit_a := 0.0          ## semi-major axis, m
var orbit_e := 0.0
var orbit_inc := 0.0        ## rad, to the parent's equator (XZ plane)
var orbit_lan := 0.0        ## longitude of ascending node, rad
var orbit_argp := 0.0       ## argument of periapsis, rad
var orbit_m0 := 0.0         ## mean anomaly at t = 0, rad

var terrain: Terrain = null   ## surface relief (null = smooth sphere)

var color: Color = Color.WHITE
var atmosphere_color: Color = Color(0.35, 0.6, 1.0)


func add_child_body(c: CelestialBody) -> void:
	c.parent = self
	children.append(c)
	# Laplace SOI radius.
	c.soi_radius = c.orbit_a * pow(c.mu / mu, 0.4)


func orbital_period() -> float:
	if parent == null:
		return INF
	return TAU * sqrt(pow(orbit_a, 3) / parent.mu)


## [pos, vel] relative to the parent at time t.
func state_at(t: float) -> Array:
	if parent == null:
		return [DVec3.new(), DVec3.new()]
	var n := TAU / orbital_period()
	return OrbitMath.state_from_elements(orbit_a, orbit_e, orbit_inc, orbit_lan, orbit_argp,
		orbit_m0 + n * t, parent.mu)


## Position relative to the root body (Earth for now) at time t.
func absolute_position(t: float) -> DVec3:
	if parent == null:
		return DVec3.new()
	return parent.absolute_position(t).add(state_at(t)[0])


func absolute_velocity(t: float) -> DVec3:
	if parent == null:
		return DVec3.new()
	return parent.absolute_velocity(t).add(state_at(t)[1])


## Terrain height (game metres above `radius`) under a body-fixed direction.
func surface_height(fixed_dir: DVec3) -> float:
	return terrain.height_at(fixed_dir, radius) if terrain != null else 0.0


func surface_gravity() -> float:
	return mu / (radius * radius)


func has_atmosphere() -> bool:
	return sea_level_density > 0.0 and atmosphere_height > 0.0


func density_at(altitude: float) -> float:
	if not has_atmosphere() or altitude >= atmosphere_height:
		return 0.0
	return sea_level_density * exp(-maxf(altitude, 0.0) / scale_height)


func pressure_at(altitude: float) -> float:
	if not has_atmosphere() or altitude >= atmosphere_height:
		return 0.0
	return sea_level_pressure * exp(-maxf(altitude, 0.0) / scale_height)


func angular_velocity() -> float:
	return TAU / rotation_period


## Spin angle at time t.
func rotation_angle(t: float) -> float:
	return rotation_offset + angular_velocity() * t


## Body-fixed -> inertial (both centred on the body).
func fixed_to_inertial(p: DVec3, t: float) -> DVec3:
	return p.rotated_y(rotation_angle(t))


func inertial_to_fixed(p: DVec3, t: float) -> DVec3:
	return p.rotated_y(-rotation_angle(t))


## Unit vector in body-fixed frame for latitude/longitude in degrees.
static func surface_normal(lat_deg: float, lon_deg: float) -> DVec3:
	var la := deg_to_rad(lat_deg)
	var lo := deg_to_rad(lon_deg)
	return DVec3.new(cos(la) * cos(lo), sin(la), -cos(la) * sin(lo))


## Body-fixed position -> [lat_deg, lon_deg].
static func lat_lon(p: DVec3) -> Vector2:
	var r := p.length()
	if r <= 0.0:
		return Vector2.ZERO
	return Vector2(rad_to_deg(asin(clampf(p.y / r, -1.0, 1.0))), rad_to_deg(atan2(-p.z, p.x)))
