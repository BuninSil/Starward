extends CanvasLayer
## Touch HUD for the flight scene. Layout: compact telemetry card top-left (tap
## for details), time warp pill top-centre, map / debug / pause top-right,
## throttle bottom-left, orientation mode + roll + joystick bottom-right,
## autopilot + staging bottom-centre with context buttons (chute, EVA) above.
## One theme for every button and panel (also the autopilot / maneuver panels).

const JoystickScript := preload("res://scripts/ui/joystick.gd")
const ThrottleScript := preload("res://scripts/ui/throttle_bar.gd")
const ConsoleScript := preload("res://scripts/ui/debug_console.gd")
const OrbitLine := preload("res://scripts/flight/trajectory_view.gd")
const AutopilotPanel := preload("res://scripts/flight/autopilot_panel.gd")
const ManeuverPanel := preload("res://scripts/flight/maneuver_panel.gd")
const InventoryPanel := preload("res://scripts/ui/inventory_panel.gd")

const ACCENT := Color(1.0, 0.62, 0.22)
const TEXT := Color(0.93, 0.95, 1.0)
const DIM := Color(0.6, 0.67, 0.8)
const CYAN := Color(0.4, 0.88, 1.0)

const HOLD_MODES := [
	["sas", "Стабилизация"], ["prograde", "По ходу"], ["retrograde", "Против хода"],
	["normal", "Нормаль"], ["antinormal", "Антинормаль"],
	["radial_out", "От планеты"], ["radial_in", "К планете"],
]

var flight: Node3D

var _root: Control
var _tele_alt: Label
var _tele_speed: Label
var _tele_line1: Label
var _tele_line2: Label
var _tele_where: Label
var _details: PanelContainer
var _telemetry: Label
var _telemetry_values: Label
var _overlay: Label
var _throttle: ThrottleScript
var _throttle_label: Label
var _warp_btn: Button
var _stage_btn: Button
var _map_btn: Button
var _focus_btn: Button
var _ship_focus_btn: Button
var _prev_body_btn: Button
var _eva_btn: Button
var _node_btn: Button
var _chute_btn: Button
var _ap_panel: PanelContainer
var _mn_panel: PanelContainer
var _ap_btn: Button
var _ap_label: Label
var _heat_label: Label
var _hold_btn: Button
var _hold_menu: PanelContainer
var _hold_buttons := {}
var _joystick: JoystickScript
var _roll := 0.0
var _toast: Label
var _toast_time := 0.0
var _debug_menu: PanelContainer
var _console: PanelContainer
var _destroyed_panel: PanelContainer
var _destroyed_label: Label
var _destroyed_title: Label
var _stage_confirm := 0.0   ## seconds left to confirm staging while landed
var _pause_layer: CanvasLayer
var _inf_fuel_btn: CheckButton
var _timer := 0.0
var _inventory: Control
var _throttle_box: Control
var _stage_col: Control


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = make_theme()
	add_child(_root)
	_build_telemetry()
	_build_top_right()
	_build_warp()
	_build_throttle()
	_build_attitude()
	_build_stage()
	_build_toast()
	_build_debug_menu()
	_build_destroyed()
	_ap_panel = AutopilotPanel.new()
	_ap_panel.flight = flight
	_ap_panel.hide()
	_root.add_child(_ap_panel)
	_mn_panel = ManeuverPanel.new()
	_mn_panel.flight = flight
	_mn_panel.hide()
	_root.add_child(_mn_panel)

	_console = ConsoleScript.new()
	_console.hide()
	_root.add_child(_console)
	_inventory = InventoryPanel.new()
	_inventory.flight = flight
	_inventory.hide()
	_root.add_child(_inventory)
	flight.message.connect(toast)
	Updater.update_available.connect(func(info: Dictionary) -> void:
		toast("Доступно обновление %s — установить можно на титульном экране" % info.tag))


# --- Builders -------------------------------------------------------------------

static func _box(bg: Color, border: Color, bw := 1, radius := 12, mx := 16, my := 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	return sb


## Shared look: dark translucent buttons, orange outline when pressed/toggled.
static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 22
	var normal := _box(Color(0.05, 0.07, 0.12, 0.78), Color(1, 1, 1, 0.12))
	var pressed := _box(Color(0.16, 0.13, 0.1, 0.92), ACCENT, 2)
	var disabled := _box(Color(0.05, 0.07, 0.12, 0.4), Color(1, 1, 1, 0.05))
	for type in ["Button", "CheckButton"]:
		t.set_stylebox("normal", type, normal)
		t.set_stylebox("hover", type, normal)
		t.set_stylebox("pressed", type, pressed)
		t.set_stylebox("hover_pressed", type, pressed)
		t.set_stylebox("disabled", type, disabled)
		t.set_stylebox("focus", type, StyleBoxEmpty.new())
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, TEXT)
		t.set_color("font_pressed_color", type, ACCENT)
		t.set_color("font_hover_pressed_color", type, ACCENT)
		t.set_color("font_disabled_color", type, Color(TEXT, 0.35))
	t.set_stylebox("panel", "PanelContainer", _box(Color(0.03, 0.05, 0.09, 0.8), Color(1, 1, 1, 0.08), 1, 14, 14, 12))
	t.set_color("font_color", "Label", TEXT)
	return t


