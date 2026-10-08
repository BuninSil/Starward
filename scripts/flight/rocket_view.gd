extends Node3D
## Procedural rocket model built from primitives, one child per stage, stacked
## along +Y with the origin at the bottom of the lowest stage.

var vessel: Vessel
var _stage_nodes: Array[Node3D] = []
var _flame: MeshInstance3D
var _flame_mat: StandardMaterial3D
var _chute: Node3D
## Ship collision for EVA (follows the rocket node, pushes the astronaut).
var collider: AnimatableBody3D
const HATCH_HEIGHT := 0.35   ## fraction of the capsule height


func build(v: Vessel) -> void:
	vessel = v
	for c in get_children():
		c.queue_free()
	_stage_nodes.clear()
	var y := 0.0
	# Bottom to top.
	for i in range(v.stages.size() - 1, -1, -1):
		var s: Dictionary = v.stages[i]
		var node := Node3D.new()
		node.name = s.name
		node.position.y = y
		add_child(node)
		_stage_nodes.push_front(node)
		if i == 0:
			_build_capsule(node, s)
		else:
			_build_tank_stage(node, s, i == v.stages.size() - 1)
		y += s.length
	_build_flame()
	_build_chute()
	_build_collider()
	_update_legs()


func _material(color: Color, metallic := 0.3, rough := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = rough
	return m


func _build_tank_stage(node: Node3D, s: Dictionary, bottom: bool) -> void:
	var d: float = s.diameter
	var length: float = s.length
	var engine_len := 1.2 if bottom else 0.9
	var base := 0.0
	if s.get("legs", false):
		base = 0.6           # ground clearance under the bell, legs reach y = 0
		engine_len = 0.7
		_build_legs(node, s, base)
	# Engine bell
	var bell := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = d * 0.18
	bm.bottom_radius = d * 0.32
	bm.height = engine_len
	bm.radial_segments = 20
	bell.mesh = bm
	bell.material_override = _material(Color(0.25, 0.25, 0.28), 0.8, 0.35)
	bell.position.y = base + engine_len * 0.5
	node.add_child(bell)
	# Tank
	var tank := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = d * 0.5
	tm.bottom_radius = d * 0.5
	tm.height = length - engine_len - base
	tm.radial_segments = 32 if not s.get("legs", false) else 8
	tank.mesh = tm
	var gold: bool = s.get("legs", false) or s.name == "Взлётная ступень"
	tank.material_override = _material(Color(0.85, 0.68, 0.3), 0.7, 0.35) if gold else _material(Color(0.92, 0.92, 0.9), 0.1, 0.6)
	tank.position.y = base + engine_len + tm.height * 0.5
	node.add_child(tank)
	# Dark band = decoupler at the top of the stage
	var band := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = d * 0.5 + 0.02
	dm.bottom_radius = d * 0.5 + 0.02
	dm.height = 0.35
	dm.radial_segments = 32
	band.mesh = dm
	band.material_override = _material(Color(0.12, 0.12, 0.14), 0.4, 0.5)
	band.position.y = length - 0.18
	node.add_child(band)
	# Fins on the bottom stage (not on a lander)
	if bottom and not s.get("legs", false):
		for k in 4:
			var fin := MeshInstance3D.new()
			var fm := BoxMesh.new()
			fm.size = Vector3(0.12, 2.0, 1.2)
			fin.mesh = fm
			fin.material_override = _material(Color(0.75, 0.2, 0.15), 0.2, 0.6)
			var ang := TAU * k / 4.0 + PI / 4.0
			fin.position = Vector3(cos(ang), 0, sin(ang)) * (d * 0.5 + 0.5) + Vector3(0, engine_len + 1.0, 0)
			fin.rotation.y = -ang
			node.add_child(fin)


## Four landing legs: struts from the tank side down to foot pads at y = 0.
## Hidden while a stage is attached below (see _update_legs).
func _build_legs(node: Node3D, s: Dictionary, base: float) -> void:
	var legs := Node3D.new()
	legs.name = "Legs"
	node.add_child(legs)
	var r: float = float(s.diameter) * 0.5
	var mat := _material(Color(0.7, 0.7, 0.72), 0.8, 0.4)
	for k in 4:
		var ang := TAU * k / 4.0 + PI / 4.0
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var top := dir * (r * 0.9) + Vector3(0, base + float(s.length) * 0.55, 0)
		var foot := dir * (r + 1.1) + Vector3(0, 0.12, 0)
		var strut := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.07
		cm.bottom_radius = 0.07
		cm.height = top.distance_to(foot)
		cm.radial_segments = 8
		strut.mesh = cm
		strut.material_override = mat
		legs.add_child(strut)
		strut.transform = _segment(top, foot)
		# Diagonal brace from the tank bottom.
		var brace := MeshInstance3D.new()
		var bm := CylinderMesh.new()
		var b0 := dir * (r * 0.9) + Vector3(0, base + 0.2, 0)
		var b1 := (top + foot) * 0.5
		bm.top_radius = 0.045
		bm.bottom_radius = 0.045
		bm.height = b0.distance_to(b1)
		bm.radial_segments = 6
		brace.mesh = bm
		brace.material_override = mat
		legs.add_child(brace)
		brace.transform = _segment(b0, b1)
		var pad := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.3
		pm.bottom_radius = 0.38
		pm.height = 0.12
		pm.radial_segments = 12
		pad.mesh = pm
		pad.material_override = mat
		pad.position = foot - Vector3(0, 0.06, 0)
		legs.add_child(pad)


## Local transform for a Y-axis cylinder spanning a..b.
static func _segment(a: Vector3, b: Vector3) -> Transform3D:
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x, y, z), (a + b) * 0.5)


