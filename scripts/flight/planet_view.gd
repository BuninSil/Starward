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
var _atmo_mat: ShaderMaterial
var _site: Node3D          ## ground patch, positioned in double precision
var _site_normal_fixed: DVec3
var _launch_normal_fixed: DVec3
var _has_launch_pad := false
var _patch_built := true


## with_site: build the detailed launch pad patch at lat/lon (Earth only for now).
func setup(b: CelestialBody, with_site: bool, lat: float, lon: float, sun_dir: Vector3) -> void:
	body = b
	site_lat = lat
	site_lon = lon
	_site_normal_fixed = CelestialBody.surface_normal(lat, lon)
	name = b.name

	_spin = Node3D.new()
	add_child(_spin)

	_surface = MeshInstance3D.new()
	_surface.mesh = _build_globe(_globe_segments())
	_surface.material_override = _make_star_material() if b.is_star else (
		_make_gas_material() if _is_gas_giant() else _make_surface_material())
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spin.add_child(_surface)
	if b.id == "saturn":
		_build_rings(1.24, 2.27)
	if b.id == "venus":
		_build_clouds(7000.0)

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
		_atmo_mat = mat
		_atmosphere = MeshInstance3D.new()
		_atmosphere.mesh = am
		_atmosphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_atmosphere)

	_site = Node3D.new()
	_site.top_level = true
	add_child(_site)
	_launch_normal_fixed = _site_normal_fixed
	_has_launch_pad = with_site
	if with_site:
		_build_site(true)
	else:
		_site.visible = false
		_patch_built = false


## Globe resolution: detailed for bodies you land on, light for the rest.
func _globe_segments() -> int:
	match body.id:
		"earth":
			return SPHERE_SEGMENTS
		"moon", "mars", "mercury", "venus":
			return 256
		"phobos", "deimos":
			return 96
	return 128


func _is_gas_giant() -> bool:
	return body.id in ["jupiter", "saturn", "uranus", "neptune"]


func _make_star_material() -> Material:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.93, 0.78)
	return m


const GAS_SHADER := preload("res://shaders/planet_gas.gdshader")
const RINGS_SHADER := preload("res://shaders/planet_rings.gdshader")


func _make_gas_material() -> Material:
	var m := ShaderMaterial.new()
	m.shader = GAS_SHADER
	var noise := FastNoiseLite.new()
	noise.seed = hash(body.id) % 1000
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.01
	noise.fractal_octaves = 5
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 256
	tex.seamless = true
	tex.noise = noise
	m.set_shader_parameter("turbulence", tex)
	match body.id:
		"jupiter":
			m.set_shader_parameter("color_a", Color(0.88, 0.8, 0.68))
			m.set_shader_parameter("color_b", Color(0.66, 0.47, 0.33))
			m.set_shader_parameter("color_c", Color(0.97, 0.94, 0.88))
			m.set_shader_parameter("bands", 16.0)
		"saturn":
			m.set_shader_parameter("color_a", Color(0.9, 0.84, 0.66))
			m.set_shader_parameter("color_b", Color(0.78, 0.68, 0.5))
			m.set_shader_parameter("color_c", Color(0.95, 0.9, 0.78))
			m.set_shader_parameter("bands", 18.0)
			m.set_shader_parameter("contrast", 0.6)
		"uranus":
			m.set_shader_parameter("color_a", Color(0.66, 0.87, 0.9))
			m.set_shader_parameter("color_b", Color(0.58, 0.8, 0.86))
			m.set_shader_parameter("color_c", Color(0.75, 0.92, 0.94))
			m.set_shader_parameter("bands", 8.0)
			m.set_shader_parameter("contrast", 0.25)
		"neptune":
			m.set_shader_parameter("color_a", Color(0.3, 0.47, 0.92))
			m.set_shader_parameter("color_b", Color(0.22, 0.36, 0.8))
			m.set_shader_parameter("color_c", Color(0.6, 0.72, 0.98))
			m.set_shader_parameter("bands", 10.0)
			m.set_shader_parameter("contrast", 0.45)
	return m


var _clouds: MeshInstance3D = null
var _cloud_top := 0.0


## Opaque cloud deck (Venus): hides the surface from orbit; disappears once the
## vessel descends below it (the haze takes over).
func _build_clouds(alt: float) -> void:
	_cloud_top = body.radius + alt
	var sm := SphereMesh.new()
	sm.radius = _cloud_top
	sm.height = _cloud_top * 2.0
	sm.radial_segments = 96
	sm.rings = 48
	var m := ShaderMaterial.new()
	m.shader = GAS_SHADER
	var noise := FastNoiseLite.new()
	noise.seed = 77
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.008
	noise.fractal_octaves = 5
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 256
	tex.seamless = true
	tex.noise = noise
	m.set_shader_parameter("turbulence", tex)
	m.set_shader_parameter("color_a", Color(0.93, 0.86, 0.66))
	m.set_shader_parameter("color_b", Color(0.84, 0.74, 0.52))
	m.set_shader_parameter("color_c", Color(0.98, 0.95, 0.85))
	m.set_shader_parameter("bands", 6.0)
	m.set_shader_parameter("warp", 0.09)
	m.set_shader_parameter("contrast", 0.35)
	sm.material = m
	_clouds = MeshInstance3D.new()
	_clouds.mesh = sm
	_clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spin.add_child(_clouds)