## Solid coloured style for the key buttons (stage, autopilot).
func _paint(b: Button, c: Color) -> void:
	var n := _box(Color(c.darkened(0.55), 0.92), c, 2, 14)
	var p := _box(Color(c.darkened(0.3), 0.95), c.lightened(0.3), 2, 14)
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", n)
	b.add_theme_stylebox_override("pressed", p)
	b.add_theme_stylebox_override("hover_pressed", p)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(k, TEXT)


func _panel() -> PanelContainer:
	return PanelContainer.new()


func _button(text: String, cb: Callable, min_w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(min_w, 60)
	b.pressed.connect(cb)
	return b


func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_telemetry() -> void:
	var col := VBoxContainer.new()
	col.position = Vector2(16, 16)
	col.add_theme_constant_override("separation", 8)
	_root.add_child(col)
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventScreenTouch and e.pressed) or (e is InputEventMouseButton and e.pressed):
			_details.visible = not _details.visible)
	col.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)
	var heads := HBoxContainer.new()
	heads.add_theme_constant_override("separation", 0)
	heads.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(heads)
	var vals := HBoxContainer.new()
	vals.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(vals)
	for k in 2:
		var h := _label(15, DIM)
		h.text = ["ВЫСОТА", "СКОРОСТЬ"][k]
		h.custom_minimum_size = Vector2(180, 0)
		heads.add_child(h)
		var v := _label(32, TEXT)
		v.custom_minimum_size = Vector2(180, 0)
		vals.add_child(v)
		if k == 0:
			_tele_alt = v
		else:
			_tele_speed = v
	_tele_line1 = _label(18, TEXT)
	box.add_child(_tele_line1)
	_tele_line2 = _label(18, TEXT)
	box.add_child(_tele_line2)
	_tele_where = _label(16, ACCENT)
	box.add_child(_tele_where)

	# Details (tap the card): everything else, two columns.
	_details = PanelContainer.new()
	_details.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_details.hide()
	col.add_child(_details)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_details.add_child(row)
	_telemetry = _label(15, DIM)
	row.add_child(_telemetry)
	_telemetry_values = _label(15, TEXT)
	row.add_child(_telemetry_values)


func _build_top_right() -> void:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_BEGIN
	box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.add_theme_constant_override("separation", 8)
	_root.add_child(box)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	_map_btn = _button("Карта", _on_map, 130)
	row.add_child(_map_btn)
	row.add_child(_button("Груз", func() -> void: _inventory.visible = not _inventory.visible, 100))
	row.add_child(_button("Дебаг", func() -> void: _debug_menu.visible = not _debug_menu.visible, 110))
	row.add_child(_button("II", toggle_pause, 64))
	# Map-only buttons.
	var map_row := HBoxContainer.new()
	map_row.alignment = BoxContainer.ALIGNMENT_END
	map_row.add_theme_constant_override("separation", 8)
	_node_btn = _button("Манёвр", _on_node_button, 140)
	_node_btn.visible = false
	map_row.add_child(_node_btn)
	_ship_focus_btn = _button("К ракете", func() -> void: flight.focus_map_on_ship(), 120)
	_ship_focus_btn.visible = false
	map_row.add_child(_ship_focus_btn)
	_prev_body_btn = _button("◀", func() -> void: flight.cycle_map_focus(-1), 60)
	_prev_body_btn.visible = false
	map_row.add_child(_prev_body_btn)
	_focus_btn = _button("Фокус: тело", func() -> void: flight.cycle_map_focus(1), 190)
	_focus_btn.visible = false
	map_row.add_child(_focus_btn)
	box.add_child(map_row)
	_overlay = _label(15, Color(0.6, 0.95, 0.7, 0.8))
	_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(_overlay)


func _build_warp() -> void:
	# One pill: ◀◀  Время ×N  ▶▶ (tap the middle for ×1).
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 16)
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(row)
	row.add_child(_button("◀◀", func() -> void: flight.set_warp(flight.warp_index - 1), 64))
	_warp_btn = _button("×1", func() -> void: flight.set_warp(0), 150)
	row.add_child(_warp_btn)
	row.add_child(_button("▶▶", func() -> void: flight.set_warp(flight.warp_index + 1), 64))


