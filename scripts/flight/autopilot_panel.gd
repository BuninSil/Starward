extends PanelContainer
## Autopilot panel: pick a task with its parameter, run it now or add it to a chain,
## run the chain, or launch the full preset mission.

var flight: Node3D

## [kind, title, param_name, unit, min, max, step, default]
const TASKS := [
	["orbit", "Выход на орбиту Земли", "высота", "км", 15, 100, 5, 20],
	["moon", "Перелёт к Луне и выход на орбиту", "высота у Луны", "км", 10, 200, 10, 30],
	["planet", "Перелёт к планете (выход на орбиту)", "цель", "", 0, 7, 1, 3],
	["moon_land", "Посадка на Луну (с орбиты Луны)", "", "", 0, 0, 0, 0],
	["moon_up", "Взлёт с Луны на орбиту", "высота", "км", 15, 60, 5, 20],
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
var _window_label: Label


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

	# Task rows scroll: the list is taller than a phone screen in landscape.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 330)
	box.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	scroll.add_child(rows)
	for t in TASKS:
		var kind: String = t[0]
		_values[kind] = t[7]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		rows.add_child(row)
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

	_window_label = Label.new()
	_window_label.add_theme_font_size_override("font_size", 19)
	_window_label.add_theme_color_override("font_color", Color(0.75, 0.9, 1.0))
	box.add_child(_window_label)
	visibility_changed.connect(func() -> void:
		if visible:
			_refresh_window())
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 10)
	box.add_child(presets)
	var pl := Label.new()
	pl.text = "Миссии:"
	pl.add_theme_font_size_override("font_size", 20)
	presets.add_child(pl)
	presets.add_child(_btn("Орбита → Луна → домой", _full_mission))
	presets.add_child(_btn("На Луну с посадкой", _moon_landing_mission))
	presets.add_child(_btn("Взлёт с Луны и домой", _moon_home_mission))
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
			if kind == "planet":
				_values[kind] = posmod(_values[kind] + dir, _planets().size())
			else:
				_values[kind] = clampi(_values[kind] + dir * t[6], t[4], t[5])
	_refresh_value(kind)
	if kind == "planet":
		_refresh_window()


func _planets() -> Array[CelestialBody]:
	return flight.root_body.children


func _target_planet() -> CelestialBody:
	return _planets()[_values["planet"]]


## Window hint for the selected planet from the vessel's current planet.
func _refresh_window() -> void:
	if _window_label == null or flight == null or flight.vessel == null:
		return
	var tgt := _target_planet()
	var from: CelestialBody = flight.vessel.body
	while from.parent != null and from.parent != flight.root_body:
		from = from.parent   # from the Moon: count from Earth
	if from == tgt or from.parent == null:
		_window_label.text = ""
		return
	var w := Planner.transfer_window(from, tgt, flight.sim_time)
	if w.is_empty():
		_window_label.text = ""
		return
	_window_label.text = "Окно %s → %s через %d сут, в пути ~%d сут, Δv отлёта ≈ %d м/с" % [
		from.name, tgt.name, int((float(w.t_depart) - flight.sim_time) / 86400.0),
		int(float(w.tof) / 86400.0), int(w.dv_hint)]


func _refresh_value(kind: String) -> void:
	if not _value_labels.has(kind):
		return
	if kind == "planet":
		(_value_labels[kind] as Label).text = "→ " + _target_planet().name
		return
	for t in TASKS:
		if t[0] == kind:
			(_value_labels[kind] as Label).text = "%s %d %s" % [t[2], _values[kind], t[3]]


func _add(kind: String) -> void:
	_chain.append([kind, _values[kind]])
	_refresh_chain()


## Presets start from where the vessel is now (pad, Earth orbit, Moon orbit, Moon surface).
func _at_moon() -> bool:
	return flight.vessel.body.name == "Луна"


## Ascent to Earth orbit if the vessel is on the ground / suborbital at Earth.
func _to_orbit_items() -> Array:
	var v: Vessel = flight.vessel
	if v.body != flight.home:
		return []
	if v.landed or v.body.has_atmosphere() and OrbitMath.elements(v.pos, v.vel, v.body.mu).periapsis - v.body.radius < v.body.atmosphere_height:
		return [["orbit", _values["orbit"]]]
	return []


## Pad / Earth orbit -> Moon orbit; nothing if already at the Moon.
func _to_moon_items() -> Array:
	if _at_moon():
		return []
	return _to_orbit_items() + [["moon", _values["moon"]]]


## Home from wherever we are at the Moon (lifting off first if landed).
func _home_items() -> Array:
	var items: Array = []
	if _at_moon() and flight.vessel.landed:
		items.append(["moon_up", _values["moon_up"]])
	items.append(["home", _values["home"]])
	return items


func _full_mission() -> void:
	_run(_to_moon_items() + _home_items())


func _moon_landing_mission() -> void:
	if _at_moon() and flight.vessel.landed:
		flight.message.emit("Уже на Луне")
		return
	_run(_to_moon_items() + [["moon_land", 0]])


func _moon_home_mission() -> void:
	if not _at_moon():
		flight.message.emit("Сначала долети до Луны")
		return
	_run(_home_items())


func _title_of(item: Array) -> String:
	if item[0] == "planet":
		return "Перелёт к планете " + _planets()[item[1]].name
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
			"home":
				var vb: CelestialBody = flight.vessel.body
				if vb.parent == flight.root_body and vb != flight.home:
					tasks += Autopilot.tasks_planet_home(flight.home, it[1] * 1000.0)
				else:
					tasks += Autopilot.tasks_home(it[1] * 1000.0)
			"planet":
				var tgt: CelestialBody = _planets()[it[1]]
				var cur: CelestialBody = flight.vessel.body
				if cur == tgt:
					flight.message.emit("Уже у %s" % tgt.name)
					return
				if cur.parent != flight.root_body:
					flight.message.emit("Сначала выйди на орбиту планеты (не спутника)")
					return
				if flight.vessel.landed and cur == flight.home:
					tasks += Autopilot.tasks_orbit(_values["orbit"] * 1000.0)
				if tgt == flight.home:
					tasks += Autopilot.tasks_planet_home(flight.home, _values["home"] * 1000.0)
				else:
					tasks += Autopilot.tasks_planet(tgt, flight.default_orbit_altitude(tgt))
			"moon_land": tasks += Autopilot.tasks_moon_land()
			"moon_up": tasks += Autopilot.tasks_moon_ascent(it[1] * 1000.0, SolarSystem.find(flight.root_body, "moon"), flight.sim_time)
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
