extends CanvasLayer
## EVA controls. Left: translation joystick + up/down. Right half of the screen:
## swipe = pitch/yaw. Buttons: roll, stabilize, kill velocity, face ship, winch,
## detach/attach, back inside. Bars: jetpack propellant and oxygen.

const JoystickScript := preload("res://scripts/ui/joystick.gd")

var flight: Node3D

var _root: Control
var _joy: JoystickScript
var _swipe: Control
var _up := 0.0
var _roll := 0.0
var _swipe_rel := Vector2.ZERO
var _swipe_touch := -1
var _fuel_bar: ProgressBar
var _o2_bar: ProgressBar
var _o2_label: Label
var _info: Label
var _stab_btn: Button
var _kill_btn: Button
var _face_btn: Button
var _detach_btn: Button
var _enter_btn: Button
var _winch_btn: Button
var _timer := 0.0


func _ready() -> void:
	layer = 2
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Swipe area: right half, behind the buttons.
	_swipe = Control.new()
	_swipe.anchor_left = 0.5
	_swipe.anchor_right = 1.0
	_swipe.anchor_bottom = 1.0
	_swipe.mouse_filter = Control.MOUSE_FILTER_STOP
	_swipe.gui_input.connect(_on_swipe)
	_root.add_child(_swipe)

	_build_bars()
	_build_left()
	_build_right()


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.04, 0.09, 0.65)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _btn(text: String, cb: Callable, w := 150.0, toggle := false) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(w, 60)
	b.add_theme_font_size_override("font_size", 20)
	if toggle:
		b.toggled.connect(func(_on: bool) -> void: cb.call())
	else:
		b.pressed.connect(cb)
	return b


func _hold(text: String, on_down: Callable, on_up: Callable, w := 150.0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(w, 60)
	b.add_theme_font_size_override("font_size", 20)
	b.button_down.connect(on_down)
	b.button_up.connect(on_up)
	return b


func _build_bars() -> void:
	var p := _panel()
	p.position = Vector2(16, 16)
	_root.add_child(p)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	p.add_child(box)
	var title := Label.new()
	title.text = "Выход в открытый космос"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	_fuel_bar = _bar(box, "Топливо ранца", Color(0.4, 0.8, 1.0))
	_o2_bar = _bar(box, "Кислород", Color(0.5, 1.0, 0.6))
	_o2_label = Label.new()
	_o2_label.add_theme_font_size_override("font_size", 18)
	box.add_child(_o2_label)
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 18)
	box.add_child(_info)


func _bar(parent: Control, label: String, col: Color) -> ProgressBar:
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 17)
	parent.add_child(l)
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(300, 22)
	b.max_value = 1.0
	b.step = 0.001
	b.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = col
	fill.set_corner_radius_all(6)
	b.add_theme_stylebox_override("fill", fill)
	parent.add_child(b)
	return b


func _build_left() -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(box)
	_joy = JoystickScript.new()
	_joy.radius = 110.0
	box.add_child(_joy)
	var ud := VBoxContainer.new()
	ud.alignment = BoxContainer.ALIGNMENT_CENTER
	ud.add_theme_constant_override("separation", 12)
	box.add_child(ud)
	ud.add_child(_hold("Вверх", func() -> void: _up = 1.0, func() -> void: _up = 0.0, 130))
	ud.add_child(_hold("Вниз", func() -> void: _up = -1.0, func() -> void: _up = 0.0, 130))


func _build_right() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(col)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)
	_stab_btn = _btn("Стабилизация", _sync_toggles, 200, true)
	grid.add_child(_stab_btn)
	_kill_btn = _btn("Гасить скорость", _sync_toggles, 200, true)
	grid.add_child(_kill_btn)
	_face_btn = _btn("К кораблю", _sync_toggles, 200, true)
	grid.add_child(_face_btn)
	_winch_btn = _hold("Лебёдка", func() -> void: flight.tether.winching = true,
		func() -> void: flight.tether.winching = false, 200)
	grid.add_child(_winch_btn)
	grid.add_child(_hold("Крен ⟲", func() -> void: _roll = -1.0, func() -> void: _roll = 0.0, 200))
	grid.add_child(_hold("Крен ⟳", func() -> void: _roll = 1.0, func() -> void: _roll = 0.0, 200))
	_detach_btn = _btn("Отстегнуть трос", _on_detach, 200)
	grid.add_child(_detach_btn)
	_enter_btn = _btn("В корабль", func() -> void: flight.end_eva(), 200)
	grid.add_child(_enter_btn)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	top.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_root.add_child(top)
	top.add_child(_btn("Дебаг: к люку", func() -> void: flight.debug_eva_to_hatch(), 210))
	top.add_child(_btn("Дебаг: тяга корабля 2 с", func() -> void: flight.debug_ship_kick(), 300))


func _sync_toggles() -> void:
	var a: Node = flight.astronaut
	if a == null:
		return
	a.stabilize = _stab_btn.button_pressed
	a.kill_rel_velocity = _kill_btn.button_pressed
	a.face_target = _face_btn.button_pressed


func _on_detach() -> void:
	var t: Node = flight.tether
	if t.attached:
		t.detach()
		flight.message.emit("Трос отстёгнут")
	elif flight.astronaut_hatch_distance() < 3.5:
		t.attach(flight.astronaut_hatch_distance())
		flight.message.emit("Трос пристёгнут")
	else:
		flight.message.emit("Пристегнуться можно только у люка (ближе 3.5 м)")


func _on_swipe(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_swipe_touch = event.index if event.pressed else -1
	elif event is InputEventScreenDrag and event.index == _swipe_touch:
		_swipe_rel += event.relative


func _process(delta: float) -> void:
	var a: Node = flight.astronaut
	if a == null:
		return
	var j: Vector2 = _joy.value
	a.move_input = Vector3(j.x, _up, -j.y)
	# Swipe speed -> rotation command (pitch about X, yaw about Y), decays when idle.
	var rot := Vector3(-_swipe_rel.y, -_swipe_rel.x, 0.0) * 0.04
	a.rot_input = Vector3(clampf(rot.x, -1, 1), clampf(rot.y, -1, 1), -_roll)
	_swipe_rel = Vector2.ZERO
	if a.kill_rel_velocity and a.linear_velocity.length() < 0.02:
		_kill_btn.set_pressed_no_signal(false)
		a.kill_rel_velocity = false

	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.1
	_fuel_bar.value = a.propellant / a.PROPELLANT_MAX
	_o2_bar.value = a.oxygen / a.OXYGEN_MAX
	var o2 := int(a.oxygen)
	_o2_label.text = "Кислорода на %d:%02d" % [o2 / 60, o2 % 60]
	var t: Node = flight.tether
	var tether_txt := "отстёгнут"
	if t.broken:
		tether_txt = "ОБОРВАН"
	elif t.attached:
		tether_txt = "%.1f м, натяжение %d Н" % [t.length, int(t.tension)]
	var dist: float = flight.astronaut_hatch_distance()
	_info.text = "До люка %.1f м · скорость %.2f м/с\nТрос: %s" % [dist, a.linear_velocity.length(), tether_txt]
	_enter_btn.disabled = dist > 2.5
	_detach_btn.text = "Отстегнуть трос" if t.attached else "Пристегнуть трос"
