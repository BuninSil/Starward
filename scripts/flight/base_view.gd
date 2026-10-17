class_name BaseView
extends Node3D
## Draws one surface base (Bases data) in its own frame: x / z along the grid,
## y up, origin on the ground at the anchor. Modules are built from primitives
## in the clean SFS/KSP style of the rockets, stand on a deck with legs (the
## ground is not flat) and are joined by conduits; the static parts are merged
## into a few meshes (MeshMerge). flight.gd places the node every frame in
## double precision, like the debris.

const C := Bases.CELL
const WHITE := Color(0.74, 0.75, 0.74)
const GREY := Color(0.36, 0.37, 0.39)
const DARK := Color(0.12, 0.12, 0.13)
const ORANGE := Color(0.95, 0.5, 0.12)
const GOLD := Color(0.83, 0.62, 0.22)

var base: Dictionary
var body: CelestialBody
var _drills: Array[Node3D] = []     ## spinning drill strings
var _lamps: Array[MeshInstance3D] = []
static var _mats := {}


## Builds the base node (static parts merged).
func setup(b: Dictionary, cb: CelestialBody) -> void:
	base = b
	body = cb
	rebuild()


func rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_drills.clear()
	_lamps.clear()
	var h0 := _height(0, 0)
	var cells := {}
	for m in base.modules:
		cells[Vector2i(int(m.x), int(m.z))] = true
	for m in base.modules:
		var gx := int(m.x)
		var gz := int(m.z)
		var n := build_module(str(m.type), false, _drills, _lamps)
		n.position = Vector3(gx * C, _height(gx, gz) - h0, gz * C)
		n.rotation.y = -PI * 0.5 * int(m.rot)
		add_child(n)
		# Conduits to the neighbours on +x and +z (each pair once).
		for d in [Vector2i(1, 0), Vector2i(0, 1)]:
			var o: Vector2i = Vector2i(gx, gz) + d
			if cells.has(o):
				var a := n.position + Vector3(0, 0.35, 0)
				var b := Vector3(o.x * C, _height(o.x, o.y) - h0 + 0.35, o.y * C)
				_conduit(self, a, b)
	# Merge the static parts; the spinning drill strings stay apart.
	var keep := []
	for d in _drills:
		keep.append([d, d.get_parent()])
		d.get_parent().remove_child(d)
	MeshMerge.merge(self, null, true, true)
	for k in keep:
		(k[1] as Node).add_child(k[0])


## Ground height (m above the reference sphere) at a grid cell.
func _height(gx: int, gz: int) -> float:
	return body.surface_height(Bases.cell_dir(base, gx, gz, body.radius))


func _process(delta: float) -> void:
	for d in _drills:
		if is_instance_valid(d):
			d.rotate_y(delta * 2.5)


# --- Module models ------------------------------------------------------------------------

static func _mat(c: Color, metal := 0.0, rough := 0.6, emit := Color.BLACK) -> StandardMaterial3D:
	var key := "%s %s %s %s" % [c, metal, rough, emit]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	if emit != Color.BLACK:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = 1.5
	_mats[key] = m
	return m