## Flat ring annulus in the equatorial plane, radii in planet radii.
func _build_rings(inner: float, outer: float) -> void:
	var segs := 128
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := body.radius * inner
	var r1 := body.radius * outer
	for j in segs:
		var a0 := TAU * j / segs
		var a1 := TAU * (j + 1) / segs
		var p00 := Vector3(cos(a0), 0, sin(a0)) * r0
		var p01 := Vector3(cos(a0), 0, sin(a0)) * r1
		var p10 := Vector3(cos(a1), 0, sin(a1)) * r0
		var p11 := Vector3(cos(a1), 0, sin(a1)) * r1
		for v in [[p00, 0.0], [p01, 1.0], [p11, 1.0], [p00, 0.0], [p11, 1.0], [p10, 0.0]]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v[1], 0.5))
			st.add_vertex(v[0])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := ShaderMaterial.new()
	m.shader = RINGS_SHADER
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.frequency = 0.05
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 4
	tex.seamless = true
	tex.noise = noise
	m.set_shader_parameter("bands_tex", tex)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spin.add_child(mi)


## origin_rel: planet centre relative to the vessel (inertial axes), double precision.
## view_scale < 1: far body drawn closer and smaller with the same angular size
## (keeps the camera depth range small).
func update_view(origin_rel: DVec3, t: float, view_scale := 1.0) -> void:
	position = origin_rel.mul(view_scale).to_v3()
	scale = Vector3.ONE * view_scale
	_spin.basis = Basis(Vector3.UP, body.rotation_angle(t))
	if _clouds:
		var cam := get_viewport().get_camera_3d()
		var cam_d := cam.global_position.distance_to(position) / maxf(view_scale, 1e-12) if cam else origin_rel.length()
		_clouds.visible = cam_d > _cloud_top
	if _atmo_mat:
		_atmo_mat.set_shader_parameter("sun_dir_world", SolarSystem.sun_dir(body, t))
	_poll_patch_task()
	if _site == null or not _patch_built:
		return
	_site.visible = view_scale >= 0.999
	if not _site.visible:
		return
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
	if _patch_material is ShaderMaterial:
		(_patch_material as ShaderMaterial).set_shader_parameter("sun_local",
			(site_basis.inverse() * SolarSystem.sun_dir(body, t)).normalized())


## Body id used for asset file names.
func _asset_id() -> String:
	return body.id


## UV sphere in the body-fixed frame with u/v = longitude/latitude (matches the
## NASA maps), vertices displaced by the map height. Built from packed arrays
## (analytic normals/tangents): SurfaceTool is too slow for ~75k vertices on phones.
func _build_globe(segs: int) -> ArrayMesh:
	var rings := segs / 2
	var nv := (rings + 1) * (segs + 1)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	verts.resize(nv)
	normals.resize(nv)
	tangents.resize(nv * 4)
	uvs.resize(nv)
	var k := 0
	for i in rings + 1:
		var lat := 90.0 - 180.0 * i / rings
		var la := deg_to_rad(lat)
		var cl := cos(la)
		var sl := sin(la)
		for j in segs + 1:
			var lon := -180.0 + 360.0 * j / segs
			var lo := deg_to_rad(lon)
			var n := Vector3(cl * cos(lo), sl, -cl * sin(lo))
			var r := body.radius + (body.terrain.globe_height(lat, lon) if body.terrain != null else 0.0)
			verts[k] = n * r
			normals[k] = n
			# Tangent = east (direction of increasing u), binormal sign +1.
			tangents[k * 4] = -sin(lo)
			tangents[k * 4 + 1] = 0.0
			tangents[k * 4 + 2] = -cos(lo)
			tangents[k * 4 + 3] = 1.0
			uvs[k] = Vector2(float(j) / segs, float(i) / rings)
			k += 1
	var idx := PackedInt32Array()
	idx.resize(rings * segs * 6)
	k = 0
	for i in rings:
		for j in segs:
			var a := i * (segs + 1) + j
			var b2 := a + segs + 1
			idx[k] = a
			idx[k + 1] = a + 1
			idx[k + 2] = b2
			idx[k + 3] = a + 1
			idx[k + 4] = b2 + 1
			idx[k + 5] = b2
			k += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TANGENT] = tangents
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


const SURFACE_SHADER := preload("res://shaders/planet_surface.gdshader")


## Globe material: NASA maps through the planet shader (water on Earth), or the
## old procedural noise texture when the maps are missing.
func _make_surface_material() -> Material:
	var id := _asset_id()
	var color_path := "res://assets/planets/%s_color.jpg" % id
	if not ResourceLoader.exists(color_path):
		return _make_noise_material()
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("albedo_tex", load(color_path))
	var np := "res://assets/planets/%s_normal.png" % id
	m.set_shader_parameter("use_normal_tex", ResourceLoader.exists(np))
	if ResourceLoader.exists(np):
		m.set_shader_parameter("normal_tex", load(np))
	m.set_shader_parameter("normal_strength", 0.8 if body.has_atmosphere() else 0.55)
	var wp := "res://assets/planets/%s_water.png" % id
	m.set_shader_parameter("has_water", ResourceLoader.exists(wp))
	if ResourceLoader.exists(wp):
		m.set_shader_parameter("water_tex", load(wp))
	m.set_shader_parameter("land_roughness", 0.85 if body.has_atmosphere() else 1.0)
	var st := surface_style()
	m.set_shader_parameter("albedo_target", st.albedo)
	m.set_shader_parameter("map_mean", st.map_mean)
	m.set_shader_parameter("ground_color", (st.ground as Color).srgb_to_linear())
	m.set_shader_parameter("recolor", st.recolor)
	m.set_shader_parameter("regolith", 0.0 if body.has_atmosphere() else 1.0)
	return m


