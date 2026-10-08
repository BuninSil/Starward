extends CanvasLayer
## Touch HUD for the flight scene: throttle, attitude joystick, staging, SAS modes,
## time warp, map toggle, telemetry, debug overlay and debug menu.

const JoystickScript := preload("res://scripts/ui/joystick.gd")
const ThrottleScript := preload("res://scripts/ui/throttle_bar.gd")
const ConsoleScript := preload("res://scripts/ui/debug_console.gd")
const OrbitLine := preload("res://scripts/flight/trajectory_view.gd")
const AutopilotPanel := preload("res://scripts/flight/autopilot_panel.gd")
const ManeuverPanel := preload("res://scripts/flight/maneuver_panel.gd")

const HOLD_MODES := [
	["sas", "Стабилизация"], ["prograde", "По ходу"], ["retrograde", "Против хода"],
	["normal", "Нормаль"], ["antinormal", "Антинормаль"],
	["radial_out", "От планеты"], ["radial_in", "К планете"],
]

var flight: Node3D

var _root: Control
var _telemetry: Label
var _telemetry_values: Label
var _overlay: Label
var _throttle: ThrottleScript
var _throttle_label: Label
var _warp_label: Label
var _stage_btn: Button
var _map_btn: Button
var _focus_btn: Button
var _node_btn: Button
var _chute_btn: Button
var _ap_panel: PanelContainer
var _mn_panel: PanelContainer
var _ap_btn: Button
var _ap_label: Label
var _hold_buttons := {}
var _joystick: JoystickScript
var _roll := 0.0
var _toast: Label
var _toast_time := 0.0
var _debug_menu: PanelContainer
var _console: PanelContainer
var _destroyed_panel: PanelContainer
var _destroyed_label: Label
var _inf_fuel_btn: CheckButton
var _timer := 0.0


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	flight.message.connect(toast)


# --- Builders -------------------------------------------------------------------

func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.04, 0.09, 0.6)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _button(text: String, cb: Callable, min_w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(min_w, 64)
	b.pressed.connect(cb)
	return b


func _small_button(text: String, cb: Callable) -> Button:
	var b := _button(text, cb)
	b.add_theme_font_size_override("font_size", 21)
	b.custom_minimum_size = Vector2(0, 58)
	return b


func _build_telemetry() -> void:
	var p := _panel()
	p.position = Vector2(16, 16)
	_root.add_child(p)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	p.add_child(row)
	_telemetry = Label.new()
	_telemetry.add_theme_font_size_override("font_size", 18)
	_telemetry.add_theme_color_override("font_color", Color(0.55, 0.68, 0.88))
	row.add_child(_telemetry)
	_telemetry_values = Label.new()
	_telemetry_values.add_theme_font_size_override("font_size", 18)
	_telemetry_values.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
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
	# Map-only buttons live in their own row under the overlay.
	var map_row := HBoxContainer.new()
	map_row.alignment = BoxContainer.ALIGNMENT_END
	map_row.add_theme_constant_override("separation", 8)
	_node_btn = _button("Манёвр", _on_node_button, 140)
	_node_btn.visible = false
	map_row.add_child(_node_btn)
	_focus_btn = _button("Фокус: тело", func() -> void: flight.cycle_map_focus(), 160)
	_focus_btn.visible = false
	map_row.add_child(_focus_btn)
	_map_btn = _button("Карта", _on_map, 120)
	row.add_child(_map_btn)
	row.add_child(_button("Дебаг", func() -> void: _debug_menu.visible = not _debug_menu.visible, 110))
	var op := _panel()
	op.mouse_filter = Control.MOUSE_FILTER_IGNORE
	op.size_flags_horizontal = Control.SIZE_SHRINK_END
	box.add_child(op)
	_overlay = Label.new()
	_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_overlay.add_theme_font_size_override("font_size", 16)
	_overlay.add_theme_color_override("font_color", Color(0.6, 0.95, 0.7))
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	op.add_child(_overlay)
	box.add_child(map_row)


func _build_warp() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 16)
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(row)
	row.add_child(_small_button("Медленнее", func() -> void: flight.set_warp(flight.warp_index - 1)))
	var p := _panel()
	_warp_label = Label.new()
	_warp_label.custom_minimum_size = Vector2(150, 0)
	_warp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warp_label.add_theme_font_size_override("font_size", 22)
	p.add_child(_warp_label)
	row.add_child(p)
	row.add_child(_small_button("Быстрее", func() -> void: flight.set_warp(flight.warp_index + 1)))
	row.add_child(_small_button("×1", func() -> void: flight.set_warp(0)))


