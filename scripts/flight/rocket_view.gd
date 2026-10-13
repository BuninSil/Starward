extends Node3D
## Procedural rocket model in a clean "SFS-like" style, one child per stage,
## stacked along +Y with the origin at the bottom of the lowest stage.
## Parts are revolved profiles with bevels (smooth normals), painted by
## hull.gdshader (bands, seams, windows, hatch outline, metal / foil); windows
## and the hatch opening are painted, never separate overlapping boxes, and
## adjacent surfaces only touch at their edges (no z-fighting). The hatch door
## is a cut piece of the capsule hull on a hinge.

const HULL_SHADER := preload("res://shaders/hull.gdshader")
const EXHAUST_SHADER := preload("res://shaders/exhaust.gdshader")

const WHITE := Color(0.92, 0.92, 0.9)
const LIGHT_GREY := Color(0.72, 0.73, 0.74)
const DARK_GREY := Color(0.2, 0.2, 0.21)
const ORANGE := Color(0.95, 0.42, 0.08)
const BLACK := Color(0.04, 0.04, 0.045)

var vessel: Vessel
var _stage_nodes: Array[Node3D] = []
var _flames: Array[MeshInstance3D] = []
var _flame_mat: ShaderMaterial
var _chute: Node3D
var _bell_mats: Array[ShaderMaterial] = []
var _capsule_mat: ShaderMaterial
## Hinged hatch (rotates about its local Y axis = the hinge line).
var hatch_pivot: Node3D
var _hatch_basis := Basis()
var _hatch_open := 0.0
var _hatch_target := 0.0
## Ship collision for EVA (follows the rocket node, pushes the astronaut).
var collider: AnimatableBody3D
const HATCH_HEIGHT := 0.35   ## fraction of the capsule height
const HATCH_U := 0.25        ## +Z side (lathe angle = u * TAU, x = cos, z = sin)
const HATCH_DU := 0.11       ## hatch width as a fraction of the circumference
const HATCH_DV := 0.8        ## hatch height, metres

static var _noise: NoiseTexture2D = null


func build(v: Vessel) -> void:
	vessel = v
	for c in get_children():
		c.queue_free()
	_stage_nodes.clear()
	_flames.clear()
	_bell_mats.clear()
	_chute_lines.clear()
	_nav.clear()
	_floods.clear()
	_fill = null
	_chute_collapse = 0.0
	hatch_pivot = null
	_engine_light = null
	var y := 0.0
	# Bottom to top.
	for i in range(v.stages.size() - 1, -1, -1):
		var s: Dictionary = v.stages[i]
		var node := Node3D.new()
		node.name = s.name
		node.position.y = y
		add_child(node)
		_stage_nodes.push_front(node)
		var upper_d: float = float(v.stages[i - 1].diameter) if i > 0 else 0.0
		build_stage(node, s, i, v.stages.size(), upper_d, _shroud_height(v, i))
		# Rigid hull panels of the stage: one mesh per paint (draw calls, shadows).
		MeshMerge.merge(node, HULL_SHADER, false)
		y += s.length
	_build_flames()
	_build_chute()
	_build_lights()
	_build_plasma()
	_collect_hull_mats()
	_build_collider()
	_update_legs()


## Builds one stage's geometry into `node` (also used by the parts showcase).
func build_stage(node: Node3D, s: Dictionary, index: int, count: int, upper_d: float, shroud_h := 0.0) -> void:
	if index == 0:
		_build_capsule(node, s)
	elif s.get("legs", false):
		_build_descent_stage(node, s)
	elif s.name == "Взлётная ступень":
		_build_ascent_stage(node, s, upper_d)
	else:
		_build_tank_stage(node, s, index == count - 1, upper_d)
	if shroud_h > 0.0:
		_build_shroud(node, s, shroud_h)


## Height of the lander stages sitting right above stage i (they ride inside an
## adapter shroud on this stage, like the Saturn V SLA), 0 if none.
static func _shroud_height(v: Vessel, i: int) -> float:
	if i < 2 or not v.stages[i - 1].get("legs", false):
		return 0.0
	var h := 0.0
	for k in range(i - 1, 0, -1):
		h += float(v.stages[k].length)
	return h


## Adapter shroud on top of a stage enclosing the lander: panels with seams,
## tapering to the capsule; goes away with this stage at separation.
func _build_shroud(node: Node3D, s: Dictionary, h: float) -> void:
	var r := float(s.diameter) * 0.5
	var y0 := float(s.length)
	var r_top := 0.95
	var rb := r + 0.25
	var prof := PackedVector2Array([Vector2(r * 0.99, y0 - 0.05), Vector2(rb, y0 + 0.4)])
	for k in 6:
		var t := float(k + 1) / 6.0
		prof.append(Vector2(lerpf(rb, r_top, t * t), y0 + 0.4 + (h - 0.4) * t))
	prof.append(Vector2(r_top, y0 + h))
	prof.append(Vector2(r_top, y0 + h))
	var shell := _skin(WHITE, {"panel": 0.0, "stringers": 4.0, "rough": 0.38, "gloss": 0.25,
		"band1": Vector4(y0 + h - 0.35, y0 + h, 1, 0), "band": LIGHT_GREY})
	shell.set_shader_parameter("pattern", 0)
	var mi := _mesh(node, _lathe(prof, 64), shell)
	mi.name = "Shroud"
	var inner := MeshInstance3D.new()
	inner.mesh = mi.mesh
	inner.material_override = _dark_inside()
	node.add_child(inner)


# --- Materials ------------------------------------------------------------------

static func _noise_tex() -> NoiseTexture2D:
	if _noise == null:
		var n := FastNoiseLite.new()
		n.seed = 77
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX
		n.frequency = 0.05
		n.fractal_octaves = 4
		_noise = NoiseTexture2D.new()
		_noise.width = 256
		_noise.height = 256
		_noise.seamless = true
		_noise.noise = n
	return _noise


