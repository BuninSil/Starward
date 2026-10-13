extends Node3D
## Safety tether. Physics: a soft distance limit between the hatch anchor and the
## astronaut (no force while slack, stiff spring + damper beyond `length`).
## Breaks above BREAK_TENSION. Visual: Verlet chain of SEGMENTS, cosmetic only,
## no collision with the ship.

const SEGMENTS := 36
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
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.72, 0.73, 0.75)
	metal.metallic = 0.9
	metal.roughness = 0.35
	# Carabiner: an elongated ring in the cord's plane.
	var ring := TorusMesh.new()
	ring.inner_radius = 0.022
	ring.outer_radius = 0.032
	ring.rings = 16
	ring.ring_segments = 6
	_hook = MeshInstance3D.new()
	_hook.mesh = ring
	_hook.material_override = metal
	add_child(_hook)
	# Reel housing at the hatch: a short drum the cord comes out of.
	var drum := CylinderMesh.new()
	drum.top_radius = 0.045
	drum.bottom_radius = 0.045
	drum.height = 0.05
	drum.radial_segments = 14
	var housing := StandardMaterial3D.new()
	housing.albedo_color = Color(0.2, 0.2, 0.22)
	housing.roughness = 0.5
	_reel = MeshInstance3D.new()
	_reel.mesh = drum
	_reel.material_override = housing
	add_child(_reel)


func reset_chain(a: Vector3, b: Vector3) -> void:
	_pts.resize(SEGMENTS + 1)
	_prev.resize(SEGMENTS + 1)
	_paid = 0.0
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


## Visual side: Verlet chain between anchor and astronaut, rendered as a round
## braided cord. Like a real EVA safety tether it comes off a spring reel at
## the hatch: the reel takes up the slack, so only a little more than the
## distance is paid out (the physical limit is still `length`). The chain has
## some bending stiffness (no kinks) and slides around the hull instead of
## passing through it. Simulated relative to the anchor, so floating-origin
## shifts of the scene do not kick the rope.
## obstacles: [Transform3D (centre, Y = axis), bottom radius, half height, top radius].
func update_visual(anchor: Vector3, astro: Vector3, _cam_pos: Vector3, dt: float, obstacles: Array = []) -> void:
	_mesh.clear_surfaces()
	_mi.visible = attached and not broken
	_hook.visible = _mi.visible
	_reel.visible = _mi.visible
	if not _mi.visible:
		return
	var tip := astro - anchor
	if _pts.size() != SEGMENTS + 1:
		reset_chain(Vector3.ZERO, tip)
	var c := tip.length()
	var want_len := clampf(c * 1.04 + 0.35, c, maxf(length, c))
	# The reel winds in and pays out at a finite speed.
	_paid = want_len if _paid <= 0.0 else clampf(want_len, _paid - 2.5 * dt, _paid + 6.0 * dt)
	_paid = maxf(_paid, c)
	var seg := _paid / SEGMENTS
	var damp := pow(0.9, dt * 60.0)
	# A weak drift towards a gentle arc keeps the slack floating smoothly.
	var bow := sqrt(maxf(3.0 * c * (_paid - c) / 8.0, 0.0))
	var side_dir := tip.cross(Vector3.UP)
	if side_dir.length() < 1e-3:
		side_dir = tip.cross(Vector3.RIGHT)
	side_dir = side_dir.normalized() if side_dir.length() > 1e-6 else Vector3.RIGHT
	for i in range(1, SEGMENTS):
		var p := _pts[i]
		var v := (p - _prev[i]) * damp
		_prev[i] = p
		var f := float(i) / SEGMENTS
		var rest := tip * f + side_dir * bow * 4.0 * f * (1.0 - f)
		_pts[i] = p + v + (rest - p) * minf(dt * 0.25, 0.02)
	# Obstacles in the anchor-relative frame.
	var obs: Array = []
	for o in obstacles:
		var xf: Transform3D = o[0]
		xf.origin -= anchor
		var r_top: float = o[3] if o.size() > 3 else o[1]
		obs.append([xf, xf.affine_inverse(), float(o[1]) + RADIUS + 0.02, float(o[2]), r_top + RADIUS + 0.02])
	for it in 14:
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
			if diff < 0.0:
				continue   # rope: only stretching is resisted
			var corr := delta * diff * 0.5
			if i > 0:
				_pts[i] = a + corr
			if i + 1 < SEGMENTS:
				_pts[i + 1] = b - corr
		# Bending stiffness: each point eases towards the middle of its
		# neighbours (smooth curves, no zigzag), then the slack stays as arcs.
		for i in range(1, SEGMENTS):
			_pts[i] = _pts[i].lerp((_pts[i - 1] + _pts[i + 1]) * 0.5, 0.12)
		# Hull: points inside a stage cylinder go out radially.
		for o in obs:
			var inv: Transform3D = o[1]
			var hh: float = o[3]
			for i in range(1, SEGMENTS):
				var lp := inv * _pts[i]
				if absf(lp.y) > hh:
					continue
				var r: float = lerpf(o[2], o[4], (lp.y + hh) / (2.0 * hh))
				var rad := Vector2(lp.x, lp.z)
				var rl := rad.length()
				if rl >= r:
					continue
				rad = rad / rl * r if rl > 1e-4 else Vector2(r, 0.0)
				_pts[i] = (o[0] as Transform3D) * Vector3(rad.x, lp.y, rad.y)
	_build_tube(anchor)
	_place_fittings(anchor)


