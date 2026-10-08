extends Node3D
## Map overlay: predicted patched-conic trajectory (one ribbon per segment, drawn
## around the segment's body), Ap/Pe markers, orbits of moons, body names, the
## vessel arrows and an optional maneuver preview.

const SEG_COLORS := [Color(0.35, 0.85, 1.0), Color(1.0, 0.75, 0.3), Color(0.9, 0.45, 1.0), Color(0.6, 1.0, 0.6)]
const PREVIEW_COLORS := [Color(1.0, 0.95, 0.4), Color(1.0, 0.6, 0.85), Color(0.7, 1.0, 1.0), Color(1, 1, 1)]
const BODY_ORBIT_COLOR := Color(0.55, 0.58, 0.65)

var root_body: CelestialBody

var _segments: Array[Dictionary] = []   ## {mesh, node, body, el, points, labels}
var _preview: Array[Dictionary] = []
var _body_orbits: Array[Dictionary] = []   ## {node, body (child), mesh, points}
var _body_labels := {}
var _ship_label: Label3D
var _arrow: MeshInstance3D
var _vel_arrow: MeshInstance3D
var _node_marker: Label3D


func setup(root: CelestialBody) -> void:
	root_body = root
	_ship_label = _label(Color(1, 1, 1), "ракета")
	_ship_label.offset = Vector2(0, -60)
	_arrow = _make_arrow(Color(1.0, 0.6, 0.2))
	_vel_arrow = _make_arrow(Color(0.5, 1.0, 0.55))
	_node_marker = _label(Color(1.0, 0.95, 0.4), "◆ манёвр")
	_node_marker.visible = false
	_add_body_recursive(root)


func _add_body_recursive(b: CelestialBody) -> void:
	var l := _label(Color(0.85, 0.88, 0.95), b.name)
	l.font_size = 34
	_body_labels[b] = l
	for c in b.children:
		var node := Node3D.new()
		add_child(node)
		var mesh := ImmediateMesh.new()
		var mi := _ribbon_instance(mesh, BODY_ORBIT_COLOR)
		node.add_child(mi)
		var el := OrbitMath.elements(c.state_at(0.0)[0], c.state_at(0.0)[1], b.mu)
		_body_orbits.append({"node": node, "parent": b, "body": c, "mesh": mesh,
			"points": OrbitMath.orbit_points(el, 240, INF), "normal": (el.h as DVec3).normalized().to_v3()})
		_add_body_recursive(c)


# --- Public API -------------------------------------------------------------------

## Replace the predicted trajectory (from Trajectory.predict).
func set_trajectory(segs: Array[Dictionary], current: CelestialBody) -> void:
	_set_segments(_segments, segs, SEG_COLORS, current)


## Maneuver preview (empty array hides it).
func set_preview(segs: Array[Dictionary], current: CelestialBody) -> void:
	_set_segments(_preview, segs, PREVIEW_COLORS, current)


## Per-frame placement. body_pos: Callable(CelestialBody, time) -> Vector3 render position
## of the body centre at that time (segments in another body are drawn where that
## body will be when the vessel arrives).
func update_view(body_pos: Callable, now: float, cam: Camera3D, ship_nose: Vector3, ship_vel: Vector3,
		node_pos = null) -> void:
	for s in _segments + _preview:
		var p: Vector3 = body_pos.call(s.body, s.anchor_t)
		s.node.position = p
		_rebuild_ribbon(s.mesh, s.points, s.normal, cam.global_position - p, 0.0035, s.color)
	for o in _body_orbits:
		var p: Vector3 = body_pos.call(o.parent, now)
		o.node.position = p
		_rebuild_ribbon(o.mesh, o.points, o.normal, cam.global_position - p, 0.002, BODY_ORBIT_COLOR)
	for b in _body_labels:
		var l: Label3D = _body_labels[b]
		l.position = body_pos.call(b, now) + Vector3(0, b.radius * 1.25, 0)
	_ship_label.position = Vector3.ZERO
	var size := cam.global_position.length() * 0.12
	_place_arrow(_arrow, Vector3.ZERO, ship_nose, size)
	_vel_arrow.visible = ship_vel.length() > 1.0
	if _vel_arrow.visible:
		_place_arrow(_vel_arrow, Vector3.ZERO, ship_vel.normalized(), size * 0.8)
	_node_marker.visible = node_pos != null
	if node_pos != null:
		_node_marker.position = node_pos


# --- Segments -------------------------------------------------------------------------