func _build_throttle() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(box)
	_throttle_label = Label.new()
	_throttle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_throttle_label.add_theme_font_size_override("font_size", 24)
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
	var quick := VBoxContainer.new()
	quick.alignment = BoxContainer.ALIGNMENT_CENTER
	quick.add_theme_constant_override("separation", 10)
	row.add_child(quick)
	quick.add_child(_button("Полный", func() -> void: _throttle.set_value(1.0), 120))
	# (set_value emits changed -> also disengages the autopilot)
	quick.add_child(_button("Выкл", func() -> void: _throttle.set_value(0.0), 120))


func _build_attitude() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(box)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	for m in HOLD_MODES:
		var b := Button.new()
		b.text = m[1]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(160, 54)
		b.add_theme_font_size_override("font_size", 19)
		var mode: String = m[0]
		b.pressed.connect(func() -> void:
			flight.disengage_autopilot("ручная ориентация")
			_set_hold(mode))
		grid.add_child(b)
		_hold_buttons[mode] = b

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var roll_box := VBoxContainer.new()
	roll_box.alignment = BoxContainer.ALIGNMENT_CENTER
	roll_box.add_theme_constant_override("separation", 10)
	row.add_child(roll_box)
	roll_box.add_child(_hold_button("Крен влево", -1.0))
	roll_box.add_child(_hold_button("Крен вправо", 1.0))
	_joystick = JoystickScript.new()
	_joystick.radius = 105.0
	_joystick.changed.connect(func(val: Vector2) -> void:
		if val.length() > 0.2:
			flight.disengage_autopilot("джойстик"))
	row.add_child(_joystick)


## Button that applies roll while held.
func _hold_button(text: String, dir: float) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(150, 64)
	b.add_theme_font_size_override("font_size", 20)
	b.button_down.connect(func() -> void:
		flight.disengage_autopilot("крен")
		_roll = dir)
	b.button_up.connect(func() -> void: _roll = 0.0)
	return b


func _build_stage() -> void:
	_stage_btn = Button.new()
	_stage_btn.text = "Сбросить ступень"
	_stage_btn.focus_mode = Control.FOCUS_NONE
	_stage_btn.custom_minimum_size = Vector2(280, 84)
	_stage_btn.add_theme_font_size_override("font_size", 26)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.55, 0.16, 0.1, 0.9)
	sb.set_corner_radius_all(14)
	sb.border_color = Color(1.0, 0.5, 0.35)
	sb.set_border_width_all(2)
	_stage_btn.add_theme_stylebox_override("normal", sb)
	_stage_btn.add_theme_stylebox_override("hover", sb)
	_stage_btn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 24)
	_stage_btn.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_stage_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_stage_btn.pressed.connect(_on_stage)
	_root.add_child(_stage_btn)

	_chute_btn = _button("Парашют", _on_chute, 170)
	_chute_btn.add_theme_font_size_override("font_size", 22)
	_chute_btn.custom_minimum_size = Vector2(170, 70)
	_chute_btn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 24)
	_chute_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_chute_btn.position += Vector2(250, -96)
	_chute_btn.visible = false
	_root.add_child(_chute_btn)

	_ap_btn = _button("Автопилот на орбиту", _on_autopilot, 270)
	_ap_btn.add_theme_font_size_override("font_size", 22)
	_ap_btn.custom_minimum_size = Vector2(230, 70)
	var apsb := StyleBoxFlat.new()
	apsb.bg_color = Color(0.06, 0.3, 0.38, 0.9)
	apsb.set_corner_radius_all(12)
	apsb.border_color = Color(0.4, 0.9, 1.0)
	apsb.set_border_width_all(2)
	_ap_btn.add_theme_stylebox_override("normal", apsb)
	_ap_btn.add_theme_stylebox_override("hover", apsb)
	_ap_btn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 24)
	_ap_btn.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_ap_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ap_btn.position.y -= 96
	_root.add_child(_ap_btn)


