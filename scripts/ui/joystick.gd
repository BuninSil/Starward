extends Control
## Touch joystick. `value` is in -1..1 on both axes (y up = +1), springs back to 0.

signal changed(value: Vector2)

@export var radius := 110.0

var value := Vector2.ZERO
var _touch := -1
var _center := Vector2.ZERO


func _ready() -> void:
	custom_minimum_size = Vector2(radius, radius) * 2.0
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _touch == -1:
			_touch = event.index
			_update(event.position)
			accept_event()
		elif not event.pressed and event.index == _touch:
			_touch = -1
			_set_value(Vector2.ZERO)
			accept_event()
	elif event is InputEventScreenDrag and event.index == _touch:
		_update(event.position)
		accept_event()


func _update(pos: Vector2) -> void:
	var d := (pos - size * 0.5) / radius
	d = d.limit_length(1.0)
	_set_value(Vector2(d.x, -d.y))


func _set_value(v: Vector2) -> void:
	value = v
	changed.emit(v)
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	draw_circle(c, radius, Color(0.03, 0.05, 0.09, 0.62))
	draw_arc(c, radius - 1.0, 0, TAU, 72, Color(1, 1, 1, 0.16), 2.0, true)
	draw_arc(c, radius * 0.55, 0, TAU, 56, Color(1, 1, 1, 0.07), 2.0, true)
	for a in 4:
		var d := Vector2.from_angle(a * PI * 0.5)
		draw_line(c + d * radius * 0.72, c + d * radius * 0.9, Color(1, 1, 1, 0.3), 3.0, true)
	var knob := c + Vector2(value.x, -value.y) * radius
	var active := value.length() > 0.01
	draw_circle(knob, radius * 0.34, Color(1.0, 0.62, 0.22, 0.9) if active else Color(0.85, 0.88, 0.95, 0.75))
	draw_arc(knob, radius * 0.34, 0, TAU, 40, Color(1, 1, 1, 0.5), 2.0, true)