func _build_throttle() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(box)
	_throttle_box = box
	_throttle_label = _label(22, TEXT)
	_throttle_label.add_theme_constant_override("outline_size", 6)
	_throttle_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	box.add_child(_throttle_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	_throttle = ThrottleScript.new()
	_throttle.changed.connect(func(v: float) -> void:
		flight.disengage_autopilot("ручной газ")
		flight.vessel.throttle = v)
	row.add_child(_throttle)
	_throttle.custom_minimum_size = Vector2(96, 236)
	var quick := VBoxContainer.new()
	quick.alignment = BoxContainer.ALIGNMENT_END
	quick.add_theme_constant_override("separation", 10)
	row.add_child(quick)
	# (set_value emits changed -> also disengages the autopilot)
	quick.add_child(_button("Полный", func() -> void: _throttle.set_value(1.0), 110))
	quick.add_child(_button("Выкл", func() -> void: _throttle.set_value(0.0), 110))


func _build_attitude() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.alignment = BoxContainer.ALIGNMENT_END
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(box)

	# Orientation modes: a popup grid over the mode button.
	_hold_menu = PanelContainer.new()
	_hold_menu.hide()
	box.add_child(_hold_menu)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	_hold_menu.add_child(grid)
	for m in HOLD_MODES:
		var b := Button.new()
		b.text = m[1]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(180, 56)
		b.add_theme_font_size_override("font_size", 20)
		var mode: String = m[0]
		b.pressed.connect(func() -> void:
			flight.disengage_autopilot("ручная ориентация")
			_set_hold(mode)
			_hold_menu.hide())
		grid.add_child(b)
		_hold_buttons[mode] = b

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var side := VBoxContainer.new()
	side.alignment = BoxContainer.ALIGNMENT_END
	side.add_theme_constant_override("separation", 10)
	row.add_child(side)
	_hold_btn = Button.new()
	_hold_btn.focus_mode = Control.FOCUS_NONE
	_hold_btn.custom_minimum_size = Vector2(170, 70)
	_hold_btn.add_theme_font_size_override("font_size", 19)
	_hold_btn.pressed.connect(func() -> void: _hold_menu.visible = not _hold_menu.visible)
	side.add_child(_hold_btn)
	var rolls := HBoxContainer.new()
	rolls.add_theme_constant_override("separation", 8)
	side.add_child(rolls)
	rolls.add_child(_hold_button("◀", -1.0))
	rolls.add_child(_hold_button("▶", 1.0))
	var roll_l := _label(15, DIM)
	roll_l.text = "крен"
	roll_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side.add_child(roll_l)
	_joystick = JoystickScript.new()
	_joystick.radius = 100.0
	_joystick.changed.connect(func(val: Vector2) -> void:
		if val.length() > 0.2:
			flight.disengage_autopilot("джойстик"))
	row.add_child(_joystick)


## Button that applies roll while held.
func _hold_button(text: String, dir: float) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(81, 64)
	b.add_theme_font_size_override("font_size", 26)
	b.button_down.connect(func() -> void:
		flight.disengage_autopilot("крен")
		_roll = dir)
	b.button_up.connect(func() -> void: _roll = 0.0)
	return b


func _build_stage() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.alignment = BoxContainer.ALIGNMENT_END
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 24)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(col)
	_stage_col = col

	# Context actions: appear only when they make sense.
	var ctx := HBoxContainer.new()
	ctx.alignment = BoxContainer.ALIGNMENT_CENTER
	ctx.add_theme_constant_override("separation", 10)
	col.add_child(ctx)
	_chute_btn = _button("Парашют", _on_chute, 190)
	_paint(_chute_btn, Color(0.95, 0.85, 0.3))
	_chute_btn.visible = false
	ctx.add_child(_chute_btn)
	_eva_btn = _button("Выйти наружу", func() -> void: flight.start_eva(), 210)
	_paint(_eva_btn, Color(0.5, 0.95, 0.55))
	_eva_btn.visible = false
	ctx.add_child(_eva_btn)

	var main := HBoxContainer.new()
	main.alignment = BoxContainer.ALIGNMENT_CENTER
	main.add_theme_constant_override("separation", 10)
	col.add_child(main)
	_ap_btn = _button("Автопилот", _on_autopilot, 180)
	_ap_btn.custom_minimum_size.y = 84
	_paint(_ap_btn, CYAN)
	main.add_child(_ap_btn)
	_stage_btn = _button("Сбросить ступень", _on_stage, 260)
	_stage_btn.custom_minimum_size.y = 84
	_stage_btn.add_theme_font_size_override("font_size", 25)
	_paint(_stage_btn, Color(1.0, 0.42, 0.3))
	main.add_child(_stage_btn)


func _build_toast() -> void:
	_ap_label = _label(21, CYAN)
	_ap_label.custom_minimum_size = Vector2(900, 0)
	_ap_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ap_label.add_theme_constant_override("outline_size", 6)
	_ap_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_ap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ap_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 88)
	_ap_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(_ap_label)

	_heat_label = _label(23, Color(1.0, 0.55, 0.25))
	_heat_label.custom_minimum_size = Vector2(900, 0)
	_heat_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_heat_label.add_theme_constant_override("outline_size", 6)
	_heat_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_heat_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_heat_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 172)
	_heat_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(_heat_label)

	_toast = _label(25, Color(1.0, 0.85, 0.45))
	_toast.custom_minimum_size = Vector2(900, 0)
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 124)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(_toast)