func _make_noise_material() -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = 3
	noise.frequency = 0.0035
	noise.fractal_octaves = 7
	var ramp := Gradient.new()
	if body.id != "earth" and body.id != "moon":
		# Generic rocky body: darker and lighter shades of its colour.
		noise.seed = hash(body.id) % 1000
		var c := body.color
		ramp.offsets = PackedFloat32Array([0.0, 0.4, 0.6, 1.0])
		ramp.colors = PackedColorArray([c.darkened(0.45), c.darkened(0.15), c, c.lightened(0.25)])
	elif body.has_atmosphere():
		ramp.offsets = PackedFloat32Array([0.0, 0.46, 0.5, 0.52, 0.62, 0.74, 0.84])
		ramp.colors = PackedColorArray([
			Color(0.02, 0.07, 0.22), Color(0.05, 0.2, 0.45), Color(0.76, 0.7, 0.5),
			Color(0.24, 0.42, 0.17), Color(0.15, 0.32, 0.12), Color(0.45, 0.38, 0.3),
			Color(0.95, 0.96, 0.98)])
	else:
		# Airless grey body: dark maria and bright highlands.
		noise.seed = 21
		noise.frequency = 0.006
		ramp.offsets = PackedFloat32Array([0.0, 0.38, 0.48, 0.62, 1.0])
		ramp.colors = PackedColorArray([
			Color(0.22, 0.22, 0.23), Color(0.3, 0.3, 0.31), Color(0.5, 0.49, 0.47),
			Color(0.62, 0.61, 0.58), Color(0.78, 0.77, 0.74)])
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


## Spherical cap around the launch site with real curvature and map relief, plus the pad.
## Makes sure the detailed ground patch covers `fixed_normal` (body-fixed unit
## vector). Rebuilds it in a worker thread when the vessel moved away from its
## centre; the old patch stays until the new one is ready. Returns true if started.
func ensure_patch(fixed_normal: DVec3, height := 0.0) -> bool:
	if body.is_star or _is_gas_giant():
		return false   # nothing to stand on
	_poll_patch_task()
	if _patch_task >= 0:
		return false
	# Low over the ground the fine centre of the patch must stay under the vessel.
	var keep := clampf(height * 0.5, 150.0, CAP_RADIUS * 0.15)
	if _patch_built and _site_normal_fixed.dot(fixed_normal) > cos(keep / body.radius):
		return false
	var near_pad := _has_launch_pad and _launch_normal_fixed.dot(fixed_normal) > cos(maxf(keep, 300.0) / body.radius)
	var centre := _launch_normal_fixed if near_pad else fixed_normal.normalized()
	_patch_result = {}
	_patch_task = WorkerThreadPool.add_task(func() -> void: _patch_result = _compute_patch(centre, near_pad))
	return true


var _patch_task := -1
var _patch_result: Dictionary = {}


func _poll_patch_task() -> void:
	if _patch_task < 0 or not WorkerThreadPool.is_task_completed(_patch_task):
		return
	WorkerThreadPool.wait_for_task_completion(_patch_task)
	_patch_task = -1
	if not _patch_result.is_empty():
		_apply_patch(_patch_result)
		_patch_result = {}


func _exit_tree() -> void:
	if _patch_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_patch_task)
		_patch_task = -1


func _build_site(with_pad := true) -> void:
	_apply_patch(_compute_patch(_site_normal_fixed, with_pad))


