extends Node3D
## Debug "parts showcase": every stage of every prebuilt rocket on its own
## turntable in a row, plus the assembled rockets, in neutral studio light with
## sun shadows. Swipe to orbit the camera, ◀ ▶ to move between parts, «Люк»
## swings the capsule hatch. Used to check that all parts render correctly
## from every side after model changes.

const RocketView := preload("res://scripts/flight/rocket_view.gd")

var _items: Array[Dictionary] = []   ## {node: Node3D, name: String, size: float}
var _index := 0
var _cam: Camera3D
var _yaw := 0.6
var _pitch := 0.25
var _dist := 8.0
var _label: Label
var _views: Array = []
var _drag := false
var _root_body: CelestialBody


func _ready() -> void:
	_build_world()
	_root_body = SolarSystem.build()
	var earth := SolarSystem.find(_root_body, "earth")
	var x := 0.0
	for design in ["moon", "orbit"]:
		var v := Vessel.make(design, earth)
		# Assembled rocket first.
		var whole := RocketView.new()
		add_child(whole)
		whole.build(v)
		_views.append(whole)
		var h := 0.0
		for s in v.stages:
			h += float(s.length)
		x = _place(whole, x, Vessel.DESIGNS[design], h, 4.0)
		# Then each stage alone on a turntable.
		var parts := RocketView.new()
		add_child(parts)
		parts.build(v)
		_views.append(parts)
		for i in v.stages.size():
			var s: Dictionary = v.stages[i]
			var node: Node3D = parts._stage_nodes[i]
			var table := Node3D.new()
			add_child(table)
			node.reparent(table, false)
			node.position = Vector3.ZERO
			x = _place(table, x, s.name, float(s.length) + (0.6 if s.get("legs", false) else 0.0), float(s.diameter) + 2.5)
		parts.visible = false
	_build_ui()
	_focus(0)


func _place(node: Node3D, x: float, title: String, height: float, width: float) -> float:
	var cx := x + width * 0.5
	node.position = Vector3(cx, 0.0, 0.0)
	_items.append({"node": node, "name": title, "size": maxf(height, width)})
	# Turntable disc.
	var disc := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = width * 0.45
	dm.bottom_radius = width * 0.47
	dm.height = 0.1
	disc.mesh = dm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.3, 0.32)
	m.roughness = 0.6
	disc.material_override = m
	disc.position = Vector3(cx, -0.05, 0)
	add_child(disc)
	return x + width + 1.5


func _build_world() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.32, 0.36, 0.42)
	psm.sky_horizon_color = Color(0.62, 0.64, 0.66)
	psm.ground_bottom_color = Color(0.2, 0.2, 0.2)
	psm.ground_horizon_color = Color(0.45, 0.45, 0.46)
	sky.sky_material = psm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.43, 0.45)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 60.0
	sun.shadow_normal_bias = 2.0
	sun.rotation = Vector3(deg_to_rad(-40.0), deg_to_rad(35.0), 0.0)
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 60)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.5, 0.5, 0.52)
	fm.roughness = 0.85
	floor_mi.material_override = fm
	floor_mi.position = Vector3(150, -0.1, 0)
	add_child(floor_mi)
	RenderingServer.global_shader_parameter_set("env_sky", Vector3(0.35, 0.38, 0.42))
	RenderingServer.global_shader_parameter_set("env_ground", Vector3(0.2, 0.2, 0.21))
	RenderingServer.global_shader_parameter_set("env_up", Vector3.UP)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	add_child(_cam)
	_cam.current = true


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -110
	bar.offset_bottom = -20
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	layer.add_child(bar)
	for b in [["◀", func() -> void: _focus(_index - 1)], ["▶", func() -> void: _focus(_index + 1)],
			["Люк", _toggle_hatch], ["Назад", _back]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.custom_minimum_size = Vector2(150, 80)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(b[1])
		bar.add_child(btn)
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_label.offset_top = 20
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 34)
	layer.add_child(_label)


func _back() -> void:
	get_tree().change_scene_to_file("res://scenes/flight.tscn")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_back()


func _exit_tree() -> void:
	# Break parent <-> children reference cycles of the body tree (else it leaks).
	var stack: Array = [_root_body]
	while not stack.is_empty():
		var b: CelestialBody = stack.pop_back()
		if b == null:
			continue
		stack.append_array(b.children)
		b.children.clear()
		b.parent = null


func _toggle_hatch() -> void:
	for v in _views:
		var rv = v
		rv.set_hatch_open(not rv.hatch_is_open() and rv._hatch_target < 0.5)


func _focus(i: int) -> void:
	_index = posmod(i, _items.size())
	var it: Dictionary = _items[_index]
	_label.text = "%s  (%d / %d)" % [it.name, _index + 1, _items.size()]
	_dist = float(it.size) * 1.6 + 3.0


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventScreenDrag or (e is InputEventMouseMotion and (e as InputEventMouseMotion).button_mask != 0):
		var rel: Vector2 = e.relative
		_yaw -= rel.x * 0.008
		_pitch = clampf(_pitch + rel.y * 0.005, -0.3, 1.3)


func _process(delta: float) -> void:
	# Turntables spin slowly; the camera orbits the focused item.
	for k in _items.size():
		var n: Node3D = _items[k].node
		n.rotation.y += delta * 0.35
	for v in _views:
		v.update_visual(delta)
	var it: Dictionary = _items[_index]
	var n: Node3D = it.node
	var c := n.position + Vector3(0, float(it.size) * 0.4, 0)
	var off := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _dist
	_cam.global_transform = Transform3D(Basis(), c + off).looking_at(c, Vector3.UP)