func _build_debug_menu() -> void:
	_debug_menu = PanelContainer.new()
	_debug_menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	_debug_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_debug_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	_debug_menu.hide()
	_root.add_child(_debug_menu)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_debug_menu.add_child(box)
	var title := Label.new()
	title.text = "Дебаг-меню"
	title.add_theme_font_size_override("font_size", 30)
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	_inf_fuel_btn = CheckButton.new()
	_inf_fuel_btn.text = "Бесконечное топливо"
	_inf_fuel_btn.focus_mode = Control.FOCUS_NONE
	_inf_fuel_btn.toggled.connect(func(on: bool) -> void: flight.vessel.infinite_fuel = on)
	grid.add_child(_inf_fuel_btn)
	grid.add_child(_button("Сброс на старт", func() -> void:
		_debug_menu.hide()
		flight.reset_to_pad()))
	var design_btn := _button("Ракета: " + Vessel.DESIGNS[Vessel.design], func() -> void: pass)
	design_btn.pressed.connect(func() -> void:
		Vessel.design = "orbit" if Vessel.design == "moon" else "moon"
		design_btn.text = "Ракета: " + Vessel.DESIGNS[Vessel.design]
		_debug_menu.hide()
		flight.reset_to_pad()
		toast("На старте: " + Vessel.DESIGNS[Vessel.design]))
	grid.add_child(design_btn)
	grid.add_child(_button("ЛМ на орбите Луны", func() -> void:
		_debug_menu.hide()
		flight.teleport_lunar_module_to_orbit(30_000.0)))
	grid.add_child(_button("Орбита 20 км", func() -> void:
		_debug_menu.hide()
		flight.teleport_to_orbit(20_000.0)))
	grid.add_child(_button("Орбита 100 км", func() -> void:
		_debug_menu.hide()
		flight.teleport_to_orbit(100_000.0)))
	grid.add_child(_button("Перелёт к Луне", func() -> void:
		_debug_menu.hide()
		flight.teleport_to_moon_transfer()))
	grid.add_child(_button("Орбита Луны 30 км", func() -> void:
		_debug_menu.hide()
		flight.teleport_to_body_orbit(SolarSystem.find(flight.root_body, "Луна"), 30_000.0)))
	grid.add_child(_button("На поверхность Луны", func() -> void:
		_debug_menu.hide()
		var moon := SolarSystem.find(flight.root_body, "Луна")
		flight.teleport_to_surface(moon, 0.0, flight.sunlit_longitude(moon))))
	grid.add_child(_button("Телепорт к телу…", func() -> void:
		_debug_menu.hide()
		_show_teleport_menu()))
	var gfx_btn := _button("Графика: " + Graphics.label(), func() -> void: pass)
	gfx_btn.pressed.connect(func() -> void:
		Graphics.set_quality(Graphics.LOW if Graphics.quality == Graphics.HIGH else Graphics.HIGH)
		gfx_btn.text = "Графика: " + Graphics.label()
		toast("Графика: %s — грунт обновится при следующем подлёте к поверхности" % Graphics.label()))
	grid.add_child(gfx_btn)
	grid.add_child(_button("Время ×1000", func() -> void: flight.set_warp(flight.WARPS.find(1000))))
	grid.add_child(_button("Витрина деталей", func() -> void:
		preload("res://scripts/flight/parts_showcase.gd").return_scene = "res://scenes/flight.tscn"
		get_tree().change_scene_to_file("res://scenes/parts_showcase.tscn")))
	grid.add_child(_button("Профайлер", func() -> void:
		_debug_menu.hide()
		_show_profiler()))
	grid.add_child(_button("Консоль", func() -> void: _console.visible = not _console.visible))
	grid.add_child(_button("Скопировать лог", Log.copy_to_clipboard))
	grid.add_child(_button("Проверить обновление", func() -> void:
		toast("Проверяю обновление…")
		Updater.check_now()))
	grid.add_child(_button("На титульный экран", func() -> void:
		get_tree().change_scene_to_file("res://scenes/boot.tscn")))
	grid.add_child(_button("Закрыть", _debug_menu.hide))
	Updater.check_finished.connect(func(_h: bool, msg: String) -> void:
		if _debug_menu.visible:
			toast(msg))


var _teleport_menu: PanelContainer = null


# --- Profiler (debug): switch features off on the phone and watch FPS / GPU ms ---

var _prof_panel: PanelContainer = null
var _prof_timer := 0.0
var _prof_hid_rocket := false
var _prof_stats: Label
const PROF_FEATURES := [["shadows", "Тени"], ["ground", "Детальный грунт"], ["globe", "Шар планеты"],
	["g_detail", "Грунт: детали вблизи (всё)"], ["g_near", "  · ближняя текстура"],
	["g_mid", "  · средние нормали"], ["g_craters", "  · мелкие кратеры"], ["g_micro", "  · микротени"],
	["g_light", "Грунт: свет реголита"], ["g_fp32", "Грунт: полная точность (вкл = медленнее)"], ["g_hd", "Грунт: HD-снимки (Земля)"],
	["rocks", "Камни и галька"], ["fx", "Дым и пыль"], ["glow", "Свечение (glow)"],
	["rocket", "Ракета и космонавт"], ["lights", "Ночные фонари"], ["sky", "Небо"]]
const PROF_SCALES := [1.0, 0.75, 0.6, 0.5]