static func _box(p: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	p.add_child(mi)
	return mi


static func _cyl(p: Node3D, r: float, h: float, pos: Vector3, mat: Material, segs := 16, r_top := -1.0) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = r if r_top < 0.0 else r_top
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = segs
	cm.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	p.add_child(mi)
	return mi


## A strut from a to b (thin box along the segment).
static func _strut(p: Node3D, a: Vector3, b: Vector3, w: float, mat: Material) -> void:
	var d := b - a
	var mi := _box(p, Vector3(w, d.length(), w), (a + b) * 0.5, mat)
	var y := d.normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	mi.basis = Basis(x, y, x.cross(y)).orthonormalized()


static func _conduit(p: Node3D, a: Vector3, b: Vector3) -> void:
	_strut(p, a, b, 0.14, _mat(GREY, 0.6, 0.45))


## Deck every module stands on: plate, rim and four legs reaching into the
## ground (it is never flat).
static func _deck(p: Node3D, size := 3.4) -> void:
	_box(p, Vector3(size, 0.18, size), Vector3(0, 0.25, 0), _mat(GREY, 0.5, 0.5))
	# Orange edge frame (hazard stripe) around the plate.
	for sgn in [-1, 1]:
		_box(p, Vector3(size + 0.06, 0.08, 0.14), Vector3(0, 0.3, sgn * (size * 0.5 - 0.04)), _mat(ORANGE, 0.0, 0.5))
		_box(p, Vector3(0.14, 0.08, size + 0.06), Vector3(sgn * (size * 0.5 - 0.04), 0.3, 0), _mat(ORANGE, 0.0, 0.5))
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			_cyl(p, 0.09, 1.6, Vector3(sx * size * 0.42, -0.5, sz * size * 0.42), _mat(DARK, 0.6, 0.5), 8)
			_cyl(p, 0.22, 0.06, Vector3(sx * size * 0.42, -1.27, sz * size * 0.42), _mat(DARK, 0.6, 0.5), 10)


## One module, origin on its deck centre at ground level. ghost: one see-through
## material (build preview). drills / lamps collect the moving / glowing parts.
static func build_module(type: String, ghost := false, drills: Array = [], lamps: Array = []) -> Node3D:
	var n := Node3D.new()
	n.name = type
	if type != "pad":
		_deck(n)
	var y0 := 0.34
	match type:
		"pad":
			# Flat landing pad ~9 m across, a little above the ground, markings
			# and edge lights.
			_cyl(n, 4.6, 0.5, Vector3(0, -0.12, 0), _mat(Color(0.47, 0.47, 0.46), 0.1, 0.85), 24)
			_cyl(n, 4.62, 0.06, Vector3(0, 0.14, 0), _mat(ORANGE, 0.0, 0.6), 24)
			_cyl(n, 4.3, 0.07, Vector3(0, 0.15, 0), _mat(Color(0.5, 0.5, 0.49), 0.1, 0.85), 24)
			_cyl(n, 2.4, 0.08, Vector3(0, 0.16, 0), _mat(WHITE, 0.0, 0.7), 24)
			_cyl(n, 2.1, 0.09, Vector3(0, 0.17, 0), _mat(Color(0.5, 0.5, 0.49), 0.1, 0.85), 24)
			_box(n, Vector3(0.35, 0.1, 2.4), Vector3(-0.6, 0.18, 0), _mat(WHITE, 0.0, 0.7))
			_box(n, Vector3(0.35, 0.1, 2.4), Vector3(0.6, 0.18, 0), _mat(WHITE, 0.0, 0.7))
			_box(n, Vector3(1.2, 0.1, 0.35), Vector3(0, 0.18, 0), _mat(WHITE, 0.0, 0.7))
			for k in 8:
				var a := TAU * k / 8.0
				var lamp := _cyl(n, 0.12, 0.14, Vector3(cos(a) * 4.45, 0.2, sin(a) * 4.45),
					_mat(DARK, 0.0, 0.4, Color(0.3, 0.8, 1.0)), 8)
				lamps.append(lamp)
		"solar":
			_cyl(n, 0.12, 1.4, Vector3(0, y0 + 0.7, 0), _mat(GREY, 0.7, 0.4), 10)
			var panel := Node3D.new()
			panel.position = Vector3(0, y0 + 1.45, 0)
			panel.rotation.x = deg_to_rad(-28.0)
			n.add_child(panel)
			_box(panel, Vector3(3.6, 0.08, 2.4), Vector3.ZERO, _mat(Color(0.75, 0.76, 0.78), 0.8, 0.3))
			# Cells: dark blue tiles in a grid (separate boxes, merged later).
			for i in 6:
				for j in 4:
					_box(panel, Vector3(0.54, 0.02, 0.54), Vector3(-1.5 + i * 0.6, 0.05, -0.9 + j * 0.6),
						_mat(Color(0.05, 0.09, 0.22), 0.4, 0.18))
			_strut(n, Vector3(-0.9, y0, 0.9), Vector3(0, y0 + 1.2, 0.2), 0.08, _mat(GREY, 0.6, 0.5))
			_strut(n, Vector3(0.9, y0, 0.9), Vector3(0, y0 + 1.2, 0.2), 0.08, _mat(GREY, 0.6, 0.5))
		"battery":
			_box(n, Vector3(2.6, 1.5, 1.6), Vector3(0, y0 + 0.75, 0), _mat(WHITE, 0.1, 0.5))
			for i in 7:
				_box(n, Vector3(0.06, 1.2, 1.75), Vector3(-1.05 + i * 0.35, y0 + 0.75, 0), _mat(GREY, 0.7, 0.4))
			_box(n, Vector3(2.62, 0.16, 1.62), Vector3(0, y0 + 1.42, 0), _mat(ORANGE, 0.0, 0.5))
			var lamp := _box(n, Vector3(0.9, 0.12, 0.04), Vector3(0, y0 + 1.1, 0.83), _mat(DARK, 0.0, 0.4, Color(0.2, 1.0, 0.4)))
			lamps.append(lamp)
		"storage":
			_box(n, Vector3(3.2, 2.2, 3.0), Vector3(0, y0 + 1.1, 0), _mat(WHITE, 0.1, 0.55))
			for i in 4:
				_box(n, Vector3(3.24, 0.1, 3.04), Vector3(0, y0 + 0.3 + i * 0.55, 0), _mat(GREY, 0.6, 0.45))
			_box(n, Vector3(1.6, 1.7, 0.06), Vector3(0, y0 + 0.9, 1.52), _mat(ORANGE, 0.0, 0.5))
			_box(n, Vector3(0.05, 1.6, 0.08), Vector3(0, y0 + 0.9, 1.55), _mat(DARK, 0.3, 0.5))
		"drill":
			# Derrick: three legs to a crown, motor head, spinning drill string.
			var crown := Vector3(0, y0 + 3.4, 0)
			for k in 3:
				var a := TAU * k / 3.0
				_strut(n, Vector3(cos(a) * 1.4, y0, sin(a) * 1.4), crown, 0.12, _mat(ORANGE, 0.2, 0.5))
			_box(n, Vector3(0.9, 0.7, 0.9), crown + Vector3(0, 0.1, 0), _mat(WHITE, 0.1, 0.5))
			var string := Node3D.new()
			string.position = Vector3(0, y0, 0)
			n.add_child(string)
			_cyl(string, 0.08, 3.6, Vector3(0, 1.4, 0), _mat(GREY, 0.9, 0.3), 8)
			_box(string, Vector3(0.5, 0.06, 0.08), Vector3(0, 0.5, 0), _mat(DARK, 0.7, 0.4))
			_box(string, Vector3(0.5, 0.06, 0.08), Vector3(0, 1.6, 0), _mat(DARK, 0.7, 0.4))
			_cyl(n, 0.35, 0.3, Vector3(0, y0 + 0.15, 0), _mat(DARK, 0.6, 0.5), 12)
			_box(n, Vector3(1.0, 0.6, 0.7), Vector3(1.1, y0 + 0.3, -0.9), _mat(WHITE, 0.1, 0.5))
			drills.append(string)
		"processor":
			_cyl(n, 0.62, 2.4, Vector3(-0.8, y0 + 1.2, -0.4), _mat(WHITE, 0.1, 0.45), 18)
			_cyl(n, 0.62, 0.3, Vector3(-0.8, y0 + 2.45, -0.4), _mat(WHITE, 0.1, 0.45), 18, 0.35)
			_cyl(n, 0.45, 1.8, Vector3(0.9, y0 + 0.9, -0.6), _mat(GOLD, 0.8, 0.35), 16)
			_box(n, Vector3(1.6, 1.0, 1.0), Vector3(0.3, y0 + 0.5, 0.9), _mat(WHITE, 0.1, 0.5))
			_box(n, Vector3(1.62, 0.12, 1.02), Vector3(0.3, y0 + 1.0, 0.9), _mat(ORANGE, 0.0, 0.5))
			_strut(n, Vector3(-0.8, y0 + 2.0, -0.4), Vector3(0.9, y0 + 1.6, -0.6), 0.1, _mat(GREY, 0.7, 0.4))
			_strut(n, Vector3(0.9, y0 + 0.6, -0.6), Vector3(0.3, y0 + 0.6, 0.9), 0.1, _mat(GREY, 0.7, 0.4))
			var lamp2 := _box(n, Vector3(0.5, 0.1, 0.04), Vector3(0.3, y0 + 0.7, 1.41), _mat(DARK, 0.0, 0.4, Color(1.0, 0.6, 0.1)))
			lamps.append(lamp2)
		"pump":
			_box(n, Vector3(0.9, 1.6, 0.7), Vector3(0, y0 + 0.8, 0), _mat(WHITE, 0.1, 0.5))
			_box(n, Vector3(0.92, 0.25, 0.72), Vector3(0, y0 + 1.5, 0), _mat(ORANGE, 0.0, 0.5))
			_cyl(n, 0.45, 0.25, Vector3(0, y0 + 0.9, 0.48), _mat(DARK, 0.3, 0.6), 16).rotation.x = PI * 0.5
			_cyl(n, 0.07, 3.0, Vector3(0, y0 + 1.5, -0.2), _mat(GREY, 0.7, 0.4), 8).position.y = y0 + 1.5 + 1.5
			var beacon := _cyl(n, 0.1, 0.16, Vector3(0, y0 + 4.1, -0.2), _mat(DARK, 0.0, 0.4, Color(1.0, 0.25, 0.1)), 10)
			lamps.append(beacon)
	if ghost:
		var gm := StandardMaterial3D.new()
		gm.albedo_color = Color(0.4, 0.85, 1.0, 0.35)
		gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		gm.cull_mode = BaseMaterial3D.CULL_DISABLED
		for mi in n.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = gm
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return n
