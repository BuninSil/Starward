extends SceneTree
## EVA smoke test on the flight scene: exit, winch back, enter; ship thrust breaks the tether.

var frames := 0
var f: Node
var fails := 0


func check(c: bool, m: String) -> void:
	print(("  ok   " if c else "  FAIL ") + m)
	if not c:
		fails += 1


func _initialize() -> void:
	f = load("res://scenes/flight.tscn").instantiate()
	root.add_child(f)


func _physics_process(_d: float) -> bool:
	frames += 1
	match frames:
		5:
			f.teleport_to_orbit(20000.0)
		10:
			f.start_eva()
			check(f.eva_mode, "EVA started in orbit")
		11:
			f.astronaut.linear_velocity = f.astronaut.global_position.normalized() * 1.0
		700:
			check(f.astronaut_hatch_distance() > 8.0, "drifted away on the tether (%.1f m)" % f.astronaut_hatch_distance())
			check(f.astronaut_hatch_distance() < 14.0, "tether holds the astronaut (<= length + stretch)")
			f.tether.winching = true
		1700:
			f.tether.winching = false
			f.astronaut.kill_rel_velocity = true
			check(f.astronaut_hatch_distance() < 2.5, "winch pulled back to the hatch (%.2f m)" % f.astronaut_hatch_distance())
		1760:
			f.end_eva()
			check(not f.eva_mode, "entered the ship")
		1770:
			f.start_eva()
		1780:
			f.debug_ship_kick()
		1950:
			check(f.tether.broken, "ship thrust broke the tether")
			check(f.astronaut.propellant <= 5.0 and f.astronaut.oxygen < 1200.0, "propellant/oxygen accounted")
			print("FAILURES: %d" % fails)
			quit(1 if fails > 0 else 0)
			return true
	return false
