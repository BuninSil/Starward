class_name LaunchPad
extends RefCounted
## Launch complex built in code: concrete pad with markings and a flame trench,
## hold-down posts, a lattice umbilical tower with swing arms, a crane and a
## lightning mast. Origin at the pad centre on the ground (rocket base).

const PAD_SHADER := preload("res://shaders/pad.gdshader")


static func build(parent: Node3D, pad_radius: float, ground_y: float, noise: Texture2D) -> void:
	var root := Node3D.new()
	root.name = "LaunchPad"
	root.position = Vector3(0.0, ground_y, 0.0)
	parent.add_child(root)
	# Concrete pad (slightly raised, sloped edge).
	var pm := CylinderMesh.new()
	pm.top_radius = pad_radius
	pm.bottom_radius = pad_radius + 1.5
	pm.height = 1.0
	pm.radial_segments = 64
	var pad_mat := ShaderMaterial.new()
	pad_mat.shader = PAD_SHADER
	pad_mat.set_shader_parameter("noise_tex", noise)
	pad_mat.set_shader_parameter("radius", pad_radius)
	var pad := _mi(root, pm, pad_mat, Vector3(0, -0.5, 0))
	pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Flame trench: dark slot along x under the rocket.
	var dark := _mat(Color(0.05, 0.045, 0.04), 0.95)
	_box(root, Vector3(24.0, 0.04, 5.2), dark, Vector3(0, 0.005, 0))
	var wall := _mat(Color(0.38, 0.37, 0.35), 0.9)
	for z in [-2.75, 2.75]:
		_box(root, Vector3(24.0, 0.5, 0.5), wall, Vector3(0, 0.25, z))
	# Rocket support ring + four hold-down posts.
	var steel := _mat(Color(0.42, 0.42, 0.43), 0.5, 0.6)
	for k in 4:
		var a := TAU * k / 4.0 + PI / 4.0
		var c := Vector3(cos(a), 0, sin(a)) * 2.1
		_box(root, Vector3(0.5, 0.8, 0.5), steel, c + Vector3(0, 0.4, 0))
		_box(root, Vector3(0.7, 0.15, 0.7), steel, c + Vector3(0, 0.85, 0))
	# Lattice umbilical tower.
	var red := _mat(Color(0.62, 0.16, 0.1), 0.6, 0.4)
	var tx := 7.5
	var w := 3.0
	var h := 30.0
	var tower := Node3D.new()
	tower.position = Vector3(tx, 0, 0)
	root.add_child(tower)
	var corners := [Vector3(-w, 0, -w), Vector3(w, 0, -w), Vector3(w, 0, w), Vector3(-w, 0, w)]
	for c in corners:
		_beam(tower, c * 0.5, c * 0.5 + Vector3(0, h, 0), 0.22, red)
	var level := 3.0
	var y := level
	var side := 0
	while y <= h + 0.01:
		for k in 4:
			var a: Vector3 = corners[k] * 0.5
			var b: Vector3 = corners[(k + 1) % 4] * 0.5
			_beam(tower, a + Vector3(0, y, 0), b + Vector3(0, y, 0), 0.12, red)
			# X bracing alternates direction per level.
			var lo := y - level
			if (k + side) % 2 == 0:
				_beam(tower, a + Vector3(0, lo, 0), b + Vector3(0, y, 0), 0.07, red)
			else:
				_beam(tower, b + Vector3(0, lo, 0), a + Vector3(0, y, 0), 0.07, red)
		y += level
		side += 1
	# Floors (grating) every 6 m.
	var grate := _mat(Color(0.3, 0.3, 0.3), 0.7)
	for fy in range(6, int(h) + 1, 6):
		_box(tower, Vector3(w, 0.08, w), grate, Vector3(0, fy, 0))
	# Swing arms to the rocket (umbilicals), at several heights.
	for ay in [8.0, 15.0, 22.0, 27.0]:
		var arm := Node3D.new()
		arm.position = Vector3(-w * 0.5, ay, 0)
		tower.add_child(arm)
		var len := tx - w * 0.5 - 1.6
		_beam(arm, Vector3(0, 0, -0.4), Vector3(-len, 0, -0.4), 0.09, red)
		_beam(arm, Vector3(0, 0, 0.4), Vector3(-len, 0, 0.4), 0.09, red)
		_beam(arm, Vector3(0, 0.6, 0), Vector3(-len * 0.9, 0.05, 0), 0.06, red)
		_box(arm, Vector3(0.5, 0.5, 1.0), steel, Vector3(-len, 0, 0))
		# Umbilical hoses hanging down.
		_beam(arm, Vector3(-len * 0.5, 0, 0), Vector3(-len * 0.7, -1.2, 0), 0.05, _mat(Color(0.1, 0.1, 0.1), 0.8))
	# Hammerhead crane on top + lightning mast.
	_box(tower, Vector3(10.0, 0.6, 0.8), red, Vector3(-1.5, h + 0.6, 0))
	_box(tower, Vector3(1.2, 1.4, 1.4), _mat(Color(0.85, 0.85, 0.8), 0.6), Vector3(2.5, h + 1.4, 0))
	_beam(tower, Vector3(0, h, 0), Vector3(0, h + 9.0, 0), 0.08, steel)
	# Small service buildings at the pad edge.
	var bld := _mat(Color(0.8, 0.79, 0.74), 0.85)
	_box(root, Vector3(4.0, 2.5, 3.0), bld, Vector3(14.0, 1.25, -9.0))
	_box(root, Vector3(3.0, 2.0, 2.0), bld, Vector3(-12.0, 1.0, 11.0))
	# Propellant tanks (spheres) off the pad.
	var sp := SphereMesh.new()
	sp.radius = 2.4
	sp.height = 4.8
	sp.radial_segments = 24
	sp.rings = 12
	_mi(root, sp, _mat(Color(0.9, 0.9, 0.88), 0.4, 0.6), Vector3(-20.0, 2.6, -16.0))
	_mi(root, sp, _mat(Color(0.9, 0.9, 0.88), 0.4, 0.6), Vector3(-25.0, 2.6, -12.0))


static func _mat(c: Color, rough: float, spec := 0.4) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic_specular = spec
	return m


static func _mi(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _box(parent: Node3D, size: Vector3, mat: Material, pos: Vector3) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return _mi(parent, bm, mat, pos)


## Square beam between two points.
static func _beam(parent: Node3D, a: Vector3, b: Vector3, t: float, mat: Material) -> void:
	var bm := BoxMesh.new()
	bm.size = Vector3(t, a.distance_to(b), t)
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = mat
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	mi.transform = Transform3D(Basis(x, y, x.cross(y)), (a + b) * 0.5)
	parent.add_child(mi)
