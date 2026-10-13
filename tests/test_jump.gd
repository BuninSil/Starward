extends SceneTree
## The astronaut actually leaves the ground when jumping (Moon and Earth).
var f: Node
var frames := 0
var fails := 0
var body_i := 0
var bodies := ["moon", "earth"]
var t0 := 0
var peak := 0.0
var base := 0.0


func _physics_process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		f = load("res://scenes/flight.tscn").instantiate()
		root.add_child(f)
		return false
	if frames == 4:
		var b = SolarSystem.find(f.root_body, bodies[body_i])
		f.teleport_to_surface(b, 0.0, 20.0)
		f.start_eva()
		t0 = frames
		return false
	if t0 == 0 or f.astronaut == null:
		return false
	var a = f.astronaut
	var g: Vector3 = f._terrain_point(f.vessel.pos.add(DVec3.from_v3(a.global_position)))
	var h: float = (a.global_position - g).dot(a.up_dir)
	if frames == t0 + 60:
		base = h
		a.jump_requested = true
	if frames > t0 + 60:
		peak = maxf(peak, h - base)
	if frames == t0 + 60 + 240:
		var want: float = 0.6 if bodies[body_i] == "moon" else 0.5
		var ok: bool = peak > want
		print(("ok   " if ok else "FAIL ") + "%s jump height %.2f m (want > %.1f)" % [bodies[body_i], peak, want])
		if not ok:
			fails += 1
		body_i += 1
		if body_i >= bodies.size():
			print("FAILURES: %d" % fails)
			quit(1 if fails > 0 else 0)
			return true
		f.end_eva()
		peak = 0.0
		frames = 3
		t0 = 0
	return false
