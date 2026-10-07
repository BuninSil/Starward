class_name DVec3
extends RefCounted
## 64-bit 3D vector. GDScript float is double, Vector3 is single precision:
## all orbital state lives in DVec3 and only small relative offsets go to the scene.

var x: float
var y: float
var z: float


func _init(px: float = 0.0, py: float = 0.0, pz: float = 0.0) -> void:
	x = px
	y = py
	z = pz


static func from_v3(v: Vector3) -> DVec3:
	return DVec3.new(v.x, v.y, v.z)


func to_v3() -> Vector3:
	return Vector3(x, y, z)


func copy() -> DVec3:
	return DVec3.new(x, y, z)


func add(o: DVec3) -> DVec3:
	return DVec3.new(x + o.x, y + o.y, z + o.z)


func sub(o: DVec3) -> DVec3:
	return DVec3.new(x - o.x, y - o.y, z - o.z)


func mul(s: float) -> DVec3:
	return DVec3.new(x * s, y * s, z * s)


## In-place this += o * s (hot path of the integrator).
func add_scaled(o: DVec3, s: float) -> void:
	x += o.x * s
	y += o.y * s
	z += o.z * s


func dot(o: DVec3) -> float:
	return x * o.x + y * o.y + z * o.z


func cross(o: DVec3) -> DVec3:
	return DVec3.new(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)


func length() -> float:
	return sqrt(x * x + y * y + z * z)


func length_squared() -> float:
	return x * x + y * y + z * z


func normalized() -> DVec3:
	var l := length()
	return DVec3.new(x / l, y / l, z / l) if l > 0.0 else DVec3.new()


## Rotation about the +Y axis (planet spin axis) by angle a.
func rotated_y(a: float) -> DVec3:
	var c := cos(a)
	var s := sin(a)
	return DVec3.new(c * x + s * z, y, -s * x + c * z)


func _to_string() -> String:
	return "(%.3f, %.3f, %.3f)" % [x, y, z]