## Pure data (safe on a worker thread): patch vertices in the site frame
## (x east, y up, z south; origin on the reference sphere under the centre).
func _compute_patch(centre: DVec3, with_pad: bool) -> Dictionary:
	var r := body.radius
	var rings := 128
	var segs := 128
	var max_a := minf(CAP_RADIUS / r, 0.5)   # small moons: a cap, not a wrap-around
	var up_f := centre.normalized()
	var east_f := DVec3.new(0, 1, 0).cross(up_f).normalized()
	var south_f := east_f.cross(up_f)
	var lon0 := CelestialBody.lat_lon(up_f).y
	var nv := 1 + rings * segs
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	verts.resize(nv)
	uvs.resize(nv)
	uv2s.resize(nv)
	var k := 0
	# Ring 0 = centre point.
	for i in rings + 1:
		var f := float(i) / rings
		var a := max_a * f * f * f      # dense near the centre: ~1 m at 10 m, ~5 m at 100 m
		var count := 1 if i == 0 else segs
		for j in count:
			var phi := TAU * j / segs
			var d := east_f.mul(sin(a) * cos(phi)).add(up_f.mul(cos(a))).add(south_f.mul(sin(a) * sin(phi)))
			var rr := r + body.surface_height(d)
			var p := Vector3(rr * sin(a) * cos(phi), rr * cos(a) - r, rr * sin(a) * sin(phi))
			verts[k] = p
			var g := CelestialBody.lat_lon(d)
			var lon := lon0 + wrapf(g.y - lon0, -180.0, 180.0)   # continuous across the date line
			uvs[k] = Vector2((lon + 180.0) / 360.0, (90.0 - g.x) / 180.0)
			uv2s[k] = Vector2(p.x, p.z)   # metres, the shader scales the detail
			k += 1
	var idx := PackedInt32Array()
	for i in rings:
		for j in segs:
			if i == 0:
				idx.append_array([0, 1 + j, 1 + (j + 1) % segs])
			else:
				var a0 := 1 + (i - 1) * segs + j
				var a1 := 1 + (i - 1) * segs + (j + 1) % segs
				var b0 := a0 + segs
				var b1 := a1 + segs
				idx.append_array([a0, b1, a1, a0, b0, b1])
	# Smooth normals: area-weighted face normals (winding: front faces are clockwise).
	var normals := PackedVector3Array()
	normals.resize(nv)
	for t in range(0, idx.size(), 3):
		var v0 := verts[idx[t]]
		var fn := (verts[idx[t + 2]] - v0).cross(verts[idx[t + 1]] - v0)
		normals[idx[t]] += fn
		normals[idx[t + 1]] += fn
		normals[idx[t + 2]] += fn
	# Tangents along +x (east, = increasing u), same convention as the globe.
	var tangents := PackedFloat32Array()
	tangents.resize(nv * 4)
	for n in nv:
		var nn := normals[n].normalized()
		normals[n] = nn
		var tg := (Vector3.RIGHT - nn * nn.x).normalized()
		tangents[n * 4] = tg.x
		tangents[n * 4 + 1] = tg.y
		tangents[n * 4 + 2] = tg.z
		tangents[n * 4 + 3] = 1.0
	# Slope per vertex (0 flat .. 1 vertical) for rocky shading on steep ground.
	var cols := PackedColorArray()
	cols.resize(nv)
	# Plus crater marks: G = ejecta / rays of young craters, B = crater walls and rims.
	var marked := body.terrain != null and body.terrain.has_crater_field()
	k = 0
	for i in rings + 1:
		var f := float(i) / rings
		var a := max_a * f * f * f
		var count := 1 if i == 0 else segs
		for j in count:
			var slope := 1.0 - clampf(normals[k].dot(Vector3.UP), 0.0, 1.0)
			var mk := Vector2.ZERO
			if marked:
				var phi := TAU * j / segs
				var d := east_f.mul(sin(a) * cos(phi)).add(up_f.mul(cos(a))).add(south_f.mul(sin(a) * sin(phi)))
				mk = body.terrain.surface_marks(d, r)
			cols[k] = Color(slope, mk.x, mk.y)
			k += 1
	return {"centre": up_f, "with_pad": with_pad, "h0": body.surface_height(up_f),
		"verts": verts, "normals": normals, "tangents": tangents, "uvs": uvs, "uv2s": uv2s, "idx": idx,
		"colors": cols, "scatter": _compute_rocks(up_f, east_f, south_f, with_pad)}