func _set_segments(store: Array[Dictionary], segs: Array[Dictionary], colors: Array, current: CelestialBody) -> void:
	for s in store:
		(s.node as Node3D).queue_free()
	store.clear()
	for i in segs.size():
		var sg: Dictionary = segs[i]
		var node := Node3D.new()
		add_child(node)
		var mesh := ImmediateMesh.new()
		var col: Color = colors[i % colors.size()]
		node.add_child(_ribbon_instance(mesh, col))
		var b: CelestialBody = sg.body
		var el: Dictionary = sg.el
		var normal := (el.h as DVec3).normalized().to_v3()
		var foreign := b != current
		var entry := {"node": node, "mesh": mesh, "body": b, "points": sg.points, "normal": normal,
			"color": col, "anchor_t": sg.t0 if foreign else -1.0}
		store.append(entry)
		if foreign:
			# Ghost of the body at encounter time.
			var ghost := MeshInstance3D.new()
			var gm := SphereMesh.new()
			gm.radius = b.radius
			gm.height = b.radius * 2.0
			gm.radial_segments = 32
			gm.rings = 16
			ghost.mesh = gm
			var gmat := StandardMaterial3D.new()
			gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			gmat.albedo_color = Color(col, 0.18)
			ghost.material_override = gmat
			node.add_child(ghost)
			_label(Color(col, 0.9), "%s при встрече" % b.name, node).position = Vector3(0, -b.radius * 1.3, 0)
		# Markers: Pe always (if above the surface), Ap only on closed orbits.
		var e: float = el.e
		var peri_dir: Vector3 = (el.e_vec as DVec3).normalized().to_v3() if e > 1e-6 else Vector3.ZERO
		if e > 0.002 and el.periapsis > b.radius and _periapsis_in_segment(sg):
			var lp := _label(Color(0.55, 1.0, 0.6), "Перицентр %s" % fmt_dist(el.periapsis - b.radius), node)
			lp.position = peri_dir * el.periapsis
		if sg.end == "loop" and e > 0.002 and e < 1.0:
			var la := _label(Color(1.0, 0.8, 0.35), "Апоцентр %s" % fmt_dist(el.apoapsis - b.radius), node)
			la.position = -peri_dir * el.apoapsis
		if sg.end == "impact":
			var li := _label(Color(1.0, 0.4, 0.35), "✕ падение", node)
			li.position = sg.points[sg.points.size() - 1]
		if sg.end == "enter":
			var ln := _label(Color(0.9, 0.9, 1.0), "→ %s" % (sg.next_body as CelestialBody).name, node)
			ln.position = sg.points[sg.points.size() - 1]


## True if the periapsis passage happens inside the drawn part of the segment.
func _periapsis_in_segment(sg: Dictionary) -> bool:
	if sg.end == "loop":
		return true
	var pts: PackedVector3Array = sg.points
	if pts.size() < 3:
		return false
	var minr := INF
	var idx := 0
	for i in pts.size():
		var l := pts[i].length()
		if l < minr:
			minr = l
			idx = i
	return idx > 0 and idx < pts.size() - 1


func _ribbon_instance(mesh: ImmediateMesh, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = col
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Width per point = its distance to the camera * width_k (constant on screen),
## so a long orbit line does not turn into a wide band near the camera.
func _rebuild_ribbon(mesh: ImmediateMesh, pts: PackedVector3Array, normal: Vector3, cam_local: Vector3,
		width_k: float, _col: Color) -> void:
	mesh.clear_surfaces()
	if pts.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in pts.size():
		var nxt := pts[mini(i + 1, pts.size() - 1)]
		var prv := pts[maxi(i - 1, 0)]
		var tangent := (nxt - prv).normalized()
		var side := normal.cross(tangent) * maxf(cam_local.distance_to(pts[i]) * width_k, 1.0)
		mesh.surface_add_vertex(pts[i] - side)
		mesh.surface_add_vertex(pts[i] + side)
	mesh.surface_end()


# --- Markers ------------------------------------------------------------------------

func _label(c: Color, text: String, parent: Node = null) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0012
	l.font_size = 30
	l.outline_size = 8
	l.modulate = c
	l.no_depth_test = true
	l.render_priority = 10
	l.text = text
	(parent if parent != null else self).add_child(l)
	return l


func _make_arrow(c: Color) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.06
	shaft.bottom_radius = 0.06
	shaft.height = 0.7
	shaft.radial_segments = 10
	st.append_from(shaft, 0, Transform3D(Basis(), Vector3(0, 0.35, 0)))
	var head := CylinderMesh.new()
	head.top_radius = 0.0
	head.bottom_radius = 0.18
	head.height = 0.3
	head.radial_segments = 12
	st.append_from(head, 0, Transform3D(Basis(), Vector3(0, 0.85, 0)))
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = c
	mat.no_depth_test = true
	mat.render_priority = 9
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _place_arrow(a: MeshInstance3D, pos: Vector3, dir: Vector3, size: float) -> void:
	var y := dir.normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	a.global_transform = Transform3D(Basis(x, y, z).scaled(Vector3.ONE * size), pos)


static func fmt_dist(m: float) -> String:
	if is_inf(m):
		return "∞"
	if absf(m) < 10_000.0:
		return "%d м" % int(m)
	if absf(m) < 10_000_000.0:
		return "%.1f км" % (m / 1000.0)
	return "%d км" % int(m / 1000.0)
