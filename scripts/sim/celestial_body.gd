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

var color: Color = Color.WHITE
var atmosphere_color: Color = Color(0.35, 0.6, 1.0)


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
