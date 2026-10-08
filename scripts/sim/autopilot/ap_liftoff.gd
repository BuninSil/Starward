class_name ApLiftoff
extends ApTask
## Before lifting off from a body: leaves the descent stage (the one with legs)
## on the ground so the ascent stage flies alone, like a lunar module.

var _timer := 0.0


func _init() -> void:
	title = "Отделение посадочной ступени"


func update(_ap: Autopilot, v: Vessel, _t: float) -> int:
	v.throttle = 0.0
	if not v.landed:
		message = "уже в полёте"
		return DONE
	var legs := v.legs_stage()
	if legs < 0 or legs != v.stages.size() - 1 or v.stages.size() <= 2:
		message = "посадочной ступени нет"
		return DONE
	_timer += 1.0 / 60.0
	if _timer < 0.5:
		status = "отделение…"
		return RUNNING
	v.stage()
	message = "посадочная ступень осталась на поверхности"
	return DONE
