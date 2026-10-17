extends SceneTree
## Surface bases (stage 6c): energy from real sunlight, drills, processor,
## catching up after an absence, store limits, save round trip.
## godot --headless --path . --script tests/test_bases.gd

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	var root := SolarSystem.build()
	var moon := SolarSystem.find(root, "moon")
	# Polar base on the Moon (summer pole at the epoch): ice there, sun low but long.
	var b := Bases.make("moon", 86.0, 20.0, 0.0, 0.0)
	for m in [["solar", 0, 0], ["solar", 1, 0], ["battery", 0, 1], ["storage", 1, 1], ["drill", -1, 0], ["processor", -1, 1]]:
		Bases.add_module(b, m[0], m[1], m[2], 0)
	check(Bases.slots(b) == Bases.BASE_SLOTS + 12, "storage adds slots")
	check(Bases.occupied(b, 1, 1) and not Bases.occupied(b, 2, 2), "grid occupancy")
	var made := Bases.simulate(b, moon, 3.0 * 86400.0)
	print("    3 days at the pole: ", made, " energy %.1f kWh" % float(b.energy))
	var inv := Bases.store(b)
	check(inv.count("ice") + int(made.get("fuel", 0)) * 20 > 50, "drill dug ice while away")
	check(int(made.get("fuel", 0)) > 0, "processor made fuel from ice")
	check(float(b.energy) >= 0.0 and float(b.energy) <= Bases.battery_kwh(b) + 1e-6, "battery within capacity")
	# Equator base without panels: nothing runs.
	var dark := Bases.make("moon", 0.0, 0.0, 0.0, 0.0)
	Bases.add_module(dark, "drill", 0, 0, 0)
	var m2 := Bases.simulate(dark, moon, 86400.0)
	check(m2.is_empty(), "no power, no work")
	# Sunlight follows the lunar day: some hours lit, some dark over a month.
	var eq := Bases.make("moon", 0.0, 0.0, 0.0, 0.0)
	var lit := 0
	for i in 60:
		if Bases.sunlight(eq, moon, i * 0.5 * 86400.0) > 0.0:
			lit += 1
	check(lit > 15 and lit < 45, "lunar day and night (%d of 60 samples lit)" % lit)
	# Store limit: a tiny base fills up and stops.
	var full := Bases.make("moon", 86.0, 20.0, 0.0, 0.0)
	for m in [["solar", 0, 0], ["solar", 1, 0], ["solar", 2, 0], ["battery", 0, 1], ["drill", -1, 0]]:
		Bases.add_module(full, m[0], m[1], m[2], 0)
	Bases.simulate(full, moon, 40.0 * 86400.0)
	var fi := Bases.store(full)
	check(fi.used() <= fi.size(), "store never overflows (%d/%d slots)" % [fi.used(), fi.size()])
	# Save round trip through JSON (ints become floats).
	var back = JSON.parse_string(JSON.stringify(b))
	check(Bases.count(back, "solar") == 2 and Bases.store(back).count("ice") == inv.count("ice"), "JSON round trip")
	var m3 := Bases.simulate(back, moon, 4.0 * 86400.0)
	check(not m3.is_empty(), "keeps working after loading")
	# Snapping: the cell of a module's own centre is that cell.
	var c := Bases.cell_dir(b, 3, -2, moon.radius)
	check(Bases.cell_of(b, c, moon.radius) == Vector2i(3, -2), "grid snapping")
	print("FAILURES: %d" % fails)
	quit(1 if fails > 0 else 0)