## Scattered rocks around the patch centre (deterministic from its position),
## transforms in the site frame sitting on the exact terrain height:
##   rocks:   boulders, power-law sizes (many small, few big), partly in
##            clusters, denser on the ejecta and rims of young craters;
##   pebbles: 1–10 cm stones within ~30 m, partly as scree around rocks;
##   drifts:  (Mars) dust tails on the lee side of rocks.
func _compute_rocks(up_f: DVec3, east_f: DVec3, south_f: DVec3, with_pad: bool) -> Dictionary:
	var style := surface_style()
	var out := {"rocks": [] as Array[Transform3D], "pebbles": [] as Array[Transform3D], "drifts": [] as Array[Transform3D]}
	var count: int = style.rocks
	if Graphics.quality == Graphics.LOW:
		count /= 2
	if count <= 0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(roundi(up_f.x * 1e5), roundi(up_f.y * 1e5), roundi(up_f.z * 1e5))) + hash(body.id)
	var r := body.radius
	var max_d := 420.0
	var marked := body.terrain != null and body.terrain.has_crater_field()
	var place := func(x: float, z: float) -> Array:
		var d := sqrt(x * x + z * z)
		var a := d / r
		var phi := atan2(z, x)
		var dir := east_f.mul(sin(a) * cos(phi)).add(up_f.mul(cos(a))).add(south_f.mul(sin(a) * sin(phi)))
		return [dir, (r + body.surface_height(dir)) * cos(a) - r]
	var clusters: Array[Vector2] = []
	for i in 14:
		var cd := max_d * pow(rng.randf(), 0.6)
		var cp := rng.randf() * TAU
		clusters.append(Vector2(cd * cos(cp), cd * sin(cp)))
	var big: Array[Vector3] = []   # (x, z, size) of rocks near the centre, for scree
	var attempts := 0
	while out.rocks.size() < count and attempts < count * 5:
		attempts += 1
		var x: float
		var z: float
		if rng.randf() < 0.35:
			var c: Vector2 = clusters[rng.randi() % clusters.size()]
			var spread := rng.randf_range(4.0, 25.0)
			x = c.x + rng.randfn(0.0, spread)
			z = c.y + rng.randfn(0.0, spread)
		else:
			var d := max_d * pow(rng.randf(), 0.75)   # denser near the player
			var phi := rng.randf() * TAU
			x = d * cos(phi)
			z = d * sin(phi)
		var dd := sqrt(x * x + z * z)
		if dd < 7.0 or (with_pad and dd < PAD_RADIUS + 6.0) or dd > max_d:
			continue
		var pl: Array = place.call(x, z)
		if marked:
			var mk: Vector2 = body.terrain.surface_marks(pl[0], r)
			if rng.randf() > 0.3 + 1.6 * (mk.x + mk.y):
				continue
		# Power law: size = min * u^(-1/1.7), capped.
		var size := minf(0.12 * pow(maxf(rng.randf(), 1e-4), -1.0 / 1.7), float(style.rock_max) * rng.randf_range(0.7, 1.0))
		var sc := Vector3(size * rng.randf_range(0.8, 1.5), size * rng.randf_range(0.45, 0.9), size * rng.randf_range(0.8, 1.4))
		var bas := Basis.from_euler(Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3))).scaled(sc)
		out.rocks.append(Transform3D(bas, Vector3(x, float(pl[1]) - sc.y * 0.35, z)))
		if dd < 45.0 and size > 0.25:
			big.append(Vector3(x, z, size))
		if style.kind == 1 and size > 0.25 and dd < 200.0:
			# Dust tail downwind (+wind in the patch plane).
			var wind := Vector3(0.8, 0.0, 0.6)
			var len := size * rng.randf_range(1.4, 2.4)
			var tp := Vector3(x, 0.0, z) + wind * (sc.x * 0.4 + len * 0.45)
			var tpl: Array = place.call(tp.x, tp.z)
			var tb := Basis.looking_at(wind, Vector3.UP).scaled(Vector3(sc.x * 0.55, sc.y * 0.35, len))
			out.drifts.append(Transform3D(tb, Vector3(tp.x, float(tpl[1]) - sc.y * 0.08, tp.z)))
	var pcount: int = style.pebbles if Graphics.quality == Graphics.HIGH else 0
	for i in pcount:
		var x: float
		var z: float
		if not big.is_empty() and rng.randf() < 0.4:
			# Scree: pebbles fallen around a rock.
			var bg: Vector3 = big[rng.randi() % big.size()]
			var ang := rng.randf() * TAU
			var rad := bg.z * rng.randf_range(0.7, 2.2)
			x = bg.x + rad * cos(ang)
			z = bg.y + rad * sin(ang)
		else:
			var d := 30.0 * sqrt(rng.randf())
			var phi := rng.randf() * TAU
			x = d * cos(phi)
			z = d * sin(phi)
		if with_pad and sqrt(x * x + z * z) < PAD_RADIUS + 2.0:
			continue
		var pl: Array = place.call(x, z)
		var size := minf(0.01 * pow(maxf(rng.randf(), 1e-3), -1.0 / 1.4), 0.1)
		var sc := Vector3(size * rng.randf_range(0.8, 1.4), size * rng.randf_range(0.5, 0.9), size * rng.randf_range(0.8, 1.3))
		var bas := Basis.from_euler(Vector3(rng.randf_range(-0.4, 0.4), rng.randf() * TAU, rng.randf_range(-0.4, 0.4))).scaled(sc)
		out.pebbles.append(Transform3D(bas, Vector3(x, float(pl[1]) - sc.y * 0.3, z)))
	return out