func _show_profiler() -> void:
	if _prof_panel == null:
		# Own layer: stays on top of the flight and EVA panels.
		var layer := CanvasLayer.new()
		layer.layer = 100
		add_child(layer)
		_prof_panel = PanelContainer.new()
		_prof_panel.theme = make_theme()
		_prof_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
		_prof_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		layer.add_child(_prof_panel)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 6)
		_prof_panel.add_child(box)
		var top := HBoxContainer.new()
		top.add_theme_constant_override("separation", 8)
		box.add_child(top)
		_prof_stats = Label.new()
		_prof_stats.add_theme_font_size_override("font_size", 24)
		_prof_stats.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		_prof_stats.custom_minimum_size = Vector2(330, 0)
		top.add_child(_prof_stats)
		var list := ScrollContainer.new()
		list.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		list.custom_minimum_size = Vector2(0, get_viewport().get_visible_rect().size.y * 0.45)
		var items := VBoxContainer.new()
		items.add_theme_constant_override("separation", 2)
		list.add_child(items)
		var fold := _button("Свернуть", func() -> void: pass)
		fold.custom_minimum_size = Vector2(150, 52)
		fold.pressed.connect(func() -> void:
			list.visible = not list.visible
			fold.text = "Свернуть" if list.visible else "Галочки")
		top.add_child(fold)
		var close := _button("✕", func() -> void:
			_prof_panel.hide()
			RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false))
		close.custom_minimum_size = Vector2(60, 52)
		top.add_child(close)
		box.add_child(list)
		var t := Label.new()
		t.text = "Выключить:"
		t.add_theme_font_size_override("font_size", 18)
		items.add_child(t)
		for fe in PROF_FEATURES:
			var key: String = fe[0]
			var cb := CheckButton.new()
			cb.text = fe[1]
			cb.focus_mode = Control.FOCUS_NONE
			cb.add_theme_font_size_override("font_size", 19)
			cb.toggled.connect(func(on: bool) -> void:
				if on:
					flight.prof_off[key] = true
				else:
					flight.prof_off.erase(key)
				_prof_timer = 0.0)
			items.add_child(cb)
		var sc := _button("Разрешение", func() -> void: pass)
		sc.pressed.connect(func() -> void:
			var vp := get_viewport()
			var i := (PROF_SCALES.find(snappedf(vp.scaling_3d_scale, 0.05)) + 1) % PROF_SCALES.size()
			vp.scaling_3d_scale = PROF_SCALES[i]
			sc.text = "Разрешение %d%%" % int(PROF_SCALES[i] * 100.0))
		sc.text = "Разрешение %d%%" % int(get_viewport().scaling_3d_scale * 100.0)
		items.add_child(sc)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_prof_panel.show()


## Profiler: a shader parameter forced to `value` while `on`, restored after.
func _prof_param(m: ShaderMaterial, name: String, value: Variant, on: bool) -> void:
	var key := "prof_" + name
	if on:
		if not m.has_meta(key):
			m.set_meta(key, m.get_shader_parameter(name))
		m.set_shader_parameter(name, value)
	elif m.has_meta(key):
		m.set_shader_parameter(name, m.get_meta(key))
		m.remove_meta(key)


## Re-applied a few times a second: the flight scene rebuilds / re-shows things.
func _prof_apply() -> void:
	_prof_timer -= get_process_delta_time()
	if _prof_timer > 0.0:
		return
	_prof_timer = 0.3
	var off: Dictionary = flight.prof_off
	flight.fx.visible = not off.has("fx")
	flight.env.glow_enabled = not off.has("glow")
	flight.sky_quad.visible = not off.has("sky")
	if off.has("rocket") or _prof_hid_rocket:
		# Hide; on the way back restore only what we hid ourselves.
		var h := off.has("rocket")
		if h or not flight.map_mode:
			flight.rocket.visible = not h
		if flight.astronaut != null and is_instance_valid(flight.astronaut):
			flight.astronaut.visible = not h
		_prof_hid_rocket = h
	for l in flight.find_children("*", "Light3D", true, false):
		if not (l is DirectionalLight3D):
			if not l.has_meta("mask"):
				l.set_meta("mask", (l as Light3D).light_cull_mask)
			(l as Light3D).light_cull_mask = 0 if off.has("lights") else int(l.get_meta("mask"))
	for b in flight.planets:
		var pv: Node = flight.planets[b]
		var pm = pv.get("_patch_material")
		if pm is ShaderMaterial:
			_prof_param(pm, "detail_level", 0, off.has("g_detail"))
			_prof_param(pm, "crater_decals", 0.0, off.has("g_craters"))
			_prof_param(pm, "near_layer", false, off.has("g_near"))
			_prof_param(pm, "mid_normals", false, off.has("g_mid"))
			_prof_param(pm, "micro_shadows", false, off.has("g_micro"))
			_prof_param(pm, "regolith", 0.0, off.has("g_light"))
			_prof_param(pm, "hd_rect", Vector4.ZERO, off.has("g_hd"))
			var want: Shader = pv.call("surface_shader_fp32") if off.has("g_fp32") else pv.get("SURFACE_SHADER")
			if (pm as ShaderMaterial).shader != want:
				(pm as ShaderMaterial).shader = want
		pv.get("_surface").visible = not off.has("globe")
		var site: Node = pv.get("_site")
		if site == null:
			continue
		for g in site.find_children("*", "GeometryInstance3D", true, false):
			var m: Material = (g as GeometryInstance3D).material_override
			if m == null:
				continue
			if m == pv.get("_patch_material"):
				g.visible = not off.has("ground")
			elif m is ShaderMaterial and (m as ShaderMaterial).shader == preload("res://shaders/rock.gdshader"):
				g.visible = not off.has("rocks")


