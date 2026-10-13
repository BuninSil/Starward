extends Node3D
## Safety tether. Physics: a soft distance limit between the hatch anchor and the
## astronaut (no force while slack, stiff spring + damper beyond `length`).
## Breaks above BREAK_TENSION. Visual: Verlet chain of SEGMENTS, cosmetic only,
## no collision with the ship.

const SEGMENTS := 25
const STIFFNESS := 400.0          ## N/m beyond the length
const DAMPING := 220.0            ## N per m/s of outward speed
const BREAK_TENSION := 1500.0     ## N
const MAX_LENGTH := 30.0
const MIN_LENGTH := 1.5
const WINCH_SPEED := 0.8          ## m/s

var attached := true
var broken := false
var length := 12.0
var tension := 0.0
var winching := false

var _pts: PackedVector3Array = PackedVector3Array()
var _prev: PackedVector3Array = PackedVector3Array()
var _mesh := ImmediateMesh.new()
var _mi: MeshInstance3D


func _ready() -> void:
	_mi = MeshInstance3D.new()
	_mi.mesh = _mesh
	# A round, lit braided cord (vertex colours give the braid bands).
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.75
	_mi.material_override = mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi)


func reset_chain(a: Vector3, b: Vector3) -> void:
	_pts.resize(SEGMENTS + 1)
	_prev.resize(SEGMENTS + 1)
	for i in SEGMENTS + 1:
		var p := a.lerp(b, float(i) / SEGMENTS)
		_pts[i] = p
		_prev[i] = p


## Physics side: returns the force on the astronaut (world) and updates tension.
func force_on(astro_pos: Vector3, astro_vel: Vector3, anchor: Vector3, anchor_vel: Vector3, dt: float) -> Vector3:
	tension = 0.0
	if not attached or broken:
		return Vector3.ZERO
	if winching:
		length = maxf(length - WINCH_SPEED * dt, MIN_LENGTH)
	var d := astro_pos - anchor
	var dist := d.length()
	if dist <= length or dist < 1e-4:
		return Vector3.ZERO
	var n := d / dist
	var stretch := dist - length
	var v_out := (astro_vel - anchor_vel).dot(n)
	tension = maxf(STIFFNESS * stretch + DAMPING * maxf(v_out, 0.0), 0.0)
	if tension > BREAK_TENSION:
		broken = true
		attached = false
		return Vector3.ZERO
	return -n * tension


func detach() -> void:
	attached = false


## Re-attach at the current distance (call only close to the hatch).
func attach(dist: float) -> void:
	attached = true
	broken = false
	length = clampf(maxf(dist, 3.0), MIN_LENGTH, MAX_LENGTH)


## Visual side: Verlet chain between anchor and astronaut, rendered as a ribbon.
## Simulated relative to the anchor, so floating-origin shifts of the scene do
## not kick the rope.
func update_visual(anchor: Vector3, astro: Vector3, cam_pos: Vector3, dt: float) -> void:
	_mesh.clear_surfaces()
	_mi.visible = attached and not broken
	if not _mi.visible:
		return
	var tip := astro - anchor
	if _pts.size() != SEGMENTS + 1:
		reset_chain(Vector3.ZERO, tip)
	# Visually the cord always keeps a little slack: a taut rope in zero g is a
	# dead straight line (looked like a stick). It drifts towards a gentle arc.
	var c := tip.length()
	var vis_len := maxf(length, c * 1.035)
	var seg := vis_len / SEGMENTS
	var bow := sqrt(maxf(3.0 * c * (vis_len - c) / 8.0, 0.0))   # arc height of a parabola that long
	var side_dir := tip.cross(Vector3.UP)
	if side_dir.length() < 1e-3:
		side_dir = tip.cross(Vector3.RIGHT)
	side_dir = side_dir.normalized() if side_dir.length() > 1e-6 else Vector3.RIGHT
	for i in range(1, SEGMENTS):
		var p := _pts[i]
		var v := (p - _prev[i]) * 0.94   # damping, no gravity in orbit
		_prev[i] = p
		var f := float(i) / SEGMENTS
		var rest := tip * f + side_dir * bow * 4.0 * f * (1.0 - f)
		_pts[i] = p + v + (rest - p) * minf(dt * 0.6, 0.05)
	for _it in 12:
		_pts[0] = Vector3.ZERO
		_pts[SEGMENTS] = tip
		for i in SEGMENTS:
			var a := _pts[i]
			var b := _pts[i + 1]
			var delta := b - a
			var dl := delta.length()
			if dl < 1e-6:
				continue
			var diff := (dl - seg) / dl
			# Rope: only resist stretching, slack is free to curl.
			if diff < 0.0:
				continue
			var corr := delta * diff * 0.5
			if i > 0:
				_pts[i] = a + corr
			if i + 1 < SEGMENTS:
				_pts[i + 1] = b - corr
	_build_tube(anchor)


const RADIUS := 0.015
const SIDES := 6
const BAND := 0.12          ## metres per braid band
const COL_A := Color(0.95, 0.78, 0.22)
const COL_B := Color(0.78, 0.6, 0.14)


## Round cord along the chain (rings carried along the curve, no twisting).
func _build_tube(anchor: Vector3) -> void:
	var rings: Array[PackedVector3Array] = []
	var norms: Array[PackedVector3Array] = []
	var n_prev := Vector3.ZERO
	var along := PackedFloat32Array()
	var acc := 0.0
	for i in SEGMENTS + 1:
		var t := (_pts[mini(i + 1, SEGMENTS)] - _pts[maxi(i - 1, 0)])
		t = t.normalized() if t.length() > 1e-6 else Vector3.UP
		var n := n_prev - t * n_prev.dot(t)
		if n.length() < 1e-4:
			n = t.cross(Vector3.UP if absf(t.y) < 0.9 else Vector3.RIGHT)
		n = n.normalized()
		n_prev = n
		var b := t.cross(n)
		var ring := PackedVector3Array()
		var rn := PackedVector3Array()
		for k in SIDES:
			var a := TAU * k / SIDES
			var dir := n * cos(a) + b * sin(a)
			ring.append(anchor + _pts[i] + dir * RADIUS)
			rn.append(dir)
		rings.append(ring)
		norms.append(rn)
		if i > 0:
			acc += (_pts[i] - _pts[i - 1]).length()
		along.append(acc)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGMENTS:
		var col := COL_A if int(along[i] / BAND) % 2 == 0 else COL_B
		for k in SIDES:
			var k2 := (k + 1) % SIDES
			for q in [[i, k], [i + 1, k], [i + 1, k2], [i, k], [i + 1, k2], [i, k2]]:
				_mesh.surface_set_color(col)
				_mesh.surface_set_normal(norms[q[0]][q[1]])
				_mesh.surface_add_vertex(rings[q[0]][q[1]])
	_mesh.surface_end()