## Per-body look of the ground up close.
func surface_style() -> Dictionary:
	# Colours are sRGB. albedo/map_mean: real mean albedo and the map's mean linear
	# luminance (tools: measured on assets/planets/<id>_color.jpg); ground: the
	# colour the map is pulled toward (luminance ~ albedo). mats: amounts of
	# fine, smooth (Mars: ripples), gravel, rock outcrops.
	var st := {"rocks": 0, "rock_max": 1.0, "rock_color": Color.GRAY, "dust_color": Color.GRAY,
		"albedo": -1.0, "map_mean": 0.3, "ground": Color.GRAY, "recolor": 0.0, "kind": 0,
		"mats": Vector4(1.0, 0.5, 0.5, 0.0), "rock_tint": Color(0.8, 0.8, 0.8), "gravel_tint": Color(0.92, 0.92, 0.92),
		"craters": 0.0, "macro_amp": 0.3, "macro_tint": Color(1.0, 1.0, 1.0), "pebbles": 0}
	match body.id:
		"moon":
			st.merge({"rocks": 1700, "rock_max": 2.4, "rock_color": Color(0.29, 0.285, 0.28), "dust_color": Color(0.39, 0.38, 0.37),
				"albedo": 0.12, "map_mean": 0.3226, "ground": Color(0.39, 0.385, 0.378), "recolor": 0.75,
				"mats": Vector4(1.0, 0.6, 0.55, 0.5), "rock_tint": Color(0.86, 0.86, 0.86), "gravel_tint": Color(1.0, 1.0, 1.0),
				"craters": 1.0, "macro_amp": 0.35, "macro_tint": Color(1.03, 1.0, 0.96), "pebbles": 2600}, true)
		"mars":
			st.merge({"rocks": 1600, "rock_max": 2.6, "rock_color": Color(0.36, 0.27, 0.22), "dust_color": Color(0.7, 0.48, 0.3),
				"albedo": 0.22, "map_mean": 0.1614, "ground": Color(0.64, 0.46, 0.33), "recolor": 0.8, "kind": 1,
				"mats": Vector4(1.0, 0.85, 0.5, 0.45), "rock_tint": Color(0.82, 0.78, 0.76), "gravel_tint": Color(0.78, 0.74, 0.74),
				"craters": 0.25, "macro_amp": 0.3, "macro_tint": Color(1.05, 0.97, 0.9), "pebbles": 2600}, true)
		"mercury":
			st.merge({"rocks": 1200, "rock_max": 2.4, "rock_color": Color(0.3, 0.29, 0.28), "dust_color": Color(0.4, 0.385, 0.37),
				"albedo": 0.12, "map_mean": 0.139, "ground": Color(0.4, 0.385, 0.365), "recolor": 0.6,
				"mats": Vector4(1.0, 0.5, 0.5, 0.5), "craters": 1.0, "pebbles": 2000}, true)
		"venus":
			st.merge({"rocks": 900, "rock_max": 2.0, "rock_color": Color(0.33, 0.26, 0.2), "dust_color": Color(0.5, 0.39, 0.28),
				"albedo": 0.18, "map_mean": 0.1346, "ground": Color(0.55, 0.42, 0.3), "recolor": 0.4,
				"mats": Vector4(1.0, 0.5, 0.4, 0.6), "pebbles": 1500}, true)
		"phobos", "deimos":
			st.merge({"rocks": 700, "rock_max": 1.6, "rock_color": Color(0.24, 0.23, 0.22), "dust_color": Color(0.3, 0.29, 0.28),
				"albedo": 0.07, "map_mean": 0.1198, "ground": Color(0.3, 0.29, 0.28), "recolor": 0.6,
				"mats": Vector4(1.0, 0.5, 0.5, 0.4), "craters": 1.0, "pebbles": 1500}, true)
		"earth":
			st.merge({"rocks": 250, "rock_max": 1.2, "rock_color": Color(0.46, 0.44, 0.41), "dust_color": Color(0.5, 0.48, 0.44),
				"mats": Vector4(1.0, 0.3, 0.2, 0.0), "pebbles": 0}, true)
	return st


func _apply_patch(res: Dictionary) -> void:
	for c in _site.get_children():
		c.queue_free()
	_site_normal_fixed = res.centre
	_patch_built = true
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = res.verts
	arr[Mesh.ARRAY_NORMAL] = res.normals
	arr[Mesh.ARRAY_TANGENT] = res.tangents
	arr[Mesh.ARRAY_TEX_UV] = res.uvs
	arr[Mesh.ARRAY_TEX_UV2] = res.uv2s
	arr[Mesh.ARRAY_COLOR] = res.colors
	arr[Mesh.ARRAY_INDEX] = res.idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if _patch_material == null:
		_patch_material = _make_patch_material()
	mi.material_override = _patch_material
	# Ground casts sun shadows (crater walls, hills) on the high preset.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Graphics.quality == Graphics.HIGH \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_site.add_child(mi)
	_add_scatter(res.scatter)
	if not res.with_pad:
		return
	var h0: float = res.h0

	# Concrete pad, sitting on the flattened terrain.
	var pad := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = PAD_RADIUS
	pm.bottom_radius = PAD_RADIUS + 1.0
	pm.height = 1.0
	pm.radial_segments = 48
	pad.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.55, 0.55, 0.55)
	pmat.roughness = 0.95
	pad.material_override = pmat
	pad.position = Vector3(0.0, h0 - 0.5, 0.0)
	_site.add_child(pad)

	# Launch tower next to the rocket.
	var tower := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(2.0, 20.0, 2.0)
	tower.mesh = tm
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(0.7, 0.25, 0.15)
	tmat.roughness = 0.7
	tower.material_override = tmat
	tower.position = Vector3(5.0, h0 + 10.0, 0.0)
	_site.add_child(tower)


var _patch_material: Material = null


## High-resolution colour block for the ground patch (from HdTiles).
func set_hd(tex: Texture2D, rect: Rect2) -> void:
	if _patch_material == null:
		_patch_material = _make_patch_material()
	if _patch_material is ShaderMaterial:
		(_patch_material as ShaderMaterial).set_shader_parameter("hd_tex", tex)
		(_patch_material as ShaderMaterial).set_shader_parameter("hd_rect", Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
static var _rocks: Array[ArrayMesh] = []
static var _pebble_mesh: ArrayMesh = null
static var _drift_mesh: ArrayMesh = null
const ROCK_VARIANTS := 7
const ROCK_SHADER := preload("res://shaders/rock.gdshader")


## Boulder meshes: a blob cut by random planes, so each rock has a few large flat
## fractured faces and sharp edges, plus a flat base. 7 variants (round, flat
## slabs, tall and angular ones) shared by all bodies, ~128 triangles each.
static func _rock_meshes() -> Array[ArrayMesh]:
	if not _rocks.is_empty():
		return _rocks
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var shapes := [Vector3(1.1, 0.8, 1.0), Vector3(1.4, 0.45, 1.1), Vector3(0.9, 1.1, 0.85), Vector3(1.2, 0.7, 0.8),
		Vector3(1.0, 0.6, 1.3), Vector3(1.3, 0.9, 1.2), Vector3(0.8, 0.55, 0.9)]
	for variant in ROCK_VARIANTS:
		_rocks.append(_make_rock(2, shapes[variant], 6 + variant, rng))
	_pebble_mesh = _make_rock(1, Vector3(1.1, 0.7, 1.0), 4, rng)
	# Dust drift: a low smooth mound, long along local +z.
	var sm := SphereMesh.new()
	sm.radial_segments = 10
	sm.rings = 5
	sm.is_hemisphere = true
	sm.radius = 1.0
	sm.height = 1.0
	_drift_mesh = ArrayMesh.new()
	_drift_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sm.get_mesh_arrays())
	return _rocks