## Painted / metal skin. Colours are sRGB here (converted to linear).
func _skin(color: Color, opts := {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = HULL_SHADER
	m.set_shader_parameter("base_color", color.srgb_to_linear())
	m.set_shader_parameter("band_color", (opts.get("band", ORANGE) as Color).srgb_to_linear())
	m.set_shader_parameter("alt_color", (opts.get("alt", BLACK) as Color).srgb_to_linear())
	m.set_shader_parameter("band1", opts.get("band1", Vector4.ZERO))
	m.set_shader_parameter("band2", opts.get("band2", Vector4.ZERO))
	m.set_shader_parameter("pattern", opts.get("pattern", 0))
	m.set_shader_parameter("panel_h", opts.get("panel", 0.0))
	m.set_shader_parameter("stringers", opts.get("stringers", 0.0))
	m.set_shader_parameter("corrugation", opts.get("corrugation", 0.0))
	m.set_shader_parameter("rough", opts.get("rough", 0.42))
	m.set_shader_parameter("metal", opts.get("metal", 0.0))
	m.set_shader_parameter("foil", opts.get("foil", 0.0))
	m.set_shader_parameter("gloss", opts.get("gloss", 0.22))
	m.set_shader_parameter("soot", opts.get("soot", 0.0))
	m.set_shader_parameter("noise_tex", _noise_tex())
	return m


func _metal(color: Color, rough := 0.4) -> ShaderMaterial:
	return _skin(color, {"metal": 0.85, "rough": rough})


func _dark_inside() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.03, 0.03, 0.03)
	m.roughness = 0.8
	m.cull_mode = BaseMaterial3D.CULL_FRONT
	return m


# --- Geometry helpers -----------------------------------------------------------

## Revolved profile (x = radius, y = height, bottom to top). UV = (angle 0..1,
## height in metres). Repeated points make a sharp crease, otherwise normals
## are smooth. a0..a1 = angle range (fractions of a turn) for partial pieces;
## grow pushes the surface out along its normal (pieces laid over a hull).
static func _lathe(profile: PackedVector2Array, segs: int, flat := false, cap_top := false,
		cap_bottom := false, a0 := 0.0, a1 := 1.0, grow := 0.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := profile.size()
	var pn: Array[Vector2] = []
	for i in n:
		var a := profile[maxi(i - 1, 0)]
		var b := profile[mini(i + 1, n - 1)]
		if i + 1 < n and profile[i + 1].is_equal_approx(profile[i]):
			b = profile[i]
		elif i > 0 and profile[i - 1].is_equal_approx(profile[i]):
			a = profile[i]
		var t := (b - a)
		pn.append(Vector2(t.y, -t.x).normalized() if t.length() > 1e-6 else Vector2(1, 0))
	for i in n - 1:
		if profile[i].is_equal_approx(profile[i + 1]):
			continue
		for j in segs:
			var f0 := lerpf(a0, a1, float(j) / segs)
			var f1 := lerpf(a0, a1, float(j + 1) / segs)
			var quad := [[i, f0], [i + 1, f0], [i + 1, f1], [i, f1]]
			for k in [0, 2, 1, 0, 3, 2]:   # Godot: clockwise = front face
				var q: Array = quad[k]
				var p := profile[q[0]] + pn[q[0]] * grow
				var ang: float = float(q[1]) * TAU
				var nn: Vector2 = pn[q[0]]
				if not flat:
					st.set_normal(Vector3(nn.x * cos(ang), nn.y, nn.x * sin(ang)))
				st.set_uv(Vector2(q[1], profile[q[0]].y))
				st.add_vertex(Vector3(p.x * cos(ang), p.y, p.x * sin(ang)))
	for cap in [[cap_top, n - 1, 1.0], [cap_bottom, 0, -1.0]]:
		if not cap[0]:
			continue
		var p := profile[cap[1]]
		for j in segs:
			var ang0 := TAU * j / segs
			var ang1 := TAU * (j + 1) / segs
			var tri := [Vector3(0, p.y, 0), Vector3(p.x * cos(ang0), p.y, p.x * sin(ang0)), Vector3(p.x * cos(ang1), p.y, p.x * sin(ang1))]
			var order := [0, 1, 2] if cap[2] > 0.0 else [0, 2, 1]
			for k in order:
				if not flat:
					st.set_normal(Vector3(0, cap[2], 0))
				st.set_uv(Vector2(0.5, p.y))
				st.add_vertex(tri[k])
	if flat:
		st.generate_normals()
	st.generate_tangents()
	return st.commit()


## Cylinder r between y0 and y1 with rounded (bevelled) top and bottom edges.
static func _bevel_cyl(r: float, y0: float, y1: float, bev: float) -> PackedVector2Array:
	var p := PackedVector2Array()
	p.append(Vector2(0.0, y0))
	for k in 4:   # bottom edge quarter round
		var a := PI * 0.5 * float(k) / 3.0
		p.append(Vector2(r - bev + sin(a) * bev, y0 + bev - cos(a) * bev))
	for k in 4:   # top edge
		var a := PI * 0.5 * float(k) / 3.0
		p.append(Vector2(r - bev + cos(a) * bev, y1 - bev + sin(a) * bev))
	p.append(Vector2(0.0, y1))
	return p


func _mesh(parent: Node3D, mesh: Mesh, mat: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


## Local transform for a Y-axis cylinder spanning a..b.
static func _segment(a: Vector3, b: Vector3) -> Transform3D:
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x, y, z), (a + b) * 0.5)


func _strut(parent: Node3D, a: Vector3, b: Vector3, r: float, mat: Material) -> void:
	var len := a.distance_to(b)
	var mi := _mesh(parent, _lathe(_bevel_cyl(r, -len * 0.5, len * 0.5, r * 0.4), 16), mat)
	mi.transform = _segment(a, b)


## Ring (rounded lip) around a hull: hull radius r, centred at y, height t.
func _rim(parent: Node3D, r: float, y: float, t: float, mat: Material) -> void:
	var p := PackedVector2Array()
	for k in 7:
		var a := PI * float(k) / 6.0
		p.append(Vector2(r + sin(a) * t * 0.35, y - cos(a) * t * 0.5))
	_mesh(parent, _lathe(p, 64), mat)


# --- Engines --------------------------------------------------------------------

## Engine: chamber with turbopump, throat and a smooth bell with a lip; exit
## plane at y = 0, total height h, exit radius re.
func _engine(parent: Node3D, pos: Vector3, re: float, h: float) -> Node3D:
	var e := Node3D.new()
	e.position = pos
	parent.add_child(e)
	var rt := re * 0.3
	var rc := re * 0.42
	var bell_h := h * 0.68
	var prof := PackedVector2Array()
	prof.append(Vector2(re * 1.05, 0.0))
	prof.append(Vector2(re * 1.05, 0.0))
	prof.append(Vector2(re * 1.05, 0.05))
	prof.append(Vector2(re * 1.05, 0.05))
	prof.append(Vector2(re, 0.07))
	for k in range(1, 10):
		var s := float(k) / 9.0
		prof.append(Vector2(rt + (re - rt) * pow(1.0 - s, 2.0), 0.07 + s * (bell_h - 0.07)))
	prof.append(Vector2(rc, bell_h + h * 0.07))
	prof.append(Vector2(rc, h * 0.9))
	prof.append(Vector2(rc * 0.7, h))
	var mat := _skin(Color(0.58, 0.57, 0.56), {"metal": 0.85, "rough": 0.38, "panel": 0.12})
	mat.set_shader_parameter("heat_v0", bell_h)
	_bell_mats.append(mat)
	var bell := _mesh(e, _lathe(prof, 48, false, true), mat)
	var inner := MeshInstance3D.new()
	inner.mesh = bell.mesh
	inner.material_override = _dark_inside()
	e.add_child(inner)
	# Turbopump and its exhaust pipe on the side of the chamber.
	var pump := _metal(Color(0.38, 0.38, 0.39), 0.45)
	_strut(e, Vector3(rc + re * 0.12, bell_h + h * 0.05, 0), Vector3(rc + re * 0.12, h * 0.95, 0), re * 0.1, pump)
	_strut(e, Vector3(rc + re * 0.12, bell_h + h * 0.08, 0), Vector3(re * 0.75, bell_h * 0.35, 0.0), re * 0.04, pump)
	return e


## Engines of a stage: cluster by stage size. Returns exhaust anchors.
func _engine_cluster(node: Node3D, d: float, y: float, h: float, count: int) -> Array[Vector4]:
	var out: Array[Vector4] = []
	var re := d * (0.3 if count == 1 else (0.16 if count == 5 else 0.19))
	var ring := d * 0.3
	for k in count:
		var p := Vector3(0, y, 0)
		if count > 1 and not (count == 5 and k == 4):
			var a := TAU * k / (4 if count == 5 else count) + PI / 4.0
			p = Vector3(cos(a) * ring, y, sin(a) * ring)
		var e := _engine(node, p, re, h)
		e.rotation.y = TAU * k / maxf(count, 1)
		out.append(Vector4(p.x, p.y, p.z, re))
	return out


# --- Stages ---------------------------------------------------------------------

func _build_tank_stage(node: Node3D, s: Dictionary, bottom: bool, upper_d: float) -> void:
	var d: float = s.diameter
	var r := d * 0.5
	var length: float = s.length
	var first := bottom
	var engine_h := minf(2.0, d * 0.55) if first else minf(1.4, d * 0.5)
	var count := (5 if d >= 3.0 else 4) if bottom else 1
	var tank_y0 := engine_h + 0.35
	var sep_h := 0.4 if upper_d > 0.0 else 0.0
	var tank_y1 := length - sep_h
	node.set_meta("exhausts", _engine_cluster(node, d, 0.02, engine_h, count))
	var metal := _metal(LIGHT_GREY, 0.45)
	# Engine mount: dark truncated cone from the tank down to the engines,
	# open below (inner face dark) so the engine tops sit inside it.
	var mount := PackedVector2Array([Vector2(r * 0.62, engine_h * 0.82), Vector2(r * 0.62, engine_h * 0.82),
		Vector2(r * 0.96, tank_y0), Vector2(r * 0.96, tank_y0)])
	var mm := _mesh(node, _lathe(mount, 48), _skin(DARK_GREY, {"rough": 0.55, "stringers": 16.0, "soot": 0.4}))
	var mi := MeshInstance3D.new()
	mi.mesh = mm.mesh
	mi.material_override = _dark_inside()
	node.add_child(mi)
	if not first:
		# Aft skirt around the engine (open below), so stacked stages read as one body.
		var skirt := PackedVector2Array([Vector2(r * 0.99, 0.0), Vector2(r * 0.99, 0.0), Vector2(r * 0.99, tank_y0), Vector2(r * 0.99, tank_y0)])
		var sk := _mesh(node, _lathe(skirt, 64), _skin(Color(0.6, 0.61, 0.62), {"rough": 0.5, "corrugation": 72.0, "metal": 0.3}))
		var ski := MeshInstance3D.new()
		ski.mesh = sk.mesh
		ski.material_override = _dark_inside()
		node.add_child(ski)
	# Tank body: bevelled cylinder, white paint with bands.
	var opts := {"panel": 1.5, "gloss": 0.25, "rough": 0.38}
	if first:
		opts.merge({"band1": Vector4(tank_y0 + 0.4, tank_y0 + 2.6, 1, 0), "pattern": 1, "band": BLACK,
			"band2": Vector4(tank_y1 - 1.0, tank_y1 - 0.6, 1, 0)})
	elif s.name == "Разгонный блок":
		opts.merge({"band1": Vector4(tank_y0 + 0.3, tank_y0 + 0.7, 1, 0), "band": ORANGE,
			"band2": Vector4(tank_y1 - 0.7, tank_y1 - 0.3, 1, 0)})
	else:
		opts.merge({"band1": Vector4(tank_y1 - 0.9, tank_y1 - 0.5, 1, 0), "band": ORANGE})
	_mesh(node, _lathe(_bevel_cyl(r, tank_y0, tank_y1, 0.08), 64), _skin(WHITE, opts))
	# Rims at both tank ends (grey metal lips).
	_rim(node, r, tank_y0 + 0.12, 0.12, metal)
	_rim(node, r, tank_y1 - 0.12, 0.12, metal)
	# Separator / adapter to the next stage.
	if sep_h > 0.0:
		var ur := maxf(upper_d * 0.5, r * 0.55)
		var sp := PackedVector2Array([Vector2(r * 0.97, tank_y1), Vector2(r * 0.97, tank_y1), Vector2(ur, length), Vector2(ur, length), Vector2(0.0, length)])
		_mesh(node, _lathe(sp, 64), _skin(DARK_GREY, {"rough": 0.6, "corrugation": 72.0}))
		# Yellow / black hazard ring (decoupler).
		var hz := _skin(Color(0.95, 0.75, 0.1), {"rough": 0.5, "stringers": 32.0})
		var hr := lerpf(r * 0.97, ur, 0.5)
		_rim(node, hr, tank_y1 + sep_h * 0.5, 0.12, hz)
	# Fins on the first stage.
	if first:
		var fin_mat := _skin(WHITE, {"band1": Vector4(0.8, 1.6, 1, 0), "band": BLACK, "rough": 0.4})
		for k in 4:
			var a := TAU * k / 4.0 + PI / 4.0
			var fm := _mesh(node, _fin(r * 0.96, tank_y0 + 1.6, tank_y0 - 0.2, 1.5, 0.16), fin_mat)
			fm.rotation.y = -a
	# Conduit along the tank.
	_mesh(node, _lathe(_bevel_cyl(0.08, tank_y0 + 0.3, tank_y1 - 0.3, 0.03), 16), _skin(LIGHT_GREY, {"rough": 0.5}),
		Vector3(0, 0, -(r + 0.05)))


## Swept fin in the XY plane at x >= r (root along the hull), thinner tip.
static func _fin(r: float, root_top: float, root_bot: float, span: float, thick: float) -> ArrayMesh:
	var pts := [Vector2(r, root_bot), Vector2(r + span, root_bot - 0.5), Vector2(r + span, root_bot + 0.4), Vector2(r, root_top)]
	var zs := [1.0, 0.4, 0.4, 1.0]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var z := thick * 0.5
	var quads := []
	quads.append([Vector3(pts[0].x, pts[0].y, z), Vector3(pts[1].x, pts[1].y, z * 0.4), Vector3(pts[2].x, pts[2].y, z * 0.4), Vector3(pts[3].x, pts[3].y, z)])
	quads.append([Vector3(pts[3].x, pts[3].y, -z), Vector3(pts[2].x, pts[2].y, -z * 0.4), Vector3(pts[1].x, pts[1].y, -z * 0.4), Vector3(pts[0].x, pts[0].y, -z)])
	for e in 4:
		var a: Vector2 = pts[e]
		var b: Vector2 = pts[(e + 1) % 4]
		var za: float = z * zs[e]
		var zb: float = z * zs[(e + 1) % 4]
		quads.append([Vector3(a.x, a.y, -za), Vector3(b.x, b.y, -zb), Vector3(b.x, b.y, zb), Vector3(a.x, a.y, za)])
	for q in quads:
		for k in [0, 2, 1, 0, 3, 2]:
			st.set_uv(Vector2(0.0, (q[k] as Vector3).y - root_bot + 1.0))
			st.add_vertex(q[k])
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


## Lunar module descent stage: gold-foil octagon with black panels, recessed
## engine, telescopic landing legs.
func _build_descent_stage(node: Node3D, s: Dictionary) -> void:
	var d: float = s.diameter
	var r := d * 0.5
	var length: float = s.length
	var base := 0.6
	var body_y0 := base + 0.45
	var foil := _skin(Color(0.95, 0.72, 0.3), {"foil": 1.0, "metal": 1.0})
	var black := _skin(Color(0.08, 0.08, 0.09), {"foil": 0.5, "rough": 0.6})
	var prof := PackedVector2Array([Vector2(0.0, body_y0), Vector2(r * 0.8, body_y0), Vector2(r * 0.8, body_y0), Vector2(r, body_y0 + 0.25), Vector2(r, body_y0 + 0.25),
		Vector2(r, length - 0.05), Vector2(r, length - 0.05), Vector2(r * 0.96, length), Vector2(r * 0.96, length), Vector2(0.0, length)])
	_mesh(node, _lathe(prof, 64), foil)
	# Black blanket panels on four sides (slightly proud of the foil).
	var bp := PackedVector2Array([Vector2(r, body_y0 + 0.4), Vector2(r, body_y0 + 0.4), Vector2(r, length - 0.25), Vector2(r, length - 0.25)])
	for k in 4:
		var bm := _mesh(node, _lathe(bp, 8, false, false, false, 0.0, 0.11, 0.015), black)
		bm.rotation.y = TAU * k / 4.0 + 0.2
	node.set_meta("exhausts", [_engine_vec(node, Vector3(0, base + 0.02, 0), 0.45, 0.8)] as Array[Vector4])
	_build_legs(node, s, base)


func _engine_vec(node: Node3D, p: Vector3, re: float, h: float) -> Vector4:
	_engine(node, p, re, h)
	return Vector4(p.x, p.y, p.z, re)


## Lunar module ascent stage: faceted anodised cabin with seams, front
## window, docking tunnel, dish antenna, RCS quads.
func _build_ascent_stage(node: Node3D, s: Dictionary, upper_d: float) -> void:
	var d: float = s.diameter
	var r := d * 0.5
	var length: float = s.length
	var top_r := maxf(upper_d * 0.5, r * 0.5)
	var cabin := _skin(Color(0.82, 0.82, 0.83), {"panel": 0.55, "stringers": 7.0, "rough": 0.42, "metal": 0.15,
		"band1": Vector4(0.0, 0.32, 1, 0), "band": Color(0.22, 0.22, 0.23)})
	cabin.set_shader_parameter("win_count", 8.0)
	cabin.set_shader_parameter("win_n", 1.0)
	cabin.set_shader_parameter("win_u0", 0.25)
	cabin.set_shader_parameter("win_v", length * 0.62)
	cabin.set_shader_parameter("win_size", Vector2(0.07, 0.45))
	var prof := PackedVector2Array([Vector2(0.0, 0.0), Vector2(r * 0.72, 0.0), Vector2(r * 0.72, 0.0), Vector2(r, 0.32), Vector2(r, 0.32),
		Vector2(r * 0.96, length * 0.8), Vector2(r * 0.96, length * 0.8), Vector2(top_r, length), Vector2(top_r, length), Vector2(0.0, length)])
	_mesh(node, _lathe(prof, 64), cabin)
	# Dish antenna on a boom (matte metal, not overexposed).
	var boom_a := Vector3(-r * 0.62, length * 0.8, -r * 0.5)
	var boom_b := boom_a + Vector3(-0.45, 0.5, -0.2)
	_strut(node, boom_a, boom_b, 0.03, _metal(LIGHT_GREY, 0.5))
	var dish_p := PackedVector2Array([Vector2(0.0, -0.02), Vector2(0.05, 0.0), Vector2(0.18, 0.05), Vector2(0.3, 0.13), Vector2(0.3, 0.13), Vector2(0.28, 0.14)])
	var dm := _mesh(node, _lathe(dish_p, 20), _skin(Color(0.78, 0.78, 0.77), {"metal": 0.4, "rough": 0.6, "gloss": 0.1}), boom_b)
	dm.rotation = Vector3(-0.5, 0.0, 0.4)
	# Back of the dish (open surface: draw both sides).
	var db := _mesh(node, dm.mesh, _dark_inside(), boom_b)
	db.rotation = dm.rotation
	(db.material_override as StandardMaterial3D).albedo_color = Color(0.7, 0.7, 0.69)
	_rcs_quads(node, r * 0.98, length * 0.58, 4)
	node.set_meta("exhausts", [_engine_vec(node, Vector3(0, -0.5, 0), 0.26, 0.5)] as Array[Vector4])


## Small RCS thruster quads around a hull.
func _rcs_quads(node: Node3D, r: float, y: float, count: int) -> void:
	var body := _skin(LIGHT_GREY, {"rough": 0.45, "metal": 0.4})
	var noz := _metal(Color(0.3, 0.3, 0.31), 0.45)
	for k in count:
		var a := TAU * k / count + PI / 4.0
		var dir := Vector3(cos(a), 0, sin(a))
		var c := dir * (r + 0.08) + Vector3(0, y, 0)
		_mesh(node, _lathe(_bevel_cyl(0.09, -0.09, 0.09, 0.03), 16), body, c)
		for t in [Vector3.UP, Vector3.DOWN, dir.cross(Vector3.UP), -dir.cross(Vector3.UP)]:
			var np := PackedVector2Array([Vector2(0.025, 0.0), Vector2(0.025, 0.0), Vector2(0.045, 0.09), Vector2(0.045, 0.09)])
			var mi := _mesh(node, _lathe(np, 12), noz)
			var seg := _segment(c + t * 0.07, c + t * 0.16)
			mi.transform = Transform3D(seg.basis, c + t * 0.07)


## Telescopic landing legs: upper strut (foil-wrapped), lower piston, two side
## struts, footpad. Hidden while a stage is attached below (see _update_legs).
func _build_legs(node: Node3D, s: Dictionary, base: float) -> void:
	var legs := Node3D.new()
	legs.name = "Legs"
	node.add_child(legs)
	var r: float = float(s.diameter) * 0.5
	var steel := _metal(Color(0.78, 0.79, 0.8), 0.38)
	var gold := _skin(Color(0.95, 0.72, 0.3), {"foil": 0.8, "metal": 1.0})
	for k in 4:
		var ang := TAU * k / 4.0 + PI / 4.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var side := dir.cross(Vector3.UP)
		var top := dir * (r * 0.95) + Vector3(0, base + float(s.length) * 0.62, 0)
		var foot := dir * (r + 1.1) + Vector3(0, 0.12, 0)
		var mid := top.lerp(foot, 0.55)
		_strut(legs, top, mid, 0.1, gold)
		_strut(legs, mid, foot, 0.06, steel)
		for sg in [-1.0, 1.0]:
			_strut(legs, dir * (r * 0.88) + side * sg * r * 0.45 + Vector3(0, base + 0.5, 0), mid, 0.035, steel)
		var pad := PackedVector2Array([Vector2(0.0, -0.08), Vector2(0.3, -0.06), Vector2(0.38, 0.02), Vector2(0.36, 0.05), Vector2(0.1, 0.06), Vector2(0.0, 0.06)])
		_mesh(legs, _lathe(pad, 32), steel, foot - Vector3(0, 0.04, 0))


## Legs are deployed only on the bottom stage.
func _update_legs() -> void:
	for i in _stage_nodes.size():
		var legs := _stage_nodes[i].get_node_or_null("Legs") as Node3D
		if legs:
			legs.visible = i == _stage_nodes.size() - 1


## Crew capsule: brown heat shield, white cone with windows and a black top
## band, docking port, RCS quads and a hinged hatch cut from the hull.
func _build_capsule(node: Node3D, s: Dictionary) -> void:
	var d: float = s.diameter
	var r := d * 0.5
	var L: float = s.length
	var top_r := d * 0.17
	var y_sh := 0.08
	# Heat shield: shallow dome + rounded shoulder, ending exactly where the cone starts.
	var shield := PackedVector2Array()
	for k in 7:
		var t := float(k) / 6.0
		shield.append(Vector2(r * 0.96 * t, -0.1 * (1.0 - t * t)))
	shield.append(Vector2(r, y_sh * 0.5))
	shield.append(Vector2(r, y_sh))
	_mesh(node, _lathe(shield, 64), _skin(Color(0.33, 0.24, 0.16), {"rough": 0.8, "gloss": 0.05}))
	# Cone body.
	_capsule_mat = _skin(WHITE, {"panel": 0.5, "stringers": 12.0, "gloss": 0.25, "rough": 0.38,
		"band1": Vector4(L * 0.78, L * 0.86, 1, 0), "band": BLACK})
	_capsule_mat.set_shader_parameter("win_count", 5.0)
	_capsule_mat.set_shader_parameter("win_n", 5.0)
	_capsule_mat.set_shader_parameter("win_u0", HATCH_U + 0.1)
	_capsule_mat.set_shader_parameter("win_v", L * 0.6)
	_capsule_mat.set_shader_parameter("win_size", Vector2(0.05, 0.28))
	var hy := L * HATCH_HEIGHT
	_capsule_mat.set_shader_parameter("hatch", Vector4(HATCH_U, hy, HATCH_DU, HATCH_DV))
	_mesh(node, _lathe(_capsule_profile(r, top_r, L, y_sh), 64), _capsule_mat)
	# Docking port on top.
	var port := PackedVector2Array([Vector2(top_r, L * 0.86), Vector2(top_r, L * 0.86), Vector2(0.24, L * 0.88), Vector2(0.24, L * 0.88),
		Vector2(0.24, L * 0.96), Vector2(0.24, L * 0.96), Vector2(0.16, L * 0.98), Vector2(0.05, L * 1.03), Vector2(0.0, L * 1.05)])
	_mesh(node, _lathe(port, 32), _metal(LIGHT_GREY, 0.45))
	_rcs_quads(node, _capsule_radius(r, top_r, L, y_sh, L * 0.68), L * 0.68, 4)
	# Hatch door: the same hull piece, grown 1.5 cm outwards, on a hinge line
	# along its left edge; swings out around it.
	var u0 := HATCH_U - HATCH_DU * 0.5
	var u1 := HATCH_U + HATCH_DU * 0.5
	var door_prof := PackedVector2Array()
	for k in 6:
		var y := lerpf(hy - HATCH_DV * 0.5, hy + HATCH_DV * 0.5, float(k) / 5.0)
		door_prof.append(Vector2(_capsule_radius(r, top_r, L, y_sh, y), y))
	var door_mat := _skin(WHITE, {"rough": 0.38, "gloss": 0.25})
	door_mat.set_shader_parameter("win_count", 1.0 / HATCH_DU)
	door_mat.set_shader_parameter("win_u0", HATCH_U)
	door_mat.set_shader_parameter("win_v", hy + 0.15)
	door_mat.set_shader_parameter("win_size", Vector2(HATCH_DU * 0.3, 0.2))
	var door_mesh := _lathe(door_prof, 6, false, false, false, u0, u1, 0.015)
	var a_h := u0 * TAU
	var p_lo := Vector3(cos(a_h) * door_prof[0].x, door_prof[0].y, sin(a_h) * door_prof[0].x)
	var p_hi := Vector3(cos(a_h) * door_prof[5].x, door_prof[5].y, sin(a_h) * door_prof[5].x)
	var hinge := _segment(p_lo, p_hi)
	hatch_pivot = Node3D.new()
	hatch_pivot.name = "Hatch"
	hatch_pivot.transform = hinge
	_hatch_basis = hinge.basis
	node.add_child(hatch_pivot)
	var door := _mesh(hatch_pivot, door_mesh, door_mat)
	door.transform = hinge.affine_inverse()
	# Inner face of the door (seen when it is swung open).
	var door_in := _mesh(hatch_pivot, door_mesh, _dark_inside())
	door_in.transform = door.transform
	(door_in.material_override as StandardMaterial3D).albedo_color = Color(0.55, 0.56, 0.58)
	_hatch_open = 0.0
	_hatch_target = 0.0


static func _capsule_profile(r: float, top_r: float, L: float, y_sh: float) -> PackedVector2Array:
	var p := PackedVector2Array([Vector2(r, y_sh), Vector2(r, y_sh)])
	for k in 9:
		var y := lerpf(y_sh, L * 0.86, float(k + 1) / 9.0)
		p.append(Vector2(_capsule_radius(r, top_r, L, y_sh, y), y))
	p.append(Vector2(top_r, L * 0.86))
	return p


## Capsule radius at height y: cone with a gently rounded shoulder.
static func _capsule_radius(r: float, top_r: float, L: float, y_sh: float, y: float) -> float:
	var t := clampf((y - y_sh) / (L * 0.86 - y_sh), 0.0, 1.0)
	return lerpf(r, top_r, t) - 0.04 * sin(t * PI)


# --- Hatch ---------------------------------------------------------------------

## Animated hatch: open (true) swings it out ~110° on its hinge.
func set_hatch_open(open: bool) -> void:
	_hatch_target = 1.0 if open else 0.0


func hatch_is_open() -> bool:
	return _hatch_open > 0.95


## Hatch position in the rocket node's local frame (slightly outside the hull).
func hatch_local() -> Vector3:
	if _stage_nodes.is_empty():
		return Vector3.ZERO
	var cap: Node3D = _stage_nodes[0]
	var s: Dictionary = vessel.stages[0]
	var d: float = s.diameter
	var L: float = s.length
	var hr := _capsule_radius(d * 0.5, d * 0.17, L, 0.08, L * HATCH_HEIGHT)
	return cap.position + Vector3(0, L * HATCH_HEIGHT, hr + 0.35)


## The hatch point on the hull itself (where the tether reel sits).
func hatch_hull_local() -> Vector3:
	return hatch_local() - Vector3(0, 0, 0.33)


# --- Exhaust, chute, collider ---------------------------------------------------

func _build_flames() -> void:
	_flames.clear()
	if _flame_mat == null:
		_flame_mat = ShaderMaterial.new()
		_flame_mat.shader = EXHAUST_SHADER
	var cone := CylinderMesh.new()
	cone.top_radius = 0.35      # narrow end on the nozzle, UV.y = 0 there
	cone.bottom_radius = 1.0
	cone.height = 1.0
	cone.radial_segments = 20
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	if _stage_nodes.is_empty():
		return
	var bottom: Node3D = _stage_nodes[_stage_nodes.size() - 1]
	var ex: Array = bottom.get_meta("exhausts", [])
	for e in ex:
		var v4: Vector4 = e
		var f := MeshInstance3D.new()
		f.mesh = cone
		f.material_override = _flame_mat
		f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		f.set_meta("anchor", Vector3(v4.x, v4.y, v4.z) + bottom.position)
		f.set_meta("re", v4.w)
		f.visible = false
		add_child(f)
		_flames.append(f)
	# The flame's own light: just below the nozzles, lighting the engines, the
	# skirt and the underside; falls off quickly up the hull.
	if _engine_light == null or not is_instance_valid(_engine_light):
		_engine_light = OmniLight3D.new()
		_engine_light.light_color = Color(1.0, 0.6, 0.28)
		_engine_light.shadow_enabled = false
		add_child(_engine_light)
	var low_y := 0.0
	var rmax := 0.5
	for e in ex:
		var v4: Vector4 = e
		low_y = minf(low_y, v4.y + bottom.position.y)
		rmax = maxf(rmax, Vector2(v4.x, v4.z).length() + v4.w)
	_engine_light.position = Vector3(0, low_y - 1.2 - rmax * 0.5, 0)
	_engine_light.omni_range = 6.0 + rmax * 6.0
	_engine_light.omni_attenuation = 2.2
	_engine_light.visible = false


func _build_collider() -> void:
	if collider:
		collider.queue_free()
	collider = AnimatableBody3D.new()
	collider.sync_to_physics = false
	add_child(collider)
	for i in _stage_nodes.size():
		var s: Dictionary = vessel.stages[i]
		var node: Node3D = _stage_nodes[i]
		var cs := CollisionShape3D.new()
		var sh := CylinderShape3D.new()
		sh.radius = float(s.diameter) * (0.38 if i == 0 else 0.5)
		sh.height = float(s.length)
		cs.shape = sh
		cs.position = node.position + Vector3(0, float(s.length) * 0.5, 0)
		collider.add_child(cs)


## Stage bodies for the tether to slide around: [global Transform3D of the
## centre (Y = axis), bottom radius, half height, top radius] (the capsule is
## a cone).
func rope_obstacles() -> Array:
	var out: Array = []
	for i in mini(_stage_nodes.size(), vessel.stages.size()):
		var s: Dictionary = vessel.stages[i]
		var node: Node3D = _stage_nodes[i]
		if not is_instance_valid(node) or not node.visible:
			continue
		var d: float = s.diameter
		var L: float = s.length
		var xf := node.global_transform * Transform3D(Basis(), Vector3(0, L * 0.5, 0))
		out.append([xf, d * 0.5, L * 0.5, d * 0.17 if i == 0 else d * 0.5])
	return out


const CHUTE_GORES := 12
const CHUTE_R := 7.5     ## skirt radius, m
const CHUTE_H := 4.6     ## canopy depth (apex above the skirt), m
const CHUTE_L := 12.0    ## suspension line length to the skirt, m

var _canopy: MeshInstance3D
var _chute_mat: ShaderMaterial
var _chute_lines: Array[MeshInstance3D] = []
var _chute_collapse := 0.0
var _chute_wind := 0.0
var _chute_flow := Quaternion.IDENTITY   ## yaw the canopy falls towards


func _build_chute() -> void:
	_chute = Node3D.new()
	# Canopy: a shallow dome of gores, alternately orange and white.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 12
	var per := 6   # segments across one gore
	var orange := Color(1.0, 0.45, 0.07)   # linear
	var white := Color(0.82, 0.82, 0.78)
	for g in CHUTE_GORES:
		var col := orange if g % 2 == 0 else white
		for k in per:
			var a0 := TAU * (g * per + k) / float(CHUTE_GORES * per)
			var a1 := TAU * (g * per + k + 1) / float(CHUTE_GORES * per)
			for ri in rings:
				var pts: Array[Vector3] = []
				for q in [[ri, a0], [ri + 1, a0], [ri + 1, a1], [ri, a1]]:
					var u: float = float(q[0]) / rings          # 0 apex .. 1 skirt
					var rr := CHUTE_R * sin(u * PI * 0.5)
					var y := CHUTE_H * cos(u * PI * 0.5)
					pts.append(Vector3(cos(q[1]) * rr, y, sin(q[1]) * rr))
				# The apex ring is a point: one triangle there (a degenerate one
				# gives a NaN normal = a black spot on some GPUs). Normals are the
				# dome's analytic ones (outward), not generated.
				var idxs := [0, 2, 1] if ri == 0 else [0, 2, 1, 0, 3, 2]
				for idx in idxs:
					var pv: Vector3 = pts[idx]
					var nrm := Vector3(pv.x / CHUTE_R, pv.y / CHUTE_H, pv.z / CHUTE_R)
					st.set_color(col)
					st.set_normal(nrm.normalized() if nrm.length() > 1e-4 else Vector3.UP)
					st.add_vertex(pv)
	_canopy = MeshInstance3D.new()
	_canopy.mesh = st.commit()
	_chute_mat = ShaderMaterial.new()
	_chute_mat.shader = load("res://shaders/chute.gdshader")
	_chute_mat.set_shader_parameter("gores", float(CHUTE_GORES))
	_chute_mat.set_shader_parameter("radius", CHUTE_R)
	_canopy.material_override = _chute_mat
	_chute.add_child(_canopy)
	var lm := CylinderMesh.new()
	lm.top_radius = 0.025
	lm.bottom_radius = 0.025
	lm.height = 1.0
	lm.radial_segments = 4
	lm.rings = 1
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.85, 0.85, 0.82)
	line_mat.roughness = 0.9
	for k in CHUTE_GORES:
		var line := MeshInstance3D.new()
		line.mesh = lm
		line.material_override = line_mat
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_chute.add_child(line)
		_chute_lines.append(line)
	add_child(_chute)
	_chute.visible = false


