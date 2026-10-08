extends PanelContainer
## Manual maneuver editor (map mode): where to burn, Δv along prograde / normal /
## radial with coarse and fine steps, live preview on the map, execute via autopilot.

var flight: Node3D
var _info: Label
var _when: Label
var _vals := {}


func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.04, 0.09, 0.82)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(12)
	add_theme_stylebox_override("panel", sb)
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	var head := HBoxContainer.new()
	box.add_child(head)
	var t := Label.new()
	t.text = "Манёвр"
	t.add_theme_font_size_override("font_size", 26)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_btn("Удалить", func() -> void: flight.clear_maneuver()))
	head.add_child(_btn("Скрыть", hide))

	var where := HBoxContainer.new()
	where.add_theme_constant_override("separation", 4)
	box.add_child(where)
	where.add_child(_btn("Через 2 мин", func() -> void: flight.maneuver_set_time("soon")))
	where.add_child(_btn("В апоцентре", func() -> void: flight.maneuver_set_time("apo")))
	where.add_child(_btn("В перицентре", func() -> void: flight.maneuver_set_time("peri")))
	var shift := HBoxContainer.new()
	shift.add_theme_constant_override("separation", 4)
	box.add_child(shift)
	for d in [[-600, "−10м"], [-60, "−1м"], [60, "+1м"], [600, "+10м"]]:
		var dt: float = d[0]
		shift.add_child(_btn(d[1], func() -> void: flight.maneuver_shift(dt)))
	_when = Label.new()
	_when.add_theme_font_size_override("font_size", 18)
	shift.add_child(_when)

	for comp in [["prograde", "По ходу"], ["normal", "Нормаль"], ["radial", "Радиально"]]:
		var key: String = comp[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 3)
		box.add_child(row)
		var l := Label.new()
		l.text = comp[1]
		l.custom_minimum_size = Vector2(110, 0)
		l.add_theme_font_size_override("font_size", 18)
		row.add_child(l)
		for st in [-100.0, -10.0, -1.0]:
			var s2: float = st
			row.add_child(_btn("%d" % int(st), func() -> void: flight.maneuver_add(key, s2), 54))
		var vl := Label.new()
		vl.custom_minimum_size = Vector2(90, 0)
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vl.add_theme_font_size_override("font_size", 18)
		row.add_child(vl)
		_vals[key] = vl
		for st in [1.0, 10.0, 100.0]:
			var s3: float = st
			row.add_child(_btn("+%d" % int(st), func() -> void: flight.maneuver_add(key, s3), 54))

	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 18)
	_info.add_theme_color_override("font_color", Color(1.0, 0.95, 0.55))
	box.add_child(_info)
	var exec := _btn("Выполнить автопилотом", func() -> void: flight.execute_maneuver())
	exec.custom_minimum_size = Vector2(0, 58)
	box.add_child(exec)


func _btn(text: String, cb: Callable, w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(w, 48)
	b.add_theme_font_size_override("font_size", 17)
	b.pressed.connect(cb)
	return b


func refresh(info: String) -> void:
	var n: ManeuverNode = flight.maneuver
	if n == null:
		return
	(_vals.prograde as Label).text = "%+.0f" % n.prograde
	(_vals.normal as Label).text = "%+.0f" % n.normal
	(_vals.radial as Label).text = "%+.0f" % n.radial
	_when.text = "  через %s" % ApExecute._fmt(maxf(n.t - flight.sim_time, 0.0))
	_info.text = "Всего %d м/с · %s" % [int(n.total()), info]