static func _make_rock(level: int, stretch: Vector3, cuts: int, rng: RandomNumberGenerator) -> ArrayMesh:
	var base := [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
	var faces := [[0, 3, 4], [0, 4, 2], [0, 2, 5], [0, 5, 3], [1, 4, 3], [1, 2, 4], [1, 5, 2], [1, 3, 5]]
	var verts: Array[Vector3] = []
	for v in base:
		verts.append(v)
	var tris: Array = faces.duplicate()
	var mid_cache := {}
	for _level in level:
		var nt: Array = []
		for t in tris:
			var m := []
			for k in 3:
				var a: int = t[k]
				var b: int = t[(k + 1) % 3]
				var key := Vector2i(mini(a, b), maxi(a, b))
				if not mid_cache.has(key):
					verts.append(((verts[a] + verts[b]) * 0.5).normalized())
					mid_cache[key] = verts.size() - 1
				m.append(mid_cache[key])
			nt.append([t[0], m[0], m[2]])
			nt.append([t[1], m[1], m[0]])
			nt.append([t[2], m[2], m[1]])
			nt.append([m[0], m[1], m[2]])
		tris = nt
	for i in verts.size():
		verts[i] = verts[i] * stretch * rng.randf_range(0.95, 1.05)
	# Fracture planes: pull everything beyond a plane onto it.
	for c in cuts:
		var n := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.4, 1), rng.randf_range(-1, 1)).normalized()
		var d := rng.randf_range(0.45, 0.8)
		for i in verts.size():
			var e: float = verts[i].dot(n) - d
			if e > 0.0:
				verts[i] -= n * e
	for i in verts.size():   # flat base, sunk into the ground
		if verts[i].y < -0.4:
			verts[i].y = -0.4
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in tris:
		for k in [0, 2, 1]:
			st.add_vertex(verts[t[k]])
	st.generate_normals()   # flat facets
	return st.commit()