## Debug: every body with "orbit" and (if solid) "surface" buttons.
func _show_teleport_menu() -> void:
	if _teleport_menu == null:
		_teleport_menu = PanelContainer.new()
		_teleport_menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
		_teleport_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_teleport_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
		_root.add_child(_teleport_menu)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)
		_teleport_menu.add_child(box)
		var head := HBoxContainer.new()
		box.add_child(head)
		var title := Label.new()
		title.text = "Телепорт"
		title.add_theme_font_size_override("font_size", 28)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(title)
		head.add_child(_button("Закрыть", _teleport_menu.hide))
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size = Vector2(620, 420)
		box.add_child(scroll)
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 8)
		scroll.add_child(grid)
		for b in flight.bodies:
			var bd: CelestialBody = b
			var l := Label.new()
			l.text = bd.name
			l.custom_minimum_size = Vector2(200, 0)
			l.add_theme_font_size_override("font_size", 22)
			grid.add_child(l)
			grid.add_child(_button("Орбита", func() -> void:
				_teleport_menu.hide()
				flight.teleport_to_body_orbit(bd, flight.default_orbit_altitude(bd))))
			if flight.has_solid_surface(bd):
				grid.add_child(_button("Поверхность", func() -> void:
					_teleport_menu.hide()
					flight.teleport_to_surface(bd, 0.0, flight.sunlit_longitude(bd))))
			else:
				grid.add_child(Control.new())
	_teleport_menu.show()


func _build_destroyed() -> void:
	_destroyed_panel = PanelContainer.new()
	_destroyed_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	_destroyed_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_destroyed_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_destroyed_panel.hide()
	_root.add_child(_destroyed_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_destroyed_panel.add_child(box)
	var t := Label.new()
	_destroyed_title = t
	t.text = "Капсула потеряна"
	t.add_theme_font_size_override("font_size", 36)
	t.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	box.add_child(t)
	_destroyed_label = Label.new()
	_destroyed_label.custom_minimum_size = Vector2(640, 0)
	_destroyed_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_destroyed_label)
	box.add_child(_button("Заново на старт", func() -> void:
		_destroyed_panel.hide()
		flight.reset_to_pad()))


# --- Behaviour --------------------------------------------------------------------

func on_vessel_reset() -> void:
	if _throttle == null:
		return
	_throttle.set_value_no_signal(0.0)
	flight.vessel.throttle = 0.0
	_inf_fuel_btn.set_pressed_no_signal(flight.vessel.infinite_fuel)
	_destroyed_panel.hide()
	flight.rocket.visible = not flight.map_mode
	_set_hold("sas")


func show_destroyed(reason: String, title := "Капсула потеряна") -> void:
	_destroyed_title.text = title
	_destroyed_label.text = reason
	_destroyed_panel.show()
	_throttle.set_value_no_signal(0.0)


func toast(text: String) -> void:
	_toast.text = text
	_toast_time = 3.5
	_toast.modulate.a = 1.0


func _set_hold(mode: String) -> void:
	var v: Vessel = flight.vessel
	if mode == "sas":
		v.sas = true
		v.hold_mode = ""
	else:
		v.sas = true
		v.hold_mode = "" if v.hold_mode == mode else mode
	var cur: String = v.hold_mode if v.hold_mode != "" else "sas"
	for k in _hold_buttons:
		var b: Button = _hold_buttons[k]
		b.set_pressed_no_signal(k == cur)
	for m in HOLD_MODES:
		if m[0] == cur:
			_hold_btn.text = "Ориентация\n%s ▴" % m[1]


func _on_stage() -> void:
	if flight.vessel.landed and _stage_confirm <= 0.0 and flight.vessel.stages.size() > 1:
		_stage_confirm = 2.5
		toast("Ракета на земле. Нажми ещё раз, чтобы сбросить ступень")
		return
	_stage_confirm = 0.0
	if not flight.vessel.stage():
		toast("Больше нет ступеней")


func _on_autopilot() -> void:
	if flight.autopilot.active():
		flight.disengage_autopilot("кнопка")
	else:
		_ap_panel.visible = not _ap_panel.visible


func _on_node_button() -> void:
	if flight.maneuver == null:
		flight.create_maneuver()
	_mn_panel.visible = flight.maneuver != null
	on_maneuver_changed()


func on_maneuver_changed() -> void:
	if flight.maneuver == null:
		_mn_panel.hide()
		return
	_mn_panel.refresh(flight.maneuver_info)


func _on_chute() -> void:
	var v: Vessel = flight.vessel
	var err: String = v.deploy_chute()
	if err != "":
		toast(err)
		return
	var vt := v.chute_touchdown_speed(flight.sim_time)
	var safe := Vessel.crash_tolerance(v.stages[v.stages.size() - 1])
	if vt > safe:
		toast("Парашют раскрыт, но ракета тяжёлая: сядет на %d м/с, нижняя ступень выдерживает %d. Сбрось ступени" % [int(vt), int(safe)])
	else:
		toast("Парашют раскрыт, касание ~%d м/с" % int(vt))


func on_autopilot_finished() -> void:
	_set_hold("sas")