## Legs are deployed only on the bottom stage.
func _update_legs() -> void:
	for i in _stage_nodes.size():
		var legs := _stage_nodes[i].get_node_or_null("Legs") as Node3D
		if legs:
			legs.visible = i == _stage_nodes.size() - 1


func _build_capsule(node: Node3D, s: Dictionary) -> void:
	var d: float = s.diameter
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = d * 0.18
	cm.bottom_radius = d * 0.5
	cm.height = s.length
	cm.radial_segments = 32
	cone.mesh = cm
	cone.material_override = _material(Color(0.82, 0.84, 0.86), 0.5, 0.45)
	cone.position.y = s.length * 0.5
	node.add_child(cone)
	# Hatch on the +Z side of the capsule.
	var hatch := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.75, 0.9, 0.08)
	hatch.mesh = hm
	hatch.material_override = _material(Color(0.25, 0.27, 0.3), 0.6, 0.4)
	var hy: float = s.length * HATCH_HEIGHT
	var hr := lerpf(d * 0.5, d * 0.18, HATCH_HEIGHT)
	hatch.position = Vector3(0, hy, hr - 0.02)
	hatch.rotation.x = -atan2(d * 0.5 - d * 0.18, s.length)
	node.add_child(hatch)
	var window := MeshInstance3D.new()
	var wm := SphereMesh.new()
	wm.radius = 0.22
	wm.height = 0.44
	window.mesh = wm
	var wmat := _material(Color(0.1, 0.2, 0.35), 0.9, 0.1)
	window.material_override = wmat
	window.position = Vector3(0, s.length * 0.45, d * 0.36)
	node.add_child(window)


func _build_flame() -> void:
	_flame = MeshInstance3D.new()
	var fm := CylinderMesh.new()
	fm.top_radius = 0.5
	fm.bottom_radius = 0.05
	fm.height = 1.0
	fm.radial_segments = 16
	_flame.mesh = fm
	_flame_mat = StandardMaterial3D.new()
	_flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flame_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flame_mat.albedo_color = Color(1.0, 0.6, 0.25, 0.85)
	_flame_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_flame.material_override = _flame_mat
	_flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_flame)
	_flame.visible = false


## Hatch position in the rocket node's local frame (slightly outside the hull).
func hatch_local() -> Vector3:
	if _stage_nodes.is_empty():
		return Vector3.ZERO
	var cap: Node3D = _stage_nodes[0]
	var s: Dictionary = vessel.stages[0]
	var d: float = s.diameter
	var hr := lerpf(d * 0.5, d * 0.18, HATCH_HEIGHT)
	return cap.position + Vector3(0, float(s.length) * HATCH_HEIGHT, hr + 0.35)


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


func _build_chute() -> void:
	_chute = Node3D.new()
	var canopy := MeshInstance3D.new()
	var cm := SphereMesh.new()
	cm.radius = 8.0
	cm.height = 8.0
	cm.is_hemisphere = true
	cm.radial_segments = 24
	cm.rings = 8
	canopy.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.15)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.8
	canopy.material_override = mat
	canopy.position.y = 14.0
	_chute.add_child(canopy)
	for k in 8:
		var line := MeshInstance3D.new()
		var lm := CylinderMesh.new()
		lm.top_radius = 0.03
		lm.bottom_radius = 0.03
		lm.height = 14.0
		line.mesh = lm
		var ang := TAU * k / 8.0
		var top := Vector3(cos(ang) * 7.5, 14.0, sin(ang) * 7.5)
		line.position = top * 0.5
		line.look_at_from_position(top * 0.5, Vector3.ZERO, Vector3.FORWARD if absf(top.normalized().y) > 0.99 else Vector3.UP)
		line.rotate_object_local(Vector3.RIGHT, PI * 0.5)
		_chute.add_child(line)
	add_child(_chute)
	_chute.visible = false


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
	_build_collider()
	_update_legs()
	return node


func update_visual(delta: float) -> void:
	if _chute and not _stage_nodes.is_empty():
		_chute.visible = vessel.chute_deployed
		var top: Node3D = _stage_nodes[0]
		_chute.position.y = top.position.y + float(vessel.stages[0].length)
	var on := vessel.last_thrust > 0.0
	_flame.visible = on
	if not on or _stage_nodes.is_empty():
		return
	var s := vessel.active_stage()
	var d: float = s.diameter
	var thr := vessel.last_thrust / maxf(vessel.current_thrust_max(), 1.0)
	# Wider plume in vacuum.
	var p := clampf(vessel.body.pressure_at(vessel.altitude()), 0.0, 1.0)
	var len := lerpf(4.0, 9.0, thr) * lerpf(1.3, 1.0, p)
	var width := d * lerpf(0.9, 0.35, p)
	var flicker := 1.0 + randf_range(-0.06, 0.06)
	_flame.scale = Vector3(width, len * flicker, width)
	_flame.position = Vector3(0, -len * flicker * 0.5 + 0.1, 0)
	_flame_mat.albedo_color.a = lerpf(0.5, 0.9, thr)
