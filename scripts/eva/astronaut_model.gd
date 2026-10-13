extends Node3D
## Visual astronaut built in code with real EMU-suit proportions: hard upper
## torso, bellows joints, gloves, boots, a helmet with gold sun visor and
## lamps, PLSS backpack with jet unit, chest control box, red commander
## stripes. A small joint hierarchy is animated procedurally: idle breathing,
## walk / run (or the lunar bunny hop in low gravity), jump tuck and the
## neutral body posture of microgravity while floating. Feet at this node's
## origin, faces -Z, ~1.85 m tall. Physics stays in astronaut.gd.

const RV := preload("res://scripts/flight/rocket_view.gd")
const HULL_SHADER := preload("res://shaders/hull.gdshader")

## Thruster puff anchors (in this node's frame), around the backpack.
var pack_centre := Vector3(0, 1.3, 0.3)
var low_gravity := false

var _state := "idle"
var _speed := 1.0
var _phase := 0.0
var _t := 0.0
var _w := {}          ## current pose (joint -> rotation), blended toward the target

var _pelvis: Node3D
var _torso: Node3D
var _head: Node3D
var _arm := {}        ## side -> [shoulder, elbow, wrist]
var _leg := {}        ## side -> [hip, knee, ankle]
var _fabric: StandardMaterial3D
var _grey: StandardMaterial3D
var _dark: StandardMaterial3D

const PELVIS_Y := 0.98
const THIGH := 0.43
const SHIN := 0.43
const UPPER_ARM := 0.31
const FOREARM := 0.29


func _ready() -> void:
	_make_materials()
	_pelvis = _joint(self, Vector3(0, PELVIS_Y, 0))
	_mesh(_pelvis, _ellipsoid(0.19, 0.13, 0.15), _fabric, Vector3(0, 0.0, 0))
	# Brief / waist bearing.
	_mesh(_pelvis, _ring(0.15, 0.03), _grey, Vector3(0, 0.1, 0))
	_torso = _joint(_pelvis, Vector3(0, 0.12, 0))
	_build_torso()
	_head = _joint(_torso, Vector3(0, 0.56, 0))
	_build_helmet()
	for side in [-1.0, 1.0]:
		_arm[side] = _build_arm(side)
		_leg[side] = _build_leg(side)


# --- Materials & mesh helpers -----------------------------------------------------

func _make_materials() -> void:
	var weave := FastNoiseLite.new()
	weave.seed = 5
	weave.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	weave.frequency = 0.08
	weave.fractal_octaves = 3
	var nt := NoiseTexture2D.new()
	nt.width = 128
	nt.height = 128
	nt.seamless = true
	nt.as_normal_map = true
	nt.bump_strength = 2.5
	nt.noise = weave
	_fabric = StandardMaterial3D.new()
	_fabric.albedo_color = Color(0.93, 0.93, 0.91)
	_fabric.roughness = 0.88
	_fabric.normal_enabled = true
	_fabric.normal_texture = nt
	_fabric.normal_scale = 0.6
	_fabric.uv1_scale = Vector3(6, 6, 6)
	_grey = StandardMaterial3D.new()
	_grey.albedo_color = Color(0.62, 0.63, 0.65)
	_grey.roughness = 0.5
	_grey.metallic_specular = 0.6
	_dark = StandardMaterial3D.new()
	_dark.albedo_color = Color(0.12, 0.12, 0.13)
	_dark.roughness = 0.7


func _paint(c: Color, metal := 0.0, rough := 0.45) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = HULL_SHADER
	m.set_shader_parameter("base_color", c.srgb_to_linear())
	m.set_shader_parameter("metal", metal)
	m.set_shader_parameter("rough", rough)
	m.set_shader_parameter("gloss", 0.3)
	m.set_shader_parameter("noise_tex", RV._noise_tex())
	return m


func _joint(parent: Node3D, pos: Vector3) -> Node3D:
	var j := Node3D.new()
	j.position = pos
	parent.add_child(j)
	return j