## Canopy pose: inflated overhead, or (collapse -> 1) falling over downwind
## and lying flat and crumpled on the ground. Lines run from the attach point
## (chute node origin) to the skirt.
func _update_chute(delta: float, attach_y: float) -> void:
	var c := _chute_collapse
	if vessel.landed:
		c = move_toward(c, 1.0, delta / 4.0)
	else:
		c = move_toward(c, 0.0, delta / 1.5)
	if c > 0.0 and _chute_collapse == 0.0:
		_chute_wind = randf() * TAU
	_chute_collapse = c
	_chute.position.y = attach_y
	# In the air the canopy streams behind along the airflow, whatever the
	# capsule does; on the ground it falls over relative to the upright ship.
	var flow := Basis()
	var vrel := vessel.surface_velocity().to_v3()
	if not vessel.landed and vrel.length() > 0.5:
		var up_local := (global_transform.basis.inverse() * -vrel).normalized()
		var axis := Vector3.UP.cross(up_local)
		if axis.length() > 1e-4:
			flow = Basis(axis.normalized(), Vector3.UP.angle_to(up_local))
		elif up_local.y < 0.0:
			flow = Basis(Vector3.RIGHT, PI)
	var target_q := flow.get_rotation_quaternion() if c == 0.0 else Quaternion.IDENTITY
	_chute_flow = _chute_flow.slerp(target_q, clampf(delta * 3.0, 0.0, 1.0))
	_chute.basis = Basis(_chute_flow) * Basis(Vector3.UP, _chute_wind)
	# 0..0.6: deflates and tips over; 0.6..1: settles flat on the ground.
	var tip := smoothstep(0.0, 0.7, c)
	var settle := smoothstep(0.45, 1.0, c)
	var ang := tip * deg_to_rad(90.0)
	var b := Basis(Vector3.RIGHT, ang)
	var sc := Vector3(lerpf(1.0, 0.75, tip), lerpf(1.0, 1.3, settle), lerpf(1.0, 0.06, settle))
	var centre := b * Vector3(0, CHUTE_L * lerpf(1.0, 0.85, tip), 0)
	# Lying on the ground: the vessel origin is the ground under the attach point.
	centre.y = lerpf(centre.y, 0.25 - attach_y, settle)
	_canopy.transform = Transform3D(b.scaled_local(sc), centre)
	_chute_mat.set_shader_parameter("collapse", c)
	_chute_mat.set_shader_parameter("ground_up", vessel.pos.normalized().to_v3())
	for k in _chute_lines.size():
		var a := TAU * k / float(_chute_lines.size())
		var skirt := _canopy.transform * Vector3(cos(a) * CHUTE_R, 0, sin(a) * CHUTE_R)
		var line := _chute_lines[k]
		var d := skirt.length()
		if d < 0.01:
			continue
		var dir := skirt / d
		var side := dir.cross(Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT).normalized()
		var basis := Basis(side, dir, side.cross(dir)).scaled_local(Vector3(1, d, 1))
		line.transform = Transform3D(basis, skirt * 0.5)


