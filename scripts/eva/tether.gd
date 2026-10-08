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
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.82, 0.25)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
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
func update_visual(anchor: Vector3, astro: Vector3, cam_pos: Vector3, dt: float) -> void:
	_mesh.clear_surfaces()
	_mi.visible = attached and not broken
	if not _mi.visible:
		return
	if _pts.size() != SEGMENTS + 1:
		reset_chain(anchor, astro)
	var seg := length / SEGMENTS
	for i in range(1, SEGMENTS):
		var p := _pts[i]
		var v := (p - _prev[i]) * 0.97   # light damping, no gravity in orbit
		_prev[i] = p
		_pts[i] = p + v
	for _it in 12:
		_pts[0] = anchor
		_pts[SEGMENTS] = astro
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
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in SEGMENTS + 1:
		var p := _pts[i]
		var tangent := (_pts[mini(i + 1, SEGMENTS)] - _pts[maxi(i - 1, 0)]).normalized()
		var side := tangent.cross((cam_pos - p).normalized()).normalized() * 0.025
		_mesh.surface_add_vertex(p - side)
		_mesh.surface_add_vertex(p + side)
	_mesh.surface_end()