func _mesh(parent: Node3D, mesh: Mesh, mat: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


## Limb segment hanging down from its joint: radius r0 at the top, r1 at the
## bottom, rounded ends, length len.
static func _limb(r0: float, r1: float, len: float) -> ArrayMesh:
	var p := PackedVector2Array()
	p.append(Vector2(0.0, -len - r1 * 0.6))
	for k in range(1, 5):
		var a := PI * 0.5 * float(k) / 4.0
		p.append(Vector2(r1 * sin(a), -len - r1 * 0.6 * cos(a)))
	for k in 5:
		var t := float(k) / 4.0
		# Slight bulge mid-segment (pressurised fabric).
		p.append(Vector2(lerpf(r1, r0, t) * (1.0 + 0.06 * sin(t * PI)), -len + len * t))
	for k in range(1, 5):
		var a := PI * 0.5 * float(k) / 4.0
		p.append(Vector2(r0 * cos(a), r0 * 0.6 * sin(a)))
	return RV._lathe(p, 20)


static func _ellipsoid(rx: float, ry: float, rz: float) -> ArrayMesh:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 24
	sm.rings = 12
	var st := SurfaceTool.new()
	st.create_from(sm, 0)
	var arrays := st.commit_to_arrays()
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in v.size():
		v[i] = Vector3(v[i].x * rx, v[i].y * ry, v[i].z * rz)
		n[i] = Vector3(n[i].x / rx, n[i].y / ry, n[i].z / rz).normalized()
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## Bellows ring (joint convolution) around a limb axis (Y).
static func _ring(r: float, t: float) -> ArrayMesh:
	var p := PackedVector2Array()
	for k in 9:
		var a := PI * float(k) / 8.0
		p.append(Vector2(r + sin(a) * t, -cos(a) * t))
	return RV._lathe(p, 20)


# --- Body parts ---------------------------------------------------------------------

func _build_torso() -> void:
	# Hard upper torso: a broad, slightly flattened shell.
	var hut := _mesh(_torso, _ellipsoid(0.27, 0.28, 0.19), _fabric, Vector3(0, 0.3, 0))
	hut.scale = Vector3(1.0, 1.0, 1.0)
	# Lower torso (waist).
	_mesh(_torso, _limb(0.19, 0.17, 0.16), _fabric, Vector3(0, 0.18, 0))
	# Neck ring.
	_mesh(_torso, _ring(0.13, 0.035), _grey, Vector3(0, 0.55, 0))
	# Display and control module on the chest.
	var bm := BoxMesh.new()
	bm.size = Vector3(0.26, 0.14, 0.1)
	var dcm := _mesh(_torso, bm, _paint(Color(0.85, 0.85, 0.84), 0.0, 0.5), Vector3(0, 0.32, -0.22))
	dcm.rotation.x = 0.25
	for k in 3:
		var knob := _mesh(dcm, RV._lathe(RV._bevel_cyl(0.018, 0.0, 0.03, 0.006), 10), _dark, Vector3(-0.07 + k * 0.07, 0.0, -0.05))
		knob.rotation.x = -PI * 0.5
	# PLSS backpack + jet unit below it.
	var plss := _paint(Color(0.92, 0.92, 0.9), 0.0, 0.5)
	var pk := _mesh(_torso, RV._lathe(RV._bevel_cyl(0.3, -0.33, 0.33, 0.06), 4, true), plss, Vector3(0, 0.32, 0.27))
	pk.rotation.y = PI * 0.25
	pk.scale = Vector3(0.95, 1.0, 0.5)
	var jet := _mesh(_torso, RV._lathe(RV._bevel_cyl(0.3, -0.07, 0.07, 0.03), 4, true), _paint(Color(0.55, 0.56, 0.58), 0.4, 0.4),
		Vector3(0, -0.06, 0.27))
	jet.rotation.y = PI * 0.25
	jet.scale = Vector3(0.95, 1.0, 0.5)
	for c in [Vector3(-0.19, 0.6, 0.38), Vector3(0.19, 0.6, 0.38), Vector3(-0.19, -0.1, 0.38), Vector3(0.19, -0.1, 0.38)]:
		_mesh(_torso, RV._lathe(PackedVector2Array([Vector2(0.02, 0.0), Vector2(0.02, 0.0), Vector2(0.035, 0.05), Vector2(0.035, 0.05)]), 10), _dark, c)


var lamps := 0.0   ## helmet lights 0..1 (set by the flight scene in the dark)
var _lamp_lights: Array[SpotLight3D] = []
var _lamp_halos: Array[MeshInstance3D] = []
var _lens_mat: StandardMaterial3D


func _build_helmet() -> void:
	_lens_mat = StandardMaterial3D.new()
	_lens_mat.albedo_color = Color(1.0, 0.98, 0.9)
	_lens_mat.roughness = 0.1
	_lens_mat.emission_enabled = true
	_lens_mat.emission = Color(1.0, 0.92, 0.75)
	_lens_mat.emission_energy_multiplier = 0.0
	# White protective shell (back), gold sun visor (front), lamps.
	var sph := PackedVector2Array()
	for k in 13:
		var a := -PI * 0.5 + PI * float(k) / 12.0
		sph.append(Vector2(cos(a) * 0.19, sin(a) * 0.19 + 0.17))
	var shell := RV._lathe(sph, 24, false, false, false, 0.75 + 0.2, 0.75 - 0.2 + 1.0, 0.012)
	_mesh(_head, shell, _paint(Color(0.94, 0.94, 0.93), 0.0, 0.35))
	var vis := PackedVector2Array()
	for k in 11:
		var a := -0.85 + 1.75 * float(k) / 10.0
		vis.append(Vector2(cos(a) * 0.185, sin(a) * 0.185 + 0.17))
	_mesh(_head, RV._lathe(vis, 24, false, false, false, 0.75 - 0.24, 0.75 + 0.24), _paint(Color(0.95, 0.72, 0.28), 1.0, 0.12))
	# Inside of the shell / visor seen at grazing angles: dark.
	var inner := MeshInstance3D.new()
	var im := SphereMesh.new()
	im.radius = 0.17
	im.height = 0.34
	inner.mesh = im
	inner.material_override = _dark
	inner.position = Vector3(0, 0.17, 0)
	_head.add_child(inner)
	for sx in [-1.0, 1.0]:
		var lamp := _mesh(_head, RV._lathe(RV._bevel_cyl(0.03, -0.05, 0.05, 0.012), 12), _grey, Vector3(sx * 0.2, 0.25, -0.02))
		lamp.rotation.x = -PI * 0.5   # lens towards the front (-Z)
		_mesh(lamp, RV._lathe(PackedVector2Array([Vector2(0.0, 0.05), Vector2(0.024, 0.05)]), 12), _lens_mat)
		# EMU helmet lights: a wide, soft warm beam where the astronaut looks.
		var l := SpotLight3D.new()
		l.light_color = Color(1.0, 0.93, 0.82)
		l.spot_range = 35.0
		l.spot_angle = 40.0
		l.spot_attenuation = 0.9
		l.spot_angle_attenuation = 0.45
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.visible = false
		l.position = Vector3(sx * 0.2, 0.25, -0.08)
		l.rotation.x = deg_to_rad(-8.0)
		_head.add_child(l)
		_lamp_lights.append(l)
		# Glow around the lens: a camera-facing halo, so the lamp itself shines.
		var halo := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.4, 0.4)
		halo.mesh = qm
		var hm := ShaderMaterial.new()
		hm.shader = RV._halo_shader()
		hm.set_shader_parameter("tint", Color(1.0, 0.9, 0.7))
		halo.material_override = hm
		halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		halo.position = Vector3(sx * 0.2, 0.25, -0.1)
		halo.visible = false
		_head.add_child(halo)
		_lamp_halos.append(halo)


