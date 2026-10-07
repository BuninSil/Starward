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
	draw_circle(c, radius, Color(0.08, 0.12, 0.22, 0.55))
	draw_arc(c, radius, 0, TAU, 64, Color(0.35, 0.55, 0.9, 0.8), 3.0, true)
	draw_line(c - Vector2(radius * 0.8, 0), c + Vector2(radius * 0.8, 0), Color(1, 1, 1, 0.12), 2.0)
	draw_line(c - Vector2(0, radius * 0.8), c + Vector2(0, radius * 0.8), Color(1, 1, 1, 0.12), 2.0)
	var knob := c + Vector2(value.x, -value.y) * radius
	draw_circle(knob, radius * 0.36, Color(0.3, 0.55, 1.0, 0.85))
