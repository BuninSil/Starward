extends Control
## Vertical throttle: drag anywhere on the bar, value 0..1 (top = 1).

signal changed(value: float)

var value := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(96, 280)
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_value_no_signal(v: float) -> void:
	value = clampf(v, 0.0, 1.0)
	queue_redraw()


func set_value(v: float) -> void:
	set_value_no_signal(v)
	changed.emit(value)


func _gui_input(event: InputEvent) -> void:
	if (event is InputEventScreenTouch and event.pressed) or event is InputEventScreenDrag:
		set_value(1.0 - event.position.y / size.y)
		accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.03, 0.05, 0.09, 0.7)
	bg.border_color = Color(1, 1, 1, 0.16)
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(14)
	draw_style_box(bg, r)
	var h := (size.y - 8.0) * value
	if h > 1.0:
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(1.0, 0.5, 0.18, 0.75).lerp(Color(1.0, 0.72, 0.3, 0.95), value)
		fill.set_corner_radius_all(10)
		draw_style_box(fill, Rect2(Vector2(4, size.y - 4.0 - h), Vector2(size.x - 8.0, h)))
	for i in range(1, 4):
		var y := size.y * i / 4.0
		draw_line(Vector2(10, y), Vector2(24, y), Color(1, 1, 1, 0.35), 2.0)
		draw_line(Vector2(size.x - 24, y), Vector2(size.x - 10, y), Color(1, 1, 1, 0.35), 2.0)
