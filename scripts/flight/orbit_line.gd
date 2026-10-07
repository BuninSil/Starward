extends Node3D
## Orbit ribbon + apoapsis/periapsis/vessel markers. Lives at the planet centre with
## inertial axes (not rotating). Rebuilt when called; cheap (~200 points).

const POINTS := 180

var _mesh := ImmediateMesh.new()
var _line: MeshInstance3D
var _apo: Label3D
var _peri: Label3D
var _ship: Label3D


func _ready() -> void:
	_line = MeshInstance3D.new()
	_line.mesh = _mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.35, 0.85, 1.0)
	mat.vertex_color_use_as_albedo = true
	_line.material_override = mat
	_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_line)
	_apo = _marker(Color(1.0, 0.8, 0.35))
	_peri = _marker(Color(0.55, 1.0, 0.6))
	_ship = _marker(Color(1, 1, 1))
	_ship.text = "▲"


func _marker(c: Color) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0012
	l.font_size = 30
	l.outline_size = 8
	l.modulate = c
	l.no_depth_test = true
	l.render_priority = 10
	add_child(l)
	return l


## rel_pos: vessel position relative to body centre. cam_dist: camera distance (for width).
func rebuild(el: Dictionary, body: CelestialBody, rel_pos: DVec3, cam_dist: float) -> void:
	_mesh.clear_surfaces()
	_ship.position = rel_pos.to_v3()
	var max_r := minf(body.soi_radius, body.radius * 40.0)
	var pts := OrbitMath.orbit_points(el, POINTS, max_r)
	if pts.size() < 2:
		_apo.visible = false
		_peri.visible = false
		return
	var normal := (el.h as DVec3).normalized().to_v3()
	var width := cam_dist * 0.0035
	var bound: bool = el.e < 1.0
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in pts.size():
		var p := pts[i]
		var nxt := pts[mini(i + 1, pts.size() - 1)]
		var prv := pts[maxi(i - 1, 0)]
		var tangent := (nxt - prv).normalized()
		var side := normal.cross(tangent) * width
		# Below the surface: dim (hidden by the planet anyway).
		var col := Color(0.35, 0.85, 1.0)
		_mesh.surface_set_color(col)
		_mesh.surface_add_vertex(p - side)
		_mesh.surface_set_color(col)
		_mesh.surface_add_vertex(p + side)
	_mesh.surface_end()

	var peri_dir: Vector3 = pts[POINTS / 2].normalized() if bound else pts[pts.size() / 2].normalized()
	if (el.e_vec as DVec3).length() > 1e-6:
		peri_dir = (el.e_vec as DVec3).normalized().to_v3()
	_peri.visible = el.e > 0.002
	_peri.position = peri_dir * el.periapsis
	_peri.text = "Пе %s" % fmt_dist(el.periapsis - body.radius)
	_apo.visible = bound and el.e > 0.002
	if _apo.visible:
		_apo.position = -peri_dir * el.apoapsis
		_apo.text = "Ап %s" % fmt_dist(el.apoapsis - body.radius)


static func fmt_dist(m: float) -> String:
	if is_inf(m):
		return "∞"
	if absf(m) < 10_000.0:
		return "%d м" % int(m)
	if absf(m) < 10_000_000.0:
		return "%.1f км" % (m / 1000.0)
	return "%d км" % int(m / 1000.0)