func _build_toast() -> void:
	_ap_label = Label.new()
	_ap_label.add_theme_font_size_override("font_size", 22)
	_ap_label.add_theme_color_override("font_color", Color(0.45, 0.9, 1.0))
	_ap_label.add_theme_constant_override("outline_size", 6)
	_ap_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_ap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ap_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 84)
	_ap_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_ap_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_ap_label)

	_toast = Label.new()
	_toast.add_theme_font_size_override("font_size", 26)
	_toast.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 120)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	box.add_child(grid)
	_inf_fuel_btn = CheckButton.new()
	_inf_fuel_btn.text = "Бесконечное топливо"
	_inf_fuel_btn.focus_mode = Control.FOCUS_NONE
	_inf_fuel_btn.toggled.connect(func(on: bool) -> void: flight.vessel.infinite_fuel = on)
	grid.add_child(_inf_fuel_btn)
	grid.add_child(_button("Сброс на старт", func() -> void:
		_debug_menu.hide()
		flight.reset_to_pad()))
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
	grid.add_child(_button("Время ×1000", func() -> void: flight.set_warp(flight.WARPS.find(1000))))
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
	t.text = "Ракета разрушена"
	t.add_theme_font_size_override("font_size", 36)
	t.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	box.add_child(t)
	_destroyed_label = Label.new()
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


func show_destroyed(reason: String) -> void:
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
	for k in _hold_buttons:
		var b: Button = _hold_buttons[k]
		b.set_pressed_no_signal(k == (v.hold_mode if v.hold_mode != "" else "sas"))


func _on_stage() -> void:
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
	var err: String = flight.vessel.deploy_chute()
	toast("Парашют раскрыт" if err == "" else err)


func on_autopilot_finished() -> void:
	_set_hold("sas")


func _on_map() -> void:
	flight.toggle_map()
	_map_btn.text = "Полёт" if flight.map_mode else "Карта"
	_focus_btn.visible = flight.map_mode
	_node_btn.visible = flight.map_mode
	if not flight.map_mode:
		_mn_panel.hide()


func _process(delta: float) -> void:
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
	_ap_btn.text = "Стоп автопилот" if ap.active() else "Автопилот"
	_chute_btn.visible = v.has_chute() and not v.chute_deployed and not v.landed \
		and v.body.has_atmosphere() and v.altitude() < v.body.atmosphere_height

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
	var state := "на поверхности" if v.landed else ("в атмосфере" if alt < b.atmosphere_height else "в космосе")
	state += " · " + b.name
	_telemetry.text = "\n".join(PackedStringArray([
		"Высота", "Скорость", "Над землёй", "Верт. скорость", "Апоцентр", "Перицентр",
		"Запас Δv ступени", "Запас Δv всего", "Тяга / вес", "Топливо ступени", "Где",
	]))
	_telemetry_values.text = "\n".join(PackedStringArray([
		OrbitLine.fmt_dist(alt),
		"%d м/с" % int(v.vel.length()),
		"%d м/с" % int(v.surface_velocity().length()),
		"%+d м/с" % int(vs),
		"—" if v.landed else OrbitLine.fmt_dist(el.apoapsis - b.radius),
		"—" if v.landed else OrbitLine.fmt_dist(el.periapsis - b.radius),
		"%d м/с" % int(dvs[dvs.size() - 1] if dvs.size() > 0 else 0.0),
		"%d м/с" % int(v.total_delta_v()),
		"%.2f" % v.twr(),
		"%d%%  (ступеней %d)" % [int(fuel_pct), v.stages.size()],
		state,
	]))
	_warp_label.text = "Время ×%d" % flight.warp()
	_warp_label.add_theme_color_override("font_color", Color(1, 0.75, 0.35) if flight.is_rails() else Color(0.9, 0.95, 1))
	_stage_btn.disabled = v.stages.size() <= 1

	var fixed := b.inertial_to_fixed(v.pos, flight.sim_time)
	var ll := CelestialBody.lat_lon(fixed)
	_overlay.text = "FPS %d · v%s (%d)\nСфера влияния: %s\nШир. %.4f°, долг. %.4f°\nВремя полёта %s" % [
		Engine.get_frames_per_second(),
		ProjectSettings.get_setting("application/config/version"),
		int(ProjectSettings.get_setting("starward/build/version_code")),
		b.name, ll.x, ll.y, _fmt_time(flight.sim_time),
	]


static func _fmt_time(t: float) -> String:
	var s := int(t)
	var d := s / 86400
	return ("%dд " % d if d > 0 else "") + "%02d:%02d:%02d" % [(s / 3600) % 24, (s / 60) % 60, s % 60]
