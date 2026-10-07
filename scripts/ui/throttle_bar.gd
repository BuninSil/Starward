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
	draw_rect(r, Color(0.06, 0.09, 0.17, 0.75))
	var h := size.y * value
	var fill := Rect2(Vector2(0, size.y - h), Vector2(size.x, h))
	draw_rect(fill, Color(1.0, 0.55, 0.2, 0.55).lerp(Color(1.0, 0.75, 0.3, 0.85), value))
	draw_rect(r, Color(0.35, 0.55, 0.9, 0.8), false, 3.0)
	for i in range(1, 4):
		var y := size.y * i / 4.0
		draw_line(Vector2(0, y), Vector2(14, y), Color(1, 1, 1, 0.35), 2.0)
		draw_line(Vector2(size.x - 14, y), Vector2(size.x, y), Color(1, 1, 1, 0.35), 2.0)
	var gy := size.y - h
	draw_rect(Rect2(Vector2(-4, gy - 8), Vector2(size.x + 8, 16)), Color(1, 0.85, 0.55))