# --- Ship lights (night) ---------------------------------------------------------

var night := 0.0   ## 0 in daylight .. 1 in the dark; set by the flight scene
var ground_agl := INF   ## metres above the ground, set by the flight scene
var _nav: Array = []   ## {bulb: MeshInstance3D, light: OmniLight3D, strobe: bool, energy: float}
var _floods: Array[SpotLight3D] = []
var _fill: OmniLight3D
var _blink := 0.0


## Navigation lights on the capsule (red port / green starboard, steady; white
## double-flash strobe aft) and two warm floodlights at its base that wash the
## hull below. Small and dim, as on real spacecraft.
func _build_lights() -> void:
	if _stage_nodes.is_empty():
		return
	var s: Dictionary = vessel.stages[0]
	var node: Node3D = _stage_nodes[0]
	var r: float = float(s.diameter) * 0.5
	var L: float = s.length
	var top_r: float = float(s.diameter) * 0.17
	var y := 0.3
	var rr := _capsule_radius(r, top_r, L, 0.08, y) + 0.03
	var specs := [
		[Vector3(-rr, y, 0), Color(1.0, 0.08, 0.05), false, 0.1],   # port (-X)
		[Vector3(rr, y, 0), Color(0.1, 1.0, 0.25), false, 0.1],     # starboard (+X)
		[Vector3(0, L * 0.82, -_capsule_radius(r, top_r, L, 0.08, L * 0.82) - 0.03), Color(1, 1, 1), true, 1.6],
	]
	var housing_mat := StandardMaterial3D.new()
	housing_mat.albedo_color = Color(0.16, 0.16, 0.17)
	housing_mat.metallic = 0.6
	housing_mat.roughness = 0.45
	for sp in specs:
		# A real fixture: a dark metal socket on the hull and a glass dome on it.
		var nrm := Vector3((sp[0] as Vector3).x, 0.0, (sp[0] as Vector3).z).normalized()
		var side := nrm.cross(Vector3.UP).normalized()
		var on_hull := Basis(side, nrm, side.cross(nrm))   # local +Y = out of the hull
		var socket := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.05
		cm.bottom_radius = 0.06
		cm.height = 0.035
		cm.radial_segments = 12
		cm.rings = 1
		socket.mesh = cm
		socket.material_override = housing_mat
		socket.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		socket.transform = Transform3D(on_hull, (sp[0] as Vector3) - nrm * 0.01)
		node.add_child(socket)
		var bulb := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.036
		sm.height = 0.036
		sm.is_hemisphere = true
		sm.radial_segments = 12
		sm.rings = 4
		bulb.mesh = sm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = sp[1]
		bulb.material_override = m
		bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bulb.transform = Transform3D(on_hull, (sp[0] as Vector3) + nrm * 0.007)
		node.add_child(bulb)
		# Small glow sitting on the dome (bright core, short falloff), facing the camera.
		var halo := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.28, 0.28)
		halo.mesh = qm
		var hm := ShaderMaterial.new()
		hm.shader = _halo_shader()
		hm.set_shader_parameter("tint", Color(sp[1]))
		hm.set_shader_parameter("pull", 0.08)
		halo.material_override = hm
		halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bulb.add_child(halo)
		var l := OmniLight3D.new()
		l.light_color = sp[1]
		l.omni_range = 1.4
		l.light_cull_mask = 1   # lights the hull only, never reaches the ground (layer 2)
		l.omni_attenuation = 1.6
		l.light_energy = 0.0
		l.position = (sp[0] as Vector3) * 1.08
		node.add_child(l)
		# Coloured spill on the ground near touchdown: a second, wide light
		# that only reaches the ground layer (the hull keeps its small one).
		var g := OmniLight3D.new()
		g.light_color = sp[1]
		g.omni_range = 16.0
		g.omni_attenuation = 0.3   # nearly flat: an even tint around the lander, fading at the range
		g.light_energy = 0.0
		g.light_cull_mask = 2   # PlanetView.GROUND_LAYER: ground patch and rocks only
		g.shadow_enabled = false
		g.visible = false
		g.position = l.position
		node.add_child(g)
		_nav.append({"bulb": bulb, "light": l, "spill": g, "strobe": sp[2], "energy": sp[3]})
	# Floodlights: just outside the base ring, aimed down along the hull.
	for a in [deg_to_rad(-40.0), deg_to_rad(220.0)]:
		var f := SpotLight3D.new()
		f.light_color = Color(1.0, 0.9, 0.76)
		f.spot_range = 90.0
		f.spot_angle = 62.0
		f.spot_attenuation = 1.1          # gentle fade with distance
		f.spot_angle_attenuation = 0.2    # very soft edge of the cone
		f.light_energy = 0.0
		f.shadow_enabled = false
		var dir := Vector3(cos(a), 0, sin(a))
		f.position = dir * (r + 0.35) + Vector3(0, 0.12, 0)
		# -Z of the light looks straight down, tilted a hair towards the hull.
		f.basis = Basis.looking_at(Vector3.DOWN - dir * 0.12, dir)
		node.add_child(f)
		_floods.append(f)
	# Soft warm fill around the ship, so lit and unlit parts blend instead of a
	# hard line between light and dark.
	var fill := OmniLight3D.new()
	fill.light_color = Color(1.0, 0.88, 0.72)
	fill.omni_range = 40.0
	fill.omni_attenuation = 1.6
	fill.shadow_enabled = false
	fill.position = Vector3(0, -2.0, 0)
	node.add_child(fill)
	_fill = fill