func _build_arm(side: float) -> Array:
	var sh := _joint(_torso, Vector3(side * 0.3, 0.46, 0.0))
	_mesh(sh, _ellipsoid(0.12, 0.11, 0.12), _fabric)
	_mesh(sh, _ring(0.1, 0.024), _grey, Vector3(0, -0.06, 0))
	_mesh(sh, _limb(0.1, 0.088, UPPER_ARM), _fabric)
	var el := _joint(sh, Vector3(0, -UPPER_ARM, 0))
	_mesh(el, _ring(0.086, 0.022), _grey)
	_mesh(el, _limb(0.086, 0.07, FOREARM), _fabric)
	var wr := _joint(el, Vector3(0, -FOREARM, 0))
	_mesh(wr, _ring(0.068, 0.02), _grey)
	# Glove: palm block + thumb.
	var glove := _paint(Color(0.78, 0.78, 0.77), 0.0, 0.7)
	_mesh(wr, _ellipsoid(0.058, 0.08, 0.04), glove, Vector3(0, -0.085, 0))
	var th := _mesh(wr, _ellipsoid(0.018, 0.04, 0.018), glove, Vector3(0, -0.07, -0.04))
	th.rotation.x = 0.6
	# Wrist checklist on the left forearm.
	if side < 0.0:
		_mesh(el, _ellipsoid(0.05, 0.06, 0.02), _paint(Color(0.85, 0.85, 0.84), 0.0, 0.6), Vector3(0, -0.2, -0.07))
	return [sh, el, wr]


