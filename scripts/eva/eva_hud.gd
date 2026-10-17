extends CanvasLayer
## EVA controls. Left: translation joystick + up/down. Right half of the screen:
## swipe = pitch/yaw. Buttons: roll, stabilize, kill velocity, face ship, winch,
## detach/attach, back inside. Bars: jetpack propellant and oxygen.

const JoystickScript := preload("res://scripts/ui/joystick.gd")

var flight: Node3D
var surface := false   ## walking on the ground instead of floating in space

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
	_root.theme = preload("res://scripts/flight/flight_hud.gd").make_theme()
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
	if surface:
		_build_surface()
	else:
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
	title.text = "На поверхности" if surface else "Выход в открытый космос"
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
	top.add_child(_btn("Груз", _toggle_inventory, 110))
	top.add_child(_btn("II", func() -> void: flight.hud.toggle_pause(), 70))


var _inventory: Control


func _toggle_inventory() -> void:
	if _inventory == null:
		_inventory = preload("res://scripts/ui/inventory_panel.gd").new()
		_inventory.flight = flight
		_inventory.hide()
		_root.add_child(_inventory)
	_inventory.visible = not _inventory.visible


func _build_pause_button() -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	top.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_root.add_child(top)
	top.add_child(_btn("Груз", _toggle_inventory, 110))
	top.add_child(_btn("II", func() -> void: flight.hud.toggle_pause(), 70))


func _build_surface() -> void:
	_build_pause_button()
	var box := HBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(box)
	_joy = JoystickScript.new()
	_joy.radius = 120.0
	box.add_child(_joy)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(col)
	var drill := _hold("Бур", func() -> void: flight.drill_held = true,
		func() -> void: flight.drill_held = false, 220)
	drill.custom_minimum_size = Vector2(220, 74)
	col.add_child(drill)
	var jump := _btn("Прыжок", func() -> void: flight.astronaut.jump_requested = true, 220)
	jump.custom_minimum_size = Vector2(220, 80)
	col.add_child(jump)
	col.add_child(_btn("Стройка", _toggle_build, 220))
	_enter_btn = _btn("В корабль", func() -> void: flight.end_eva(), 220)
	col.add_child(_enter_btn)
	var hint := Label.new()
	hint.text = "Свайп по правой половине — камера"
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.7, 0.78, 0.9))
	col.add_child(hint)


# --- Build mode -----------------------------------------------------------------------

var _build_panel: PanelContainer
var _build_list: VBoxContainer
var _build_note: Label
var _build_btns := {}


func _toggle_build() -> void:
	if _build_panel == null:
		_make_build_panel()
	_build_panel.visible = not _build_panel.visible
	if not _build_panel.visible:
		flight.set_build_type("")
	_refresh_build()


func _make_build_panel() -> void:
	_build_panel = _panel()
	_build_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)
	_build_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(_build_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_build_panel.add_child(box)
	var head := Label.new()
	head.text = "Стройка: модуль встанет в 7 м перед тобой, рядом с базой — по её сетке"
	head.add_theme_font_size_override("font_size", 17)
	head.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	box.add_child(head)
	_build_list = VBoxContainer.new()
	box.add_child(_build_list)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	_build_list.add_child(grid)
	for type in Bases.ORDER:
		var b := _btn("", func() -> void:
			flight.set_build_type(type)
			_refresh_build(), 380, false)
		b.add_theme_font_size_override("font_size", 16)
		b.custom_minimum_size = Vector2(380, 56)
		grid.add_child(b)
		_build_btns[type] = b
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	row.add_child(_btn("Повернуть", func() -> void: flight.rotate_build(), 170))
	row.add_child(_btn("Поставить", func() -> void:
		var r: String = flight.place_build()
		flight.message.emit(r)
		_refresh_build(), 190))
	row.add_child(_btn("Закрыть", _toggle_build, 150))
	_build_note = Label.new()
	_build_note.add_theme_font_size_override("font_size", 17)
	box.add_child(_build_note)


func _refresh_build() -> void:
	if _build_panel == null or not _build_panel.visible:
		return
	var invs: Array = flight.build_inventories()
	for type in _build_btns:
		var ok := Bases.affordable(type, invs)
		var b: Button = _build_btns[type]
		b.text = "%s%s\n%s" % ["▶ " if flight.build_type == type else "", Bases.MODULES[type].name, Bases.cost_text(type)]
		b.modulate = Color(1, 1, 1) if ok else Color(0.65, 0.65, 0.7)
	var have := PackedStringArray()
	for id in ["metal", "parts"]:
		var n := 0
		for inv in invs:
			n += (inv as Inventory).count(id)
		have.append("%s %d" % [Items.name_of(id), n])
	var src := "скафандр + корабль" if invs.size() > 1 else "только скафандр (корабль дальше 60 м)"
	var spot: Dictionary = flight._build_spot
	var why := ""
	if flight.build_type != "" and not spot.is_empty() and not spot.ok:
		why = "\n⚠ " + str(spot.why)
	elif flight.build_type != "":
		why = "\n" + str(Bases.MODULES[flight.build_type].desc)
	_build_note.text = "Есть: %s (%s)%s" % [", ".join(have), src, why]


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


func _update_texts_surface(a: Node, delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.1
	_fuel_bar.value = a.propellant / a.PROPELLANT_MAX
	_o2_bar.value = a.oxygen / a.OXYGEN_MAX
	var o2 := int(a.oxygen)
	_o2_label.text = "Дышим воздухом" if a.breathable else "Кислорода на %d:%02d" % [o2 / 60, o2 % 60]
	var dist: float = flight.entry_distance()
	_info.text = "%s · g = %.2f м/с²\nДо ракеты %.1f м · %s\nГрунт: %s" % [flight.vessel.body.name, a.gravity, dist,
		"бурю…" if a.drilling else ("на земле" if a.on_ground else "в прыжке"),
		Resources.describe(flight.resources_here())]
	_enter_btn.disabled = dist > 2.5


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
	if surface:
		a.walk_input = j
		flight.cam_yaw -= _swipe_rel.x * 0.006
		flight.cam_pitch = clampf(flight.cam_pitch + _swipe_rel.y * 0.006, -0.2, 1.2)
		_swipe_rel = Vector2.ZERO
		_update_texts_surface(a, delta)
		if _build_panel != null and _build_panel.visible and _timer >= 0.09:
			_refresh_build()
		return
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