static var _halo: Shader


static func _halo_shader() -> Shader:
	if _halo == null:
		_halo = Shader.new()
		_halo.code = """shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform vec4 tint : source_color;
uniform float pull = 0.08;   // metres towards the camera, so the lamp's own housing does not cut it
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX[3].z += pull;
}
void fragment() {
	// A lamp, not a cloud: hot white-ish core the size of the bulb, a short
	// bright falloff and only a faint wide glow.
	float d = length(UV - 0.5) * 2.0;
	float core = 1.0 - smoothstep(0.08, 0.2, d);
	float g = exp(-d * d * 22.0) * 0.9 + 0.12 * exp(-d * d * 5.0);
	g *= 1.0 - smoothstep(0.7, 1.0, d);
	ALBEDO = mix(tint.rgb, vec3(1.0), 0.6) * core * 1.4 + tint.rgb * g * 1.2;
	ALPHA = 1.0;
}
"""
	return _halo


const SPILL_GAIN := 4.0   ## ground glow of a nav light relative to its hull light
const SPILL_MAX := 0.6    ## the strobe flash on the ground stays soft


func _update_lights(delta: float) -> void:
	_blink = fmod(_blink + delta, 1.4)
	var on_flash := _blink < 0.05 or (_blink > 0.17 and _blink < 0.22)
	var n := clampf(night, 0.0, 1.0)
	for e in _nav:
		var lit: bool = on_flash if e.strobe else true
		(e.bulb as MeshInstance3D).visible = lit
		(e.light as OmniLight3D).light_energy = (e.energy as float) * n if lit else 0.0
		(e.light as OmniLight3D).visible = n > 0.01 and lit
		var near := 1.0 - smoothstep(10.0, 25.0, ground_agl)
		var spill := e.spill as OmniLight3D
		spill.light_energy = minf((e.energy as float) * SPILL_GAIN, SPILL_MAX) * n * near if lit else 0.0
		spill.visible = spill.light_energy > 0.001
	for f in _floods:
		f.light_energy = 8.0 * n
		f.visible = n > 0.01
	if _fill:
		_fill.light_energy = 1.6 * n
		_fill.visible = n > 0.01


