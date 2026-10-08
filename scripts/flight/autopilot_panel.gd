extends PanelContainer
## Autopilot panel: pick a task with its parameter, run it now or add it to a chain,
## run the chain, or launch the full preset mission.

var flight: Node3D

## [kind, title, param_name, unit, min, max, step, default]
const TASKS := [
	["orbit", "Выход на орбиту Земли", "высота", "км", 15, 100, 5, 20],
	["moon", "Перелёт к Луне и выход на орбиту", "высота у Луны", "км", 10, 200, 10, 30],
	["home", "Возврат на Землю и посадка", "перицентр у Земли", "км", 1, 8, 1, 3],
	["deorbit", "Сход с орбиты и посадка", "", "", 0, 0, 0, 0],
	["circ_apo", "Скруглить орбиту в апоцентре", "", "", 0, 0, 0, 0],
	["circ_peri", "Скруглить орбиту в перицентре", "", "", 0, 0, 0, 0],
	["node", "Выполнить мой манёвр", "", "", 0, 0, 0, 0],
]

var _values := {}
var _value_labels := {}
var _chain: Array = []     ## [[kind, value], ...]
var _chain_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var head := HBoxContainer.new()
	box.add_child(head)
	var title := Label.new()
	title.text = "Автопилот"
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(_btn("Закрыть", hide))

	for t in TASKS:
		var kind: String = t[0]
		_values[kind] = t[7]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		box.add_child(row)
		var name_l := Label.new()
		name_l.text = t[1]
		name_l.custom_minimum_size = Vector2(380, 0)
		name_l.add_theme_font_size_override("font_size", 20)
		row.add_child(name_l)
		if t[2] != "":
			row.add_child(_btn("−", func() -> void: _step(kind, -1)))
			var vl := Label.new()
			vl.custom_minimum_size = Vector2(150, 0)
			vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			vl.add_theme_font_size_override("font_size", 19)
			row.add_child(vl)
			_value_labels[kind] = vl
			row.add_child(_btn("+", func() -> void: _step(kind, 1)))
		else:
			var spacer := Control.new()
			spacer.custom_minimum_size = Vector2(150 + 2 * 64 + 12, 0)
			row.add_child(spacer)
		row.add_child(_btn("Пуск", func() -> void: _run([[kind, _values[kind]]])))
		row.add_child(_btn("+ в цепочку", func() -> void: _add(kind)))
		_refresh_value(kind)

	var sep := HSeparator.new()
	box.add_child(sep)
	_chain_label = Label.new()
	_chain_label.add_theme_font_size_override("font_size", 19)
	_chain_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chain_label.custom_minimum_size = Vector2(900, 0)
	box.add_child(_chain_label)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	box.add_child(bottom)
	bottom.add_child(_btn("Полная миссия: орбита → Луна → домой", _full_mission))
	bottom.add_child(_btn("Запустить цепочку", func() -> void: _run(_chain.duplicate())))
	bottom.add_child(_btn("Очистить", func() -> void:
		_chain.clear()
		_refresh_chain()))
	_refresh_chain()


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(64, 52)
	b.add_theme_font_size_override("font_size", 19)
	b.pressed.connect(cb)
	return b


func _step(kind: String, dir: int) -> void:
	for t in TASKS:
		if t[0] == kind:
			_values[kind] = clampi(_values[kind] + dir * t[6], t[4], t[5])
	_refresh_value(kind)


func _refresh_value(kind: String) -> void:
	if not _value_labels.has(kind):
		return
	for t in TASKS:
		if t[0] == kind:
			(_value_labels[kind] as Label).text = "%s %d %s" % [t[2], _values[kind], t[3]]


func _add(kind: String) -> void:
	_chain.append([kind, _values[kind]])
	_refresh_chain()


func _full_mission() -> void:
	var items: Array = []
	var v: Vessel = flight.vessel
	if v.landed or v.body.has_atmosphere() and OrbitMath.elements(v.pos, v.vel, v.body.mu).periapsis - v.body.radius < v.body.atmosphere_height:
		items.append(["orbit", _values["orbit"]])
	items.append(["moon", _values["moon"]])
	items.append(["home", _values["home"]])
	_run(items)


func _title_of(item: Array) -> String:
	for t in TASKS:
		if t[0] == item[0]:
			return t[1] + ("" if t[2] == "" else " (%d %s)" % [item[1], t[3]])
	return str(item)


func _refresh_chain() -> void:
	if _chain.is_empty():
		_chain_label.text = "Цепочка пуста. Добавляй задачи кнопкой «+ в цепочку» — выполнятся по порядку."
		return
	var parts := PackedStringArray()
	for i in _chain.size():
		parts.append("%d. %s" % [i + 1, _title_of(_chain[i])])
	_chain_label.text = "Цепочка: " + "  →  ".join(parts)


func _run(items: Array) -> void:
	var tasks: Array = []
	for it in items:
		match it[0]:
			"orbit": tasks += Autopilot.tasks_orbit(it[1] * 1000.0)
			"moon": tasks += Autopilot.tasks_moon(flight.root_body, it[1] * 1000.0)
			"home": tasks += Autopilot.tasks_home(it[1] * 1000.0)
			"deorbit": tasks += Autopilot.tasks_deorbit()
			"circ_apo": tasks += Autopilot.tasks_circularize("apo")
			"circ_peri": tasks += Autopilot.tasks_circularize("peri")
			"node":
				if flight.maneuver == null:
					flight.message.emit("Сначала создай манёвр на карте")
					return
				tasks += Autopilot.tasks_execute(flight.maneuver)
	if tasks.is_empty():
		return
	hide()
	flight.start_mission(tasks)