func _on_map() -> void:
	flight.toggle_map()
	_map_btn.text = "Полёт" if flight.map_mode else "Карта"
	_focus_btn.visible = flight.map_mode
	_ship_focus_btn.visible = flight.map_mode
	_prev_body_btn.visible = flight.map_mode
	_node_btn.visible = flight.map_mode
	if not flight.map_mode:
		_mn_panel.hide()


func _process(delta: float) -> void:
	if flight.map_mode and _focus_btn:
		_focus_btn.text = ("%s ▶" % flight.vessel.body.name) if flight.map_focus_ship else ("%s ▶" % flight.map_focus.name)
	var v: Vessel = flight.vessel
	# Joystick: right = nose to local +X (east on the pad), up = nose to local -Z.
	var j: Vector2 = _joystick.value
	v.input_pitch = -j.y
	v.input_yaw = j.x
	v.input_roll = _roll
	if absf(v.throttle - _throttle.value) > 0.001:
		_throttle.set_value_no_signal(v.throttle)
	_throttle_label.text = "Газ %d%%" % int(round(v.throttle * 100.0))
	var ap: Autopilot = flight.autopilot
	_ap_label.text = "Автопилот · " + ap.status() if ap.active() else ""
	if not ap.active() and v.chute_deployed and not v.landed and not v.destroyed_flag:
		var vt := v.chute_touchdown_speed(flight.sim_time)
		var safe_b := Vessel.crash_tolerance(v.stages[v.stages.size() - 1])
		if vt > safe_b:
			_ap_label.text = "Парашют не держит: касание ~%d м/с > %d, нижняя ступень разобьётся. Сбрось ступени или притормози двигателем" % [int(vt), int(safe_b)]
	_ap_btn.text = "Стоп\nавтопилот" if ap.active() else "Автопилот"
	# Re-entry heating: shown once it matters, with what to do about it.
	var hf := v.heat_fraction()
	if hf > 0.25 and not v.landed and not v.destroyed_flag:
		var tip := ""
		if v.heat_lead == "nose" or v.heat_lead == "side":
			tip = " · разверни дном вперёд («Против хода»)!"
		elif v.heat_lead == "bottom":
			tip = " · без теплозащиты: ступень может сгореть"
		else:
			tip = " · теплозащитный экран"
		_heat_label.text = "Нагрев %d%%%s" % [int(hf * 100.0), tip]
		_heat_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3).lerp(Color(1.0, 0.25, 0.15), clampf((hf - 0.5) * 2.0, 0.0, 1.0)))
	else:
		_heat_label.text = ""
	_eva_btn.visible = flight.can_eva() == "" and not flight.map_mode
	_chute_btn.visible = v.has_chute() and not v.chute_deployed and not v.landed \
		and v.body.has_atmosphere() and v.altitude() < v.body.atmosphere_height

	# The maneuver editor takes the lower left of the map: hide what it covers.
	_throttle_box.visible = not _mn_panel.visible
	_stage_col.visible = not _mn_panel.visible
	_stage_confirm = maxf(_stage_confirm - delta, 0.0)
	if _toast_time > 0.0:
		_toast_time -= delta
		_toast.modulate.a = clampf(_toast_time, 0.0, 1.0)

	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.1
	_update_texts()


func _update_texts() -> void:
	var v: Vessel = flight.vessel
	var b: CelestialBody = flight.body
	var el := OrbitMath.elements(v.pos, v.vel, b.mu)
	var alt := v.altitude()
	var vs := v.vel.dot(v.pos.normalized())
	var stage := v.active_stage()
	var fuel_pct := 0.0
	if not stage.is_empty() and stage.fuel_max > 0.0:
		fuel_pct = stage.fuel / stage.fuel_max * 100.0
	var dvs := v.stage_delta_v()
	var state := b.name
	var low := alt < b.atmosphere_height * 0.5 or v.landed
	_tele_alt.text = OrbitLine.fmt_dist(alt)
	# Near the ground the speed over it matters, in space the orbital one.
	_tele_speed.text = "%d м/с" % int(v.surface_velocity().length() if low else v.vel.length())
	_tele_line1.text = "Верт. %+d м/с   Ап %s   Пе %s" % [int(vs),
		"—" if v.landed else OrbitLine.fmt_dist(el.apoapsis - b.radius),
		"—" if v.landed else OrbitLine.fmt_dist(el.periapsis - b.radius)]
	_tele_line2.text = "Δv %d м/с   Т/В %.2f   топливо %d%%" % [int(v.total_delta_v()), v.twr(), int(fuel_pct)]
	_tele_where.text = "%s · %s   ▾" % [b.name, "на поверхности" if v.landed else ("в атмосфере" if b.has_atmosphere() and alt < b.atmosphere_height else "в космосе")]
	var fixed := b.inertial_to_fixed(v.pos, flight.sim_time)
	var ll := CelestialBody.lat_lon(fixed)
	_telemetry.text = "\n".join(PackedStringArray([
		"Над рельефом", "Орбитальная скор.", "Путевая скор.", "Запас Δv ступени", "Ступеней",
		"Сфера влияния", "Координаты", "Время полёта",
	]))
	_telemetry_values.text = "\n".join(PackedStringArray([
		_agl_text(v, b),
		"%d м/с" % int(v.vel.length()),
		"%d м/с" % int(v.surface_velocity().length()),
		"%d м/с" % int(dvs[dvs.size() - 1] if dvs.size() > 0 else 0.0),
		"%d" % v.stages.size(),
		state,
		"%.4f°, %.4f°" % [ll.x, ll.y],
		_fmt_time(flight.sim_time),
	]))
	_warp_btn.text = "Время ×%d" % flight.warp()
	_warp_btn.add_theme_color_override("font_color", ACCENT if flight.warp() > 1 else TEXT)
	_stage_btn.disabled = v.stages.size() <= 1

	_overlay.text = "FPS %d · v%s (%d)" % [
		Engine.get_frames_per_second(),
		ProjectSettings.get_setting("application/config/version"),
		int(ProjectSettings.get_setting("starward/build/version_code")),
	]
	if _prof_panel != null and _prof_panel.visible:
		var vp := get_viewport().get_viewport_rid()
		_prof_stats.text = "FPS %d · экран %d Гц\nCPU %.1f мс · GPU %.1f мс\ndraw %d · %dk треуг." % [
			Engine.get_frames_per_second(), int(round(maxf(Graphics.current_hz(), 0.0))),
			RenderingServer.viewport_get_measured_render_time_cpu(vp) + Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			RenderingServer.viewport_get_measured_render_time_gpu(vp),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0)]
		_prof_apply()