# --- Re-entry: plasma, char, hot skin ---------------------------------------------

var _engine_light: OmniLight3D
var _plasma: MeshInstance3D
var _plasma_mat: ShaderMaterial
var _hull_mats: Dictionary = {}   ## stage node -> Array[ShaderMaterial]
var _char_shown: Dictionary = {}  ## stage node -> last char value pushed to shaders


func _build_plasma() -> void:
	var cm := _bow_shock_mesh()
	_plasma = MeshInstance3D.new()
	_plasma.mesh = cm
	_plasma_mat = ShaderMaterial.new()
	_plasma_mat.shader = load("res://shaders/plasma.gdshader")
	_plasma_mat.set_shader_parameter("noise_tex", _noise_tex())
	_plasma.material_override = _plasma_mat
	_plasma.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_plasma.top_level = true
	_plasma.visible = false
	add_child(_plasma)


## Bow shock shell in unit space: closed blunt apex at y = +0.5 (ahead of the
## leading end), widening downstream to radius 1.9 at y = -0.5 (open there,
## where the shader fades it out). No open rim in front: that showed as a hard
## glowing edge.
static func _bow_shock_mesh() -> ArrayMesh:
	const RINGS := 20
	const SEGS := 24
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in RINGS + 1:
		var t := float(i) / RINGS
		var d := t * t                        # denser near the apex
		var r := 1.9 * pow(d, 0.2)
		# Slope dr/dy for the normal (r = 1.9 d^0.2, y = 0.5 - d).
		var dr := 1.9 * 0.2 * pow(maxf(d, 1e-4), -0.8)
		for k in SEGS + 1:
			var a := TAU * k / SEGS
			var dir := Vector3(cos(a), 0.0, sin(a))
			verts.append(dir * r + Vector3(0, 0.5 - d, 0))
			norms.append((dir + Vector3(0, 1.0 / dr, 0)).normalized())
			uvs.append(Vector2(float(k) / SEGS, t))
	for i in RINGS:
		for k in SEGS:
			var a := i * (SEGS + 1) + k
			var b := a + SEGS + 1
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


