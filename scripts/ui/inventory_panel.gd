extends Control
## Inventory window: the astronaut's suit and the ship's hold side by side.
## Tap a stack to move it to the other side (only when the astronaut is in the
## ship or next to it). Shows slot use and the cargo mass the rocket carries.

const HudScript := preload("res://scripts/flight/flight_hud.gd")
const CELL := Vector2(86, 86)

var flight: Node3D
var _grids := {}       ## "astro"/"ship" -> GridContainer
var _heads := {}       ## "astro"/"ship" -> Label
var _note: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = HudScript.make_theme()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var top := HBoxContainer.new()
	box.add_child(top)
	var title := Label.new()
	title.text = "Груз"
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var close := Button.new()
	close.text = "Закрыть"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(150, 56)
	close.pressed.connect(hide)
	top.add_child(close)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	box.add_child(row)
	for key in ["astro", "ship"]:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 6)
		row.add_child(col)
		var h := Label.new()
		h.add_theme_font_size_override("font_size", 20)
		h.add_theme_color_override("font_color", Color(0.6, 0.67, 0.8))
		col.add_child(h)
		_heads[key] = h
		var g := GridContainer.new()
		g.columns = 4 if key == "astro" else 6
		g.add_theme_constant_override("h_separation", 6)
		g.add_theme_constant_override("v_separation", 6)
		col.add_child(g)
		_grids[key] = g
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", 18)
	_note.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(900, 0)
	box.add_child(_note)
	Game.inventories_changed.connect(refresh)
	visibility_changed.connect(func() -> void:
		if visible:
			refresh())
	refresh()


func _can_transfer() -> bool:
	return flight == null or flight.call("can_transfer_cargo")


func refresh() -> void:
	if not is_inside_tree():
		return
	var invs := {"astro": Game.astro_inv, "ship": Game.ship_inv}
	for key in invs:
		var inv: Inventory = invs[key]
		var g: GridContainer = _grids[key]
		for c in g.get_children():
			c.queue_free()
		for i in inv.size():
			g.add_child(_cell(inv, i, invs["ship" if key == "astro" else "astro"]))
		(_heads[key] as Label).text = "%s · %d/%d · %.0f кг" % [
			"Скафандр" if key == "astro" else "Корабль", inv.used(), inv.size(), inv.mass()]
	_note.text = "Нажми на стопку, чтобы переложить её на другую сторону. Груз корабля утяжеляет ракету." \
		if _can_transfer() else "Перекладывать можно только в корабле или рядом с ним."


func _cell(inv: Inventory, i: int, other: Inventory) -> Control:
	var b := Button.new()
	b.custom_minimum_size = CELL
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	var s = inv.slots[i]
	if s == null:
		b.disabled = true
		return b
	var id: String = s.id
	b.text = "%s\n×%d" % [Items.name_of(id), int(s.n)]
	b.add_theme_font_size_override("font_size", 15)
	var sb := StyleBoxFlat.new()
	var c := Items.color_of(id)
	sb.bg_color = Color(c.darkened(0.6), 0.9)
	sb.border_color = c
	sb.set_border_width_all(2)
	sb.border_width_top = 6
	sb.set_corner_radius_all(10)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, sb)
	b.pressed.connect(func() -> void:
		if not _can_transfer():
			refresh()
			return
		if inv.move_slot_to(i, other) == 0:
			_note.text = "Некуда класть: на другой стороне нет места."
		refresh())
	return b
