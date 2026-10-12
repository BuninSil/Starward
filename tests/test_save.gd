extends SceneTree
## Saves and inventory: stacking/moving, cargo mass in the rocket's dV, and a
## save -> load round trip in orbit and on the surface (state must match).
## godot --headless --path . --script tests/test_save.gd

var f: Node
var frames := 0
var fails := 0
var step := 0
var expect := {}
var game: Node


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	# Inventory basics.
	var inv := Inventory.new(3)
	_check(inv.add("ice", 800) == 50, "stacks of 250 in 3 slots, 50 left over")
	_check(inv.count("ice") == 750 and is_equal_approx(inv.mass(), 750.0), "count and mass")
	var other := Inventory.new(2)
	_check(inv.move_slot_to(0, other) == 250 and other.count("ice") == 250, "move a stack")
	_check(inv.remove("ice", 600) == 500 and inv.count("ice") == 0, "remove clamps to what is there")
	var back := Inventory.from_data(other.to_data(), 2)
	_check(back.count("ice") == 250, "inventory data round trip")


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		game = root.get_node("Game")
		game.new_game("sandbox", "orbit")
		f = load("res://scenes/flight.tscn").instantiate()
		root.add_child(f)
		return false
	if frames < 4:
		return false
	match step:
		0:
			# Cargo mass reaches the rocket.
			f._process(0.016)
			var m0: float = f.vessel.mass()
			var dv0: float = f.vessel.total_delta_v()
			game.ship_inv.add("metal", 40)   # +200 kg
			f._process(0.016)
			_check(absf(f.vessel.mass() - m0 - 200.0) < 0.01, "cargo adds to vessel mass")
			_check(f.vessel.total_delta_v() < dv0 - 1.0, "cargo lowers dV")
			f.teleport_to_body_orbit(SolarSystem.find(f.root_body, "moon"), 40_000.0)
			for k in 50:
				f.sim_tick()
			_snapshot()
			_check(game.save_to("slot2", f), "save in Moon orbit")
			game.load_from("slot2")
			step = 1
		1:
			f = root.get_child(root.get_child_count() - 1)
			if f.name != "Flight" and not f.has_method("save_state"):
				return false
			step = 2
		2:
			_compare("orbit")
			# Surface case.
			var mars = SolarSystem.find(f.root_body, "mars")
			f.teleport_to_surface(mars, 10.0, 20.0)
			for k in 20:
				f.sim_tick()
			_snapshot()
			_check(game.save_to("slot3", f), "save on Mars surface")
			game.load_from("slot3")
			step = 3
		3:
			f = root.get_child(root.get_child_count() - 1)
			if not f.has_method("save_state"):
				return false
			step = 4
		4:
			_compare("surface")
			_check(f.vessel.landed, "still landed after load")
			print("FAILURES: %d" % fails)
			quit(1 if fails > 0 else 0)
			return true
	return false


func _snapshot() -> void:
	var v = f.vessel
	expect = {"t": f.sim_time, "body": v.body.id, "pos": v.pos.copy(), "vel": v.vel.copy(),
		"fuel": float(v.stages[v.stages.size() - 1].fuel), "stages": v.stages.size(),
		"metal": game.ship_inv.count("metal"), "mass": v.mass()}


func _compare(what: String) -> void:
	var v = f.vessel
	f._process(0.016)
	# The new scene may already have run a few physics steps: allow for them.
	var dt: float = f.sim_time - expect.t
	_check(dt >= 0.0 and dt < 0.5, what + ": time restored (+%.3f s of physics)" % dt)
	_check(v.body.id == expect.body, what + ": body restored")
	var guess: DVec3 = expect.pos.add(expect.vel.mul(dt))
	var err: float = v.pos.sub(guess).length()
	_check(err < 1.0, what + ": position restored (%.3f m off)" % err)
	_check(v.vel.sub(expect.vel).length() < 2.0 * maxf(dt, 0.01) + 0.01, what + ": velocity restored")
	_check(v.stages.size() == expect.stages and is_equal_approx(float(v.stages[v.stages.size() - 1].fuel), expect.fuel), what + ": stages and fuel")
	_check(game.ship_inv.count("metal") == expect.metal, what + ": cargo restored")
	_check(absf(v.mass() - expect.mass) < 0.01, what + ": mass incl. cargo")
