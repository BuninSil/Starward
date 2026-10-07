extends Node3D
## Visual planet: coarse textured sphere, atmosphere rim and a detailed ground patch
## around the launch site. Positioned every frame relative to the active vessel
## (floating origin: the vessel is always at the scene origin).

const ATMO_SHADER := preload("res://shaders/atmosphere_rim.gdshader")

const SPHERE_SEGMENTS := 384      ## facet sag ~20 m at R = 637 km
const PAD_RADIUS := 30.0
const CAP_RADIUS := 45_000.0      ## ground patch radius around the launch site

var body: CelestialBody
var site_lat := 0.0
var site_lon := 0.0

var _spin: Node3D          ## rotates with the planet, centred on it
var _surface: MeshInstance3D
var _atmosphere: MeshInstance3D
var _site: Node3D          ## ground patch, positioned in double precision
var _site_normal_fixed: DVec3


func setup(b: CelestialBody, lat: float, lon: float, sun_dir: Vector3) -> void:
	body = b
	site_lat = lat
	site_lon = lon
	_site_normal_fixed = CelestialBody.surface_normal(lat, lon)

	_spin = Node3D.new()
	add_child(_spin)

	var mesh := SphereMesh.new()
	mesh.radius = b.radius
	mesh.height = b.radius * 2.0
	mesh.radial_segments = SPHERE_SEGMENTS
	mesh.rings = SPHERE_SEGMENTS / 2
	mesh.material = _make_surface_material()
	_surface = MeshInstance3D.new()
	_surface.mesh = mesh
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# SphereMesh puts u=0 at -X; rotate so texture longitude roughly matches.
	_spin.add_child(_surface)

	if b.has_atmosphere():
		var am := SphereMesh.new()
		am.radius = b.radius + b.atmosphere_height
		am.height = am.radius * 2.0
		am.radial_segments = 96
		am.rings = 48
		var mat := ShaderMaterial.new()
		mat.shader = ATMO_SHADER
		mat.render_priority = 1
		mat.set_shader_parameter("glow_color", b.atmosphere_color)
		mat.set_shader_parameter("sun_dir_world", sun_dir)
		mat.set_shader_parameter("power", 5.0)
		mat.set_shader_parameter("intensity", 1.6)
		am.material = mat
		_atmosphere = MeshInstance3D.new()
		_atmosphere.mesh = am
		_atmosphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_atmosphere)

	_site = Node3D.new()
	_site.top_level = true
	add_child(_site)
	_build_site()


## origin_rel: planet centre relative to the vessel (inertial axes), double precision.
func update_view(origin_rel: DVec3, t: float) -> void:
	position = origin_rel.to_v3()
	_spin.basis = Basis(Vector3.UP, body.rotation_angle(t))
	# Ground patch: compute its world position in doubles relative to the vessel,
	# then undo the parent offset so float error stays small near the vessel.
	var n := body.fixed_to_inertial(_site_normal_fixed, t)
	var site_rel := origin_rel.add(n.mul(body.radius))
	var up := n.to_v3()
	var east := Vector3.UP.cross(up).normalized()
	var north := up.cross(east)
	var site_basis := Basis(east, up, -north)
	# top_level: transform is global, computed from doubles relative to the vessel,
	# so the pad never inherits the float error of the planet centre offset.
	_site.global_transform = Transform3D(site_basis, site_rel.to_v3())


func _make_surface_material() -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = 3
	noise.frequency = 0.0035
	noise.fractal_octaves = 7
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.46, 0.5, 0.52, 0.62, 0.74, 0.84])
	ramp.colors = PackedColorArray([
		Color(0.02, 0.07, 0.22), Color(0.05, 0.2, 0.45), Color(0.76, 0.7, 0.5),
		Color(0.24, 0.42, 0.17), Color(0.15, 0.32, 0.12), Color(0.45, 0.38, 0.3),
		Color(0.95, 0.96, 0.98)])
	var tex := NoiseTexture2D.new()
	tex.width = 2048
	tex.height = 1024
	tex.seamless = true
	tex.noise = noise
	tex.color_ramp = ramp
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = 0.9
	return mat


## Spherical cap around the launch site with real curvature, plus the pad.
func _build_site() -> void:
	var r := body.radius
	var rings := 48
	var segs := 64
	var max_a := CAP_RADIUS / r
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var noise := FastNoiseLite.new()
	noise.seed = 11
	noise.frequency = 0.0008
	var verts: Array[Vector3] = []
	var cols: Array[Color] = []
	# Ring 0 = centre point.
	for i in rings + 1:
		var f := float(i) / rings
		var a := max_a * f * f          # denser near the pad
		var dist := a * r
		var count := 1 if i == 0 else segs
		for j in count:
			var phi := TAU * j / segs
			var p := Vector3(r * sin(a) * cos(phi), r * cos(a) - r, r * sin(a) * sin(phi))
			verts.append(p)
			var c: Color
			if dist < PAD_RADIUS:
				c = Color(0.55, 0.55, 0.55)
			else:
				var n := noise.get_noise_2d(p.x, p.z) * 0.5 + 0.5
				c = Color(0.34, 0.33, 0.2).lerp(Color(0.22, 0.36, 0.14), n)
				# fade into the sphere texture tint at the edge
				c = c.lerp(Color(0.2, 0.38, 0.16), clampf((f - 0.7) / 0.3, 0.0, 1.0))
			cols.append(c)
	var idx := func(i: int, j: int) -> int:
		return 0 if i == 0 else 1 + (i - 1) * segs + (j % segs)
	for i in rings:
		for j in segs:
			if i == 0:
				_tri(st, verts, cols, 0, idx.call(1, j), idx.call(1, j + 1))
			else:
				var a0: int = idx.call(i, j)
				var a1: int = idx.call(i, j + 1)
				var b0: int = idx.call(i + 1, j)
				var b1: int = idx.call(i + 1, j + 1)
				_tri(st, verts, cols, a0, b1, a1)
				_tri(st, verts, cols, a0, b0, b1)
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.95
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_site.add_child(mi)

	# Launch tower next to the rocket.
	var tower := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(2.0, 20.0, 2.0)
	tower.mesh = tm
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(0.7, 0.25, 0.15)
	tmat.roughness = 0.7
	tower.material_override = tmat
	tower.position = Vector3(5.0, 10.0, 0.0)
	_site.add_child(tower)


func _tri(st: SurfaceTool, v: Array[Vector3], c: Array[Color], a: int, b: int, d: int) -> void:
	for k in [a, b, d]:
		st.set_color(c[k])
		st.add_vertex(v[k])