var _paid := 0.0
var _hook: MeshInstance3D
var _reel: MeshInstance3D

const RADIUS := 0.014
const SIDES := 8
const SUBDIV := 3           ## smooth rings per chain segment (Catmull-Rom)
const BAND := 0.09          ## metres per braid band
const COL_A := Color(0.93, 0.8, 0.3)
const COL_B := Color(0.74, 0.6, 0.2)


## Smooth curve through the chain points.
func _curve() -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in SEGMENTS:
		var p0 := _pts[maxi(i - 1, 0)]
		var p1 := _pts[i]
		var p2 := _pts[i + 1]
		var p3 := _pts[mini(i + 2, SEGMENTS)]
		for k in SUBDIV:
			var t := float(k) / SUBDIV
			var t2 := t * t
			var t3 := t2 * t
			out.append(0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3))
	out.append(_pts[SEGMENTS])
	return out


## Round cord along the curve (rings carried along it, no twisting); the braid
## is a helix of two shades.
func _build_tube(anchor: Vector3) -> void:
	var pts := _curve()
	var n_pts := pts.size()
	var rings: Array[PackedVector3Array] = []
	var norms: Array[PackedVector3Array] = []
	var along := PackedFloat32Array()
	var n_prev := Vector3.ZERO
	var acc := 0.0
	for i in n_pts:
		var t := (pts[mini(i + 1, n_pts - 1)] - pts[maxi(i - 1, 0)])
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
			ring.append(anchor + pts[i] + dir * RADIUS)
			rn.append(dir)
		rings.append(ring)
		norms.append(rn)
		if i > 0:
			acc += (pts[i] - pts[i - 1]).length()
		along.append(acc)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n_pts - 1:
		for k in SIDES:
			var k2 := (k + 1) % SIDES
			for q in [[i, k], [i + 1, k], [i + 1, k2], [i, k], [i + 1, k2], [i, k2]]:
				# Helix: the band index shifts with the angle around the cord.
				var ph := along[q[0]] / BAND + float(q[1]) / SIDES
				_mesh.surface_set_color(COL_A if int(floor(ph)) % 2 == 0 else COL_B)
				_mesh.surface_set_normal(norms[q[0]][q[1]])
				_mesh.surface_add_vertex(rings[q[0]][q[1]])
	_mesh.surface_end()


## Carabiner at the suit end, reel housing at the hatch, along the cord.
func _place_fittings(anchor: Vector3) -> void:
	var t_end := (_pts[SEGMENTS] - _pts[SEGMENTS - 1]).normalized()
	var t_start := (_pts[1] - _pts[0]).normalized()
	# The ring's plane holds the cord; it hangs on past the clip point.
	var hb := _along_basis(t_end)
	var hook_b := Basis(hb.y * 1.5, hb.x, hb.z)
	_hook.global_transform = Transform3D(hook_b, anchor + _pts[SEGMENTS] + t_end * 0.03)
	_reel.global_transform = Transform3D(_along_basis(t_start), anchor)


static func _along_basis(t: Vector3) -> Basis:
	if t.length() < 1e-4:
		return Basis()
	var x := t.cross(Vector3.UP if absf(t.y) < 0.9 else Vector3.RIGHT).normalized()
	return Basis(x, t, x.cross(t).normalized())