func _build_leg(side: float) -> Array:
	var hip := _joint(_pelvis, Vector3(side * 0.12, -0.04, 0.0))
	_mesh(hip, _ring(0.12, 0.026), _grey, Vector3(0, -0.06, 0))
	_mesh(hip, _limb(0.135, 0.11, THIGH), _fabric)
	# Red commander stripe band on the thigh.
	_mesh(hip, _ring(0.13, 0.012), _paint(Color(0.75, 0.1, 0.08), 0.0, 0.6), Vector3(0, -0.2, 0))
	var kn := _joint(hip, Vector3(0, -THIGH, 0))
	_mesh(kn, _ring(0.108, 0.026), _grey)
	_mesh(kn, _limb(0.108, 0.092, SHIN), _fabric)
	_mesh(kn, _ring(0.105, 0.012), _paint(Color(0.75, 0.1, 0.08), 0.0, 0.6), Vector3(0, -0.15, 0))
	var an := _joint(kn, Vector3(0, -SHIN, 0))
	# Boot: upper + sole.
	_mesh(an, _ellipsoid(0.085, 0.075, 0.14), _paint(Color(0.88, 0.88, 0.86), 0.0, 0.7), Vector3(0, -0.02, -0.04))
	var sole := _mesh(an, RV._lathe(RV._bevel_cyl(0.07, -0.025, 0.025, 0.012), 16), _dark, Vector3(0, -0.075, -0.04))
	sole.scale = Vector3(1.05, 1.0, 1.9)
	return [hip, kn, an]


# --- Animation ---------------------------------------------------------------------

## Animation state: "float" (EVA in space), "idle", "walk", "run", "jump".
func play(state: String, speed := 1.0) -> void:
	_state = state
	_speed = speed


func _update_lamps() -> void:
	var n := clampf(lamps, 0.0, 1.0)
	for l in _lamp_lights:
		l.light_energy = 6.0 * n
		l.visible = n > 0.01
	for h in _lamp_halos:
		h.visible = n > 0.5
	if _lens_mat:
		_lens_mat.emission_energy_multiplier = 6.0 * n