func _add_scatter(sc: Dictionary) -> void:
	var style := surface_style()
	_ground_textures()
	var meshes := _rock_meshes()
	var vrng := RandomNumberGenerator.new()
	vrng.seed = sc.rocks.size()
	var mat := func(rock: Color, dust: Color, fade: float) -> ShaderMaterial:
		var m := ShaderMaterial.new()
		m.shader = ROCK_SHADER
		m.set_shader_parameter("rock_color", rock.srgb_to_linear())
		m.set_shader_parameter("dust_color", dust.srgb_to_linear())
		m.set_shader_parameter("ground_pack", _ground_pack)
		m.set_shader_parameter("fade_end", fade)
		return m
	var add := func(mesh: Mesh, xs: Array, m: Material, shadows: bool) -> void:
		if xs.is_empty():
			return
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = xs.size()
		for i in xs.size():
			mm.set_instance_transform(i, xs[i])
			var k := vrng.randf_range(0.75, 1.15)
			mm.set_instance_color(i, Color(k, k * vrng.randf_range(0.96, 1.02), k * vrng.randf_range(0.94, 1.03)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = m
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows and Graphics.quality == Graphics.HIGH \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_site.add_child(mmi)
	var rock_m: ShaderMaterial = mat.call(style.rock_color, style.dust_color, 0.0)
	var rocks: Array = sc.rocks
	for v in meshes.size():
		var mine := []
		for i in range(v, rocks.size(), meshes.size()):
			mine.append(rocks[i])
		add.call(meshes[v], mine, rock_m, true)
	add.call(_pebble_mesh, sc.pebbles, mat.call(style.rock_color, style.dust_color, 30.0), false)
	add.call(_drift_mesh, sc.drifts, mat.call(style.dust_color, style.dust_color, 0.0), false)


## Patch material: same maps as the globe (so the edge blends) plus close-up
## ground materials on UV2 (metres) from two small packed textures shared by
## all bodies (see _ground_textures).
func _make_patch_material() -> Material:
	var m := _make_surface_material()
	if not m is ShaderMaterial:
		return m
	var sm := m as ShaderMaterial
	_ground_textures()
	sm.set_shader_parameter("use_normal_tex", false)   # real geometry here
	sm.set_shader_parameter("normal_strength", 1.0)
	sm.set_shader_parameter("use_detail", true)
	var st := surface_style()
	sm.set_shader_parameter("ground_pack", _ground_pack)
	sm.set_shader_parameter("ground_pack_normal", _ground_pack_normal)
	sm.set_shader_parameter("ground_pack_normal2", _ground_pack_normal2)
	sm.set_shader_parameter("detail_level", Graphics.quality)
	sm.set_shader_parameter("detail_strength", 0.85)
	sm.set_shader_parameter("ground_kind", st.kind)
	var rs := hash(body.id)
	sm.set_shader_parameter("macro_seed", Vector2(float(rs % 997) / 997.0, float(rs / 997 % 991) / 991.0))
	sm.set_shader_parameter("macro_amp", st.macro_amp)
	sm.set_shader_parameter("macro_tint", st.macro_tint)
	sm.set_shader_parameter("mat_amount", st.mats)
	sm.set_shader_parameter("rock_tint", st.rock_tint)
	sm.set_shader_parameter("gravel_tint", st.gravel_tint)
	sm.set_shader_parameter("crater_decals", st.craters)
	sm.set_shader_parameter("use_slope", true)
	return sm


static var _ground_pack: ImageTexture = null
static var _ground_pack_normal: ImageTexture = null
static var _ground_pack_normal2: ImageTexture = null


## Builds (once per run) the three textures of the close-up ground:
##   pack:    R = fine speckle, G = cracked rock (ridged), B = soft bumps,
##            A = sparse pebbles (0 between them);
##   normal:  RG = fine ground (bumps + speckle), BA = gravel (pebbles);
##   normal2: RG = rock, BA = soft bumps only (compacted ground, ripples).
## 512² RGBA8 with mipmaps each (~1.4 MB): ~4 MB of VRAM whatever the body.
static func _ground_textures() -> void:
	if _ground_pack != null:
		return
	const S := 512
	var sand := FastNoiseLite.new()
	sand.seed = 41
	sand.noise_type = FastNoiseLite.TYPE_SIMPLEX
	sand.frequency = 0.25
	sand.fractal_octaves = 3
	var rn := FastNoiseLite.new()
	rn.seed = 57
	rn.noise_type = FastNoiseLite.TYPE_SIMPLEX
	rn.frequency = 0.012
	rn.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	rn.fractal_octaves = 5
	var mn := FastNoiseLite.new()
	mn.seed = 11
	mn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	mn.frequency = 0.008
	mn.fractal_octaves = 5
	# Pebbles: cellular cells; a stone sits in a cell when its random value is high.
	var pd := FastNoiseLite.new()
	pd.seed = 23
	pd.noise_type = FastNoiseLite.TYPE_CELLULAR
	pd.frequency = 0.04
	pd.fractal_type = FastNoiseLite.FRACTAL_NONE
	pd.cellular_jitter = 0.8
	pd.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	var pv := pd.duplicate() as FastNoiseLite
	pv.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	var g := sand.get_seamless_image(S, S)
	var r := rn.get_seamless_image(S, S)
	var mc := mn.get_seamless_image(S, S)
	var di := pd.get_seamless_image(S, S)
	var vi := pv.get_seamless_image(S, S)
	for im: Image in [g, r, mc, di, vi]:
		im.convert(Image.FORMAT_L8)
	var gd := g.get_data()
	var rd := r.get_data()
	var md := mc.get_data()
	var dd := di.get_data()
	var vd := vi.get_data()
	var pebbles := PackedByteArray()
	pebbles.resize(S * S)
	var h_fine := PackedByteArray()
	h_fine.resize(S * S)
	var h_grav := PackedByteArray()
	h_grav.resize(S * S)
	for i in S * S:
		var keep := clampf((vd[i] - 150.0) / 40.0, 0.0, 1.0)            # ~35 % of cells
		var size := 0.45 + 0.4 * float(vd[i] % 7) / 6.0
		var dome := clampf(1.0 - float(dd[i]) / 255.0 / size * 1.6, 0.0, 1.0)
		var peb := sqrt(dome) * keep
		pebbles[i] = int(peb * 255.0)
		h_fine[i] = int(md[i] * 0.6 + gd[i] * 0.4)
		h_grav[i] = int(clampf(peb * 200.0 + md[i] * 0.2, 0.0, 255.0))
	var nf := _normals(Image.create_from_data(S, S, false, Image.FORMAT_L8, h_fine), 5.0)
	var ng := _normals(Image.create_from_data(S, S, false, Image.FORMAT_L8, h_grav), 7.0)
	var nr := _normals(r, 7.0)
	var nb := _normals(mc, 4.0)
	var pack := PackedByteArray()
	pack.resize(S * S * 4)
	var n1 := PackedByteArray()
	n1.resize(S * S * 4)
	var n2 := PackedByteArray()
	n2.resize(S * S * 4)
	for i in S * S:
		var j := i * 4
		pack[j] = gd[i]
		pack[j + 1] = rd[i]
		pack[j + 2] = md[i]
		pack[j + 3] = pebbles[i]
		n1[j] = nf[j]
		n1[j + 1] = nf[j + 1]
		n1[j + 2] = ng[j]
		n1[j + 3] = ng[j + 1]
		n2[j] = nr[j]
		n2[j + 1] = nr[j + 1]
		n2[j + 2] = nb[j]
		n2[j + 3] = nb[j + 1]
	_ground_pack = _tex(S, pack)
	_ground_pack_normal = _tex(S, n1)
	_ground_pack_normal2 = _tex(S, n2)


static func _normals(height: Image, strength: float) -> PackedByteArray:
	var im := height.duplicate() as Image
	im.bump_map_to_normal_map(strength)
	im.convert(Image.FORMAT_RGBA8)
	return im.get_data()


static func _tex(size: int, data: PackedByteArray) -> ImageTexture:
	var im := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	im.generate_mipmaps()
	return ImageTexture.create_from_image(im)
