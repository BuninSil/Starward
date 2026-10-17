extends SceneTree
## Ship in the Elite Dangerous style: lift off on thrusters, hover with flight
## assist, fly forward at the set speed, set down gently with "down" held.
## godot --headless --path . --script tests/test_ship.gd

var f: Node
var frames := 0
var fails := 0
var phase := 0
var t_phase := 0.0
var h0 := 0.0


func _initialize() -> void:
	Vessel.design = "ship"
	f = load("res://scenes/flight.tscn").instantiate()
	root.add_child(f)


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		fails += 1


func _process(_d: float) -> bool:
	frames += 1
	if frames < 3:
		return false
	var v: Vessel = f.vessel
	if frames == 3:
		_check(v.is_ship(), "ship design")
		print("  TWR %.2f, dV %.0f m/s" % [v.twr(), v.total_delta_v()])
		h0 = v.altitude_above_ground(f.sim_time)
	for i in 30:
		f.sim_tick()
		t_phase += Vessel_DT()
		var agl := v.altitude_above_ground(f.sim_time)
		var up := v.pos.normalized().to_v3()
		var vs := v.surface_velocity().to_v3().dot(up)
		var gs := (v.surface_velocity().to_v3() - up * vs).length()
		match phase:
			0:
				v.ship_lift = 1.0
				if t_phase > 6.0:
					_check(not v.landed and agl > 100.0, "lifted off on thrusters (%.0f m)" % agl)
					v.ship_lift = 0.0
					phase = 1
					t_phase = 0.0
			1:
				if t_phase > 6.0:
					_check(absf(vs) < 1.0, "hovers with flight assist (vs %.2f m/s)" % vs)
					v.throttle = 0.5
					phase = 2
					t_phase = 0.0
			2:
				if t_phase > 25.0:
					var want: float = 0.5 * v.ship_max_speed()
					_check(absf(gs - want) < want * 0.15, "flies at the set speed (%.0f of %.0f m/s)" % [gs, want])
					_check(agl > 50.0, "holds height while flying (%.0f m)" % agl)
					v.throttle = 0.0
					phase = 3
					t_phase = 0.0
			3:
				if t_phase > 20.0:
					_check(gs < 3.0, "stops when the throttle is cut (%.1f m/s)" % gs)
					v.ship_lift = -1.0
					phase = 4
					t_phase = 0.0
			4:
				if v.landed or v.destroyed_flag or t_phase > 120.0:
					_check(v.landed and not v.destroyed_flag, "set down gently (touchdown %.1f m/s)" % v.touchdown_speed)
					print("FAILURES: %d" % fails)
					quit(0 if fails == 0 else 1)
					return true
	return false


func Vessel_DT() -> float:
	return 1.0 / 60.0
