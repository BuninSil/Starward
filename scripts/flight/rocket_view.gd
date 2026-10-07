extends Node3D
## Procedural rocket model built from primitives, one child per stage, stacked
## along +Y with the origin at the bottom of the lowest stage.

var vessel: Vessel
var _stage_nodes: Array[Node3D] = []
var _flame: MeshInstance3D
var _flame_mat: StandardMaterial3D


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
	# Engine bell
	var bell := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = d * 0.18
	bm.bottom_radius = d * 0.32
	bm.height = engine_len
	bm.radial_segments = 20
	bell.mesh = bm
	bell.material_override = _material(Color(0.25, 0.25, 0.28), 0.8, 0.35)
	bell.position.y = engine_len * 0.5
	node.add_child(bell)
	# Tank
	var tank := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = d * 0.5
	tm.bottom_radius = d * 0.5
	tm.height = length - engine_len
	tm.radial_segments = 32
	tank.mesh = tm
	tank.material_override = _material(Color(0.92, 0.92, 0.9), 0.1, 0.6)
	tank.position.y = engine_len + tm.height * 0.5
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
	# Fins on the bottom stage
	if bottom:
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
	return node


func update_visual(delta: float) -> void:
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