func _collect_hull_mats() -> void:
	_hull_mats.clear()
	_char_shown.clear()
	for node in _stage_nodes:
		var mats: Array[ShaderMaterial] = []
		var stack: Array[Node] = [node]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			stack.append_array(n.get_children())
			if n is MeshInstance3D and (n as MeshInstance3D).material_override is ShaderMaterial:
				var m := (n as MeshInstance3D).material_override as ShaderMaterial
				if m.shader == HULL_SHADER and not mats.has(m):
					mats.append(m)
		_hull_mats[node] = mats


func hull_materials_of(node: Node3D) -> Array:
	var mats: Array = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is MeshInstance3D and (n as MeshInstance3D).material_override is ShaderMaterial:
			var m := (n as MeshInstance3D).material_override as ShaderMaterial
			if m.shader == HULL_SHADER and not mats.has(m):
				mats.append(m)
	return mats


func _update_reentry() -> void:
	var n_st := _stage_nodes.size()
	if n_st == 0 or n_st != vessel.stages.size():
		return
	var heat := clampf((vessel.heat_temp - 700.0) / maxf(vessel.heat_limit - 700.0, 1.0), 0.0, 1.0)
	var lead_i := 0 if vessel.heat_lead == "nose" else n_st - 1
	for i in n_st:
		var node := _stage_nodes[i]
		var s: Dictionary = vessel.stages[i]
		var ch := float(s.get("char", 0.0))
		var g := heat if i == lead_i else 0.0
		var last: Vector2 = _char_shown.get(node, Vector2(-1, -1))
		if absf(last.x - ch) < 0.01 and absf(last.y - g) < 0.01:
			continue
		_char_shown[node] = Vector2(ch, g)
		var top: bool = s.get("char_top", false)
		var L := float(s.length)
		for m in _hull_mats.get(node, []):
			m.set_shader_parameter("scorch", ch * 1.3)
			m.set_shader_parameter("scorch_y0", L if top else -0.2)
			m.set_shader_parameter("scorch_dir", -1.0 if top else 1.0)
			m.set_shader_parameter("scorch_len", clampf(L * 0.6, 1.2, 5.0))
			m.set_shader_parameter("glow", g)
	# Plasma sheath around the leading end, along the airflow.
	var q := vessel.heat_flux
	var pw := clampf(pow(q / 350_000.0, 0.7), 0.0, 1.0)
	_plasma.visible = pw > 0.03 and not vessel.destroyed_flag
	if not _plasma.visible:
		return
	var vdir := vessel.surface_velocity().to_v3().normalized()
	var total := 0.0
	for s in vessel.stages:
		total += float(s.length)
	var lead_local := Vector3.ZERO
	match vessel.heat_lead:
		"nose": lead_local = Vector3(0, total, 0)
		"side": lead_local = Vector3(0, vessel.com_height(), 0)
		_: lead_local = Vector3(0, -0.2, 0)
	var lead := global_transform * lead_local
	var R := 0.0
	for s in vessel.stages:
		R = maxf(R, float(s.diameter) * 0.5)
	R *= 1.12 if vessel.heat_lead != "side" else 1.6
	var length := R * lerpf(2.5, 7.0, pw) + (total * 0.8 if vessel.heat_lead == "side" else 0.0)
	var x := vdir.cross(Vector3.UP if absf(vdir.y) < 0.95 else Vector3.RIGHT).normalized()
	var z := x.cross(vdir)
	_plasma.global_transform = Transform3D(Basis(x * R, vdir * length, z * R), lead - vdir * (length * 0.5 - R * 0.35))
	_plasma_mat.set_shader_parameter("power", pw)


