extends SceneTree
## Resources, crafting, refuelling and the astronaut's drill.
## godot --headless --path . --script tests/test_resources.gd

var f: Node
var frames := 0
var fails := 0
var game: Node


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1


func _process(_d: float) -> bool:
	frames += 1
	if frames == 1:
		# Resource map.
		var eq := Resources.at("moon", 0.0, 30.0)
		var pole := Resources.at("moon", 88.0, 30.0)
		_check(eq.ice < 0.05 and pole.ice > 0.4, "Moon: ice in polar cold traps, not at the equator (%.2f / %.2f)" % [eq.ice, pole.ice])
		_check(Resources.at("moon", 10.0, 10.0).regolith > 0.8, "Moon: regolith everywhere")
		_check(Resources.at("mars", 75.0, 0.0).ice > 0.7, "Mars: polar ice")
		_check(Resources.at("venus", 0.0, 0.0).ice == 0.0, "Venus: no ice")
		var same := Resources.at("mars", 12.3, 45.6)
		_check(same.ore == Resources.at("mars", 12.3, 45.6).ore, "deterministic")
		# Crafting.
		var ship := Inventory.new(24)
		var suit := Inventory.new(12)
		ship.add("ice", 25)
		suit.add("ice", 15)
		var fuel_r: Dictionary = Crafting.RECIPES[1]
		_check(Crafting.craft(fuel_r, [ship, suit], ship) == "" and ship.count("fuel") == 1 and ship.count("ice") == 5, "craft fuel from ice (ship first)")
		_check(Crafting.craft(fuel_r, [ship, suit], ship) == "" and suit.count("ice") == 0 and ship.count("ice") == 0, "craft takes the rest from the suit")
		_check(Crafting.craft(fuel_r, [ship, suit], ship) != "", "not enough ice -> refused")
		game = root.get_node("Game")
		game.new_game("career", "moon")
		f = load("res://scenes/flight.tscn").instantiate()
		root.add_child(f)
		return false
	if frames != 4:
		return false
	# Refuel the bottom stage.
	var v: Vessel = f.vessel
	var s: Dictionary = v.stages[v.stages.size() - 1]
	s.fuel = float(s.fuel_max) - 25.0
	var inv := Inventory.new(4)
	inv.add("fuel", 5)
	var kg := Crafting.refuel(v, [inv])
	_check(absf(kg - 25.0) < 0.01 and absf(float(s.fuel) - float(s.fuel_max)) < 0.01 and inv.count("fuel") == 2, "refuel tops up the active stage (%.0f kg, %d left)" % [kg, inv.count("fuel")])
	# Drill near the lunar south pole (real frames: the ground ray needs physics).
	var moon = SolarSystem.find(f.root_body, "moon")
	f.teleport_lunar_module_to_orbit(30_000.0)
	f.teleport_to_surface(moon, -86.0, 40.0)
	f.start_eva()
	before = game.astro_inv.count("ice") + game.astro_inv.count("regolith") + game.astro_inv.count("ore")
	f.drill_held = true
	return false


var before := 0


func _physics_process(_d: float) -> bool:
	if frames < 5 or f == null or f.astronaut == null:
		return false
	drill_frames += 1
	if drill_frames < 60 * 12:
		return false
	f.drill_held = false
	var got: int = game.astro_inv.count("ice") + game.astro_inv.count("regolith") + game.astro_inv.count("ore") - before
	_check(got >= 8, "drilling 12 s at the pole yields resources (%d, ice %d)" % [got, game.astro_inv.count("ice")])
	_check(game.astro_inv.count("ice") > 0, "polar drilling finds ice")
	# Oxygen cylinder.
	f.astronaut.oxygen = 100.0
	var err: String = f.use_oxygen_item()
	_check(err == "" and f.astronaut.oxygen > 600.0, "oxygen item refills the suit (%s)" % err)
	print("FAILURES: %d" % fails)
	quit(1 if fails > 0 else 0)
	return true


var drill_frames := 0