func _agl_text(v: Vessel, b: CelestialBody) -> String:
	if v.landed:
		return "0 м"
	if not flight.has_solid_surface(b) or v.altitude() > 100_000.0:
		return "—"
	return OrbitLine.fmt_dist(maxf(v.altitude_above_ground(flight.sim_time) - v.height_offset, 0.0))


# --- Pause menu (Android "back") -------------------------------------------------

func toggle_pause() -> void:
	if _pause_layer == null:
		_build_pause()
	var on := not _pause_layer.visible
	_close_slots()
	_pause_layer.visible = on
	get_tree().paused = on


func _build_pause() -> void:
	# Own layer above everything, works while the tree is paused and while the
	# flight HUD itself is hidden (EVA).
	_pause_layer = CanvasLayer.new()
	_pause_layer.layer = 20
	_pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_layer.visible = false
	get_parent().add_child(_pause_layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pause_layer.add_child(dim)
	var p := _panel()
	_pause_panel = p
	p.theme = make_theme()
	p.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	_pause_layer.add_child(p)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	p.add_child(box)
	var t := Label.new()
	t.text = "Пауза"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 34)
	box.add_child(t)
	box.add_child(_button("Продолжить", toggle_pause, 360))
	if Game.has_game():
		box.add_child(_button("Сохранить", func() -> void: _show_slots(true), 360))
		box.add_child(_button("Загрузить", func() -> void: _show_slots(false), 360))
	box.add_child(_button("Заново на старт", func() -> void:
		toggle_pause()
		flight.reset_to_pad(), 360))
	box.add_child(_button("На титульный экран", func() -> void:
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scenes/boot.tscn"), 360))
	box.add_child(_button("Выйти из игры", func() -> void: get_tree().quit(), 360))


var _slots_panel: PanelContainer
var _pause_panel: PanelContainer


func _close_slots() -> void:
	if _slots_panel:
		_slots_panel.queue_free()
		_slots_panel = null
	if _pause_panel:
		_pause_panel.show()


## Save / load slot list over the pause menu.
func _show_slots(saving: bool) -> void:
	if _slots_panel:
		_slots_panel.queue_free()
	_pause_panel.hide()
	_slots_panel = _panel()
	_slots_panel.theme = make_theme()
	_slots_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	_slots_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_slots_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_pause_layer.add_child(_slots_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_slots_panel.add_child(box)
	var t := _label(30, TEXT)
	t.text = "Сохранить в слот" if saving else "Загрузить"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	var list: Array = Game.SLOTS.duplicate() if saving else [Game.AUTOSAVE] + Game.SLOTS
	for slot in list:
		var info := Game.slot_info(slot)
		var title: String = "Автосохранение" if slot == Game.AUTOSAVE else "Слот " + str(slot).right(1)
		var text := "%s — пусто" % title
		if not info.is_empty():
			text = "%s · %s\n%s · %s" % [title, Game.fmt_date(info.time), Game.mode_title(info.mode), info.where]
		var s_id: String = slot
		var b := _button(text, func() -> void:
			if saving:
				var ok := Game.save_to(s_id, flight)
				_close_slots()
				toast("Сохранено: %s" % title if ok else "Не удалось сохранить")
			else:
				Game.load_from(s_id), 480)
		b.custom_minimum_size.y = 74
		b.add_theme_font_size_override("font_size", 20)
		b.disabled = not saving and info.is_empty()
		box.add_child(b)
	box.add_child(_button("Назад", _close_slots, 480))


static func _fmt_time(t: float) -> String:
	var s := int(t)
	var d := s / 86400
	return ("%dд " % d if d > 0 else "") + "%02d:%02d:%02d" % [(s / 3600) % 24, (s / 60) % 60, s % 60]