func _process(delta: float) -> void:
	_update_lamps()
	_t += delta
	var target := {}
	var bob := 0.0
	var lean := 0.0
	match _state:
		"walk", "run":
			var run := _state == "run"
			# Low gravity: an Apollo-style lope (alternating legs, long slow strides,
			# a short float between steps) rather than a two-footed hop, which on
			# loop looked like flying.
			var hop := false
			_phase += delta * (5.2 if run else 4.2) * _speed * (0.6 if low_gravity else 1.0)
			for side in [-1.0, 1.0]:
				var ph := _phase + (0.0 if hop else (PI if side > 0.0 else 0.0))
				var swing := sin(ph) * (0.25 if hop else (0.55 if run else 0.38))
				target["hip%d" % side] = swing - (0.25 if hop else 0.0)
				target["knee%d" % side] = -(0.15 + (0.9 if run else 0.55) * pow(maxf(0.0, sin(ph + 1.1)), 1.5)) - (0.35 if hop else 0.0)
				target["ankle%d" % side] = -swing * 0.4 + 0.1
				target["sh%d" % side] = -sin(ph) * (0.15 if hop else (0.45 if run else 0.3)) + (0.25 if hop else 0.0)
				target["el%d" % side] = 0.35 + (0.5 if run else 0.2)
				target["abd%d" % side] = 0.12
			bob = absf(sin(_phase)) * (0.07 if low_gravity and run else (0.05 if run else 0.025))
			lean = 0.18 if hop else (0.12 if run else 0.05)
		"drill":
			# Kneeling, both hands on the drill in front of the knees.
			for side in [-1.0, 1.0]:
				target["hip%d" % side] = 1.1 if side > 0.0 else 0.4
				target["knee%d" % side] = -1.7 if side > 0.0 else -0.9
				target["ankle%d" % side] = 0.5
				target["sh%d" % side] = 0.95 + 0.05 * sin(_t * 30.0)
				target["el%d" % side] = 0.7
				target["abd%d" % side] = 0.05
			bob = -0.2 + 0.01 * sin(_t * 40.0)
			lean = 0.35
		"jump":
			for side in [-1.0, 1.0]:
				target["hip%d" % side] = 0.5
				target["knee%d" % side] = -0.9
				target["ankle%d" % side] = 0.3
				target["sh%d" % side] = 0.6
				target["el%d" % side] = 0.6
				target["abd%d" % side] = 0.25
			lean = 0.1
		"float":
			# Neutral body posture: arms forward and up, hips and knees bent.
			for side in [-1.0, 1.0]:
				var w := sin(_t * 0.6 + side) * 0.1
				target["hip%d" % side] = 0.45 + w
				target["knee%d" % side] = -0.75 + w
				target["ankle%d" % side] = 0.3
				target["sh%d" % side] = 0.75 + sin(_t * 0.5 + side * 2.0) * 0.12
				target["el%d" % side] = 0.8
				target["abd%d" % side] = 0.35
			lean = 0.1
		_:
			# Idle: pressurised suit keeps arms slightly out and bent; breathing.
			for side in [-1.0, 1.0]:
				target["hip%d" % side] = 0.03
				target["knee%d" % side] = -0.08
				target["ankle%d" % side] = 0.05
				target["sh%d" % side] = 0.12 + sin(_t * 1.3) * 0.02
				target["el%d" % side] = 0.4
				target["abd%d" % side] = 0.22
			lean = 0.03 + sin(_t * 0.4) * 0.02
	# Blend toward the target pose (no pops between states).
	var k := 1.0 - exp(-delta * 10.0)
	for key in target:
		_w[key] = lerpf(float(_w.get(key, 0.0)), float(target[key]), k)
	_w["lean"] = lerpf(float(_w.get("lean", 0.0)), lean, k)
	_w["bob"] = lerpf(float(_w.get("bob", 0.0)), bob, k)
	_apply()


func _apply() -> void:
	# Knee bend lowers the pelvis so the boots stay on the ground.
	var knee := (float(_w.get("knee-1", 0.0)) + float(_w.get("knee1", 0.0))) * 0.5
	var drop := (1.0 - cos(knee)) * 0.22 if _state != "float" and _state != "jump" else 0.0
	_pelvis.position.y = PELVIS_Y - drop + float(_w.get("bob", 0.0))
	_torso.rotation.x = -float(_w.get("lean", 0.0))
	# Breathing: the chest rises a little.
	_torso.scale = Vector3.ONE * (1.0 + sin(_t * 1.6) * 0.008)
	_head.rotation.y = sin(_t * 0.3) * 0.08
	for side in [-1.0, 1.0]:
		var a: Array = _arm[side]
		(a[0] as Node3D).rotation = Vector3(float(_w.get("sh%d" % side, 0.0)), 0.0, side * float(_w.get("abd%d" % side, 0.0)))
		(a[1] as Node3D).rotation = Vector3(float(_w.get("el%d" % side, 0.0)), 0.0, 0.0)
		var l: Array = _leg[side]
		(l[0] as Node3D).rotation = Vector3(float(_w.get("hip%d" % side, 0.0)), 0.0, side * 0.03)
		(l[1] as Node3D).rotation = Vector3(float(_w.get("knee%d" % side, 0.0)), 0.0, 0.0)
		(l[2] as Node3D).rotation = Vector3(float(_w.get("ankle%d" % side, 0.0)), 0.0, 0.0)