## Drops the visual of the bottom stage; returns it re-parented for debris.
func detach_bottom_stage() -> Node3D:
	if _stage_nodes.size() <= 1:
		return null
	var node: Node3D = _stage_nodes.pop_back()
	var gt := node.global_transform
	remove_child(node)
	# Shift remaining stages so the origin stays at the new bottom.
	var drop := _stage_nodes[_stage_nodes.size() - 1].position.y
	for n in _stage_nodes:
		n.position.y -= drop
	node.set_meta("global", gt)
	for f in _flames:
		f.queue_free()
	_build_flames()
	_build_collider()
	_update_legs()
	_hull_mats.erase(node)
	_char_shown.erase(node)
	return node


func update_visual(delta: float) -> void:
	if _chute and not _stage_nodes.is_empty():
		_chute.visible = vessel.chute_deployed
		if vessel.chute_deployed:
			var top: Node3D = _stage_nodes[0]
			_update_chute(delta, top.position.y + float(vessel.stages[0].length))
		else:
			_chute_collapse = 0.0
	_update_lights(delta)
	_update_reentry()
	# Hatch animation (eased swing about the hinge line).
	if hatch_pivot and not is_equal_approx(_hatch_open, _hatch_target):
		_hatch_open = move_toward(_hatch_open, _hatch_target, delta / 1.6)
		var e := _hatch_open * _hatch_open * (3.0 - 2.0 * _hatch_open)
		hatch_pivot.basis = _hatch_basis * Basis(Vector3.UP, -e * deg_to_rad(110.0))
		if _capsule_mat:
			_capsule_mat.set_shader_parameter("hatch_open", clampf(_hatch_open * 4.0, 0.0, 1.0))
	var on := vessel.last_thrust > 0.0
	var thr := vessel.last_thrust / maxf(vessel.current_thrust_max(), 1.0) if on else 0.0
	for m in _bell_mats:
		if is_instance_valid(m):
			m.set_shader_parameter("heat", thr * 0.6)
	for f in _flames:
		f.visible = on
	if _engine_light:
		_engine_light.visible = on and not _flames.is_empty()
	if not on or _stage_nodes.is_empty():
		return
	if _engine_light and _engine_light.visible:
		# Bright in air (a full luminous plume), dim in vacuum (thin, faint plume).
		var pr := clampf(vessel.body.pressure_at(vessel.altitude()), 0.0, 1.0)
		_engine_light.light_energy = lerpf(0.45, 1.0, thr) * lerpf(0.9, 3.2, pr) * randf_range(0.85, 1.15)
	var p := clampf(vessel.body.pressure_at(vessel.altitude()), 0.0, 1.0)
	_flame_mat.set_shader_parameter("throttle", lerpf(0.4, 1.0, thr))
	_flame_mat.set_shader_parameter("pressure", p)
	for f in _flames:
		var re: float = f.get_meta("re")
		var anchor: Vector3 = f.get_meta("anchor")
		# Long thin plume in air, short wide bloom in vacuum.
		var len := re * lerpf(9.0, 22.0, thr) * lerpf(0.8, 1.0, p)
		var width := re * lerpf(3.2, 1.05, p)
		var flick := 1.0 + randf_range(-0.04, 0.04)
		f.scale = Vector3(width, len * flick, width)
		f.position = anchor + Vector3(0, -len * flick * 0.5, 0)
