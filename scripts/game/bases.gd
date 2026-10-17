class_name Bases
extends RefCounted
## Surface bases (stage 6c): modules on a 4 m grid around an anchor point
## (lat/lon on a body), a shared store, an energy buffer. Pure data and
## simulation, no scene: Game keeps the list and saves it, the flight scene
## draws it (scripts/flight/base_view.gd) and builds on it.
##
## A base keeps working while the player is away: simulate() advances it from
## its last time to now in steps, with real sunlight at its place (the body's
## turn and the Sun's direction), so panels go dark at night, batteries carry
## the load, and drills/processors stop when power runs out or the store is full.

const CELL := 4.0                 ## metres per grid cell
const NEAR := 40.0                ## metres: a new module joins a base this close
const BASE_SLOTS := 4             ## store slots of a base without storage modules
const MAX_CATCH_UP := 60.0 * 86400.0   ## simulate at most 60 days of absence

const MODULES := {
	"solar": {"name": "Солнечная панель", "cost": {"metal": 4, "parts": 2},
		"desc": "2 кВт на солнце, ночью — ноль", "gen_kw": 2.0},
	"battery": {"name": "Батарея", "cost": {"metal": 3, "parts": 3},
		"desc": "запас 20 кВт·ч на ночь", "store_kwh": 20.0},
	"storage": {"name": "Склад", "cost": {"metal": 6, "parts": 1},
		"desc": "+12 ячеек хранения", "slots": 12},
	"drill": {"name": "Автобур", "cost": {"metal": 6, "parts": 4},
		"desc": "добывает то, что под ним; 1.5 кВт", "use_kw": 1.5},
	"processor": {"name": "Переработчик", "cost": {"metal": 5, "parts": 5},
		"desc": "лёд → топливо или кислород; 2 кВт", "use_kw": 2.0},
	"pump": {"name": "Заправочная колонка", "cost": {"metal": 4, "parts": 2},
		"desc": "заправляет ракету, севшую рядом (40 м)", "range": 40.0},
}
const ORDER := ["solar", "battery", "storage", "drill", "processor", "pump"]

const DRILL_RATE := 1.0 / 30.0    ## units per second at richness 1
const PROC_PERIOD := 60.0         ## seconds per product


## A new base anchored at lat/lon (degrees) with the given grid heading.
static func make(body_id: String, lat: float, lon: float, heading_deg: float, t: float) -> Dictionary:
	return {"body": body_id, "lat": lat, "lon": lon, "heading": heading_deg,
		"modules": [], "store": Inventory.new(BASE_SLOTS, "Склад базы").to_data(),
		"energy": 0.0, "t": t, "mode": "fuel", "target": "", "acc": {}, "name": ""}


static func count(base: Dictionary, type: String) -> int:
	var n := 0
	for m in base.modules:
		if m.type == type:
			n += 1
	return n


static func slots(base: Dictionary) -> int:
	return BASE_SLOTS + count(base, "storage") * int(MODULES.storage.slots)


static func battery_kwh(base: Dictionary) -> float:
	# A little buffer even without batteries (capacitors in the modules).
	return 0.5 + count(base, "battery") * float(MODULES.battery.store_kwh)


static func store(base: Dictionary) -> Inventory:
	return Inventory.from_data(base.store, slots(base))


static func set_store(base: Dictionary, inv: Inventory) -> void:
	base.store = inv.to_data()


static func occupied(base: Dictionary, gx: int, gz: int) -> bool:
	for m in base.modules:
		if int(m.x) == gx and int(m.z) == gz:
			return true
	return false


static func add_module(base: Dictionary, type: String, gx: int, gz: int, rot: int) -> void:
	base.modules.append({"type": type, "x": gx, "z": gz, "rot": rot})


# --- Geometry -------------------------------------------------------------------------

## Body-fixed frame of the base: [up, east, south] unit vectors, grid axes
## turned by the heading (x along "east'", z along "south'").
static func frame(base: Dictionary) -> Array:
	var up := CelestialBody.surface_normal(float(base.lat), float(base.lon))
	var east := DVec3.new(0, 1, 0).cross(up)
	if east.length() < 1e-6:
		east = DVec3.new(1, 0, 0)
	east = east.normalized()
	var south := east.cross(up)
	var h := deg_to_rad(float(base.heading))
	var gx := east.mul(cos(h)).add(south.mul(sin(h)))
	var gz := south.mul(cos(h)).sub(east.mul(sin(h)))
	return [up, gx, gz]


## Body-fixed unit direction of a grid cell's centre.
static func cell_dir(base: Dictionary, gx: int, gz: int, radius: float) -> DVec3:
	var f := frame(base)
	var p := (f[0] as DVec3).mul(radius).add((f[1] as DVec3).mul(gx * CELL)).add((f[2] as DVec3).mul(gz * CELL))
	return p.normalized()


## Grid cell nearest to a body-fixed direction (for snapping).
static func cell_of(base: Dictionary, fixed_dir: DVec3, radius: float) -> Vector2i:
	var f := frame(base)
	var d := fixed_dir.normalized().mul(radius)
	return Vector2i(roundi(d.dot(f[1]) / CELL), roundi(d.dot(f[2]) / CELL))


## Distance (m, along the surface, approx.) from a body-fixed direction to the
## nearest module of the base; INF without modules.
static func distance_to(base: Dictionary, fixed_dir: DVec3, radius: float, type := "") -> float:
	var best := INF
	for m in base.modules:
		if type != "" and m.type != type:
			continue
		var c := cell_dir(base, int(m.x), int(m.z), radius)
		best = minf(best, c.sub(fixed_dir.normalized()).length() * radius)
	return best


static func anchor_distance(base: Dictionary, fixed_dir: DVec3, radius: float) -> float:
	return CelestialBody.surface_normal(float(base.lat), float(base.lon)).sub(fixed_dir.normalized()).length() * radius


# --- Simulation -----------------------------------------------------------------------

## Sunlight on a horizontal panel at the base: 0 (night) .. 1 (Sun overhead,
## clear sky).
static func sunlight(base: Dictionary, body: CelestialBody, t: float) -> float:
	var up := body.fixed_to_inertial(CelestialBody.surface_normal(float(base.lat), float(base.lon)), t).to_v3()
	var s := up.dot(SolarSystem.sun_dir(body, t))
	if s <= 0.0:
		return 0.0
	# Air: some loss, more at a low Sun (thick on Venus).
	var air := 1.0
	if body.has_atmosphere():
		air = 0.25 if body.id == "venus" else 0.75
		air *= pow(s, 0.3)
	return pow(s, 0.8) * air


## Power balance right now (kW): generation, load of the running machines.
static func power(base: Dictionary, body: CelestialBody, t: float) -> Dictionary:
	var gen := count(base, "solar") * float(MODULES.solar.gen_kw) * sunlight(base, body, t)
	var load := count(base, "drill") * float(MODULES.drill.use_kw) + count(base, "processor") * float(MODULES.processor.use_kw)
	return {"gen": gen, "load": load}


## Advances the base to time t (catches up after an absence). Returns a short
## report of what it made {item: units}.
static func simulate(base: Dictionary, body: CelestialBody, t: float) -> Dictionary:
	var made := {}
	var t0 := float(base.t)
	if t <= t0:
		return made
	var span := minf(t - t0, MAX_CATCH_UP)
	base.t = t
	if base.modules.is_empty():
		return made
	var inv := store(base)
	var cap := battery_kwh(base)
	var e := clampf(float(base.energy), 0.0, cap)
	var acc: Dictionary = base.acc
	# Each drill pulls the chosen resource at its richness under it.
	var target := drill_target(base, body)
	var drill_rich := 0.0
	for m in base.modules:
		if m.type == "drill":
			var ll := CelestialBody.lat_lon(cell_dir(base, int(m.x), int(m.z), body.radius))
			drill_rich += float(Resources.at(body.id, ll.x, ll.y).get(target, 0.0))
	var n_proc := count(base, "processor")
	# Steps short against the day (sunlight changes), at most ~1500 of them.
	var step := clampf(span / 1500.0, 30.0, 3600.0)
	var n := int(ceil(span / step))
	step = span / maxf(n, 1)
	var ts := t - span
	for i in n:
		var p := power(base, body, ts + (i + 0.5) * step)
		var hours := step / 3600.0
		# Fraction of the step the machines can run on sun + battery.
		var run := 1.0
		if p.load > 0.0:
			var avail: float = e + float(p.gen) * hours
			run = clampf(avail / (float(p.load) * hours), 0.0, 1.0)
		e = clampf(e + (float(p.gen) - float(p.load) * run) * hours, 0.0, cap)
		if run <= 0.0:
			continue
		var secs := step * run
		acc[target] = float(acc.get(target, 0.0)) + DRILL_RATE * secs * drill_rich
		if n_proc > 0:
			acc["proc"] = float(acc.get("proc", 0.0)) + secs * n_proc / PROC_PERIOD
		# Whole units into the store (what does not fit is lost: a full store
		# stops the drill).
		for k in Resources.KINDS:
			var whole := int(floor(float(acc.get(k, 0.0))))
			if whole > 0:
				acc[k] = float(acc[k]) - whole
				var left := inv.add(k, whole)
				made[k] = int(made.get(k, 0)) + whole - left
		var runs := int(floor(float(acc.get("proc", 0.0))))
		if runs > 0:
			acc["proc"] = float(acc["proc"]) - runs
			var rec := _recipe(str(base.mode))
			for r in runs:
				var need := int(rec["in"]["ice"])
				if inv.count("ice") < need:
					break
				var probe := Inventory.from_data(inv.to_data(), inv.size())
				probe.remove("ice", need)
				if probe.add(rec.id, int(rec.out)) > 0:
					break
				inv.remove("ice", need)
				inv.add(rec.id, int(rec.out))
				made[rec.id] = int(made.get(rec.id, 0)) + int(rec.out)
	base.energy = e
	base.acc = acc
	set_store(base, inv)
	return made


## What the drills pull: the player's choice, or the richer of ice and ore here.
static func drill_target(base: Dictionary, body: CelestialBody) -> String:
	var t := str(base.get("target", ""))
	if t in Resources.KINDS:
		return t
	var r := Resources.at(body.id, float(base.lat), float(base.lon))
	return "ice" if float(r.get("ice", 0.0)) >= float(r.get("ore", 0.0)) and float(r.get("ice", 0.0)) > 0.05 else "ore"


static func _recipe(id: String) -> Dictionary:
	for r in Crafting.RECIPES:
		if r.id == id:
			return r
	return Crafting.RECIPES[0]


## Can the cost be paid from these inventories?
static func affordable(type: String, invs: Array) -> bool:
	var cost: Dictionary = MODULES[type].cost
	for id in cost:
		var have := 0
		for inv in invs:
			have += (inv as Inventory).count(id)
		if have < int(cost[id]):
			return false
	return true


static func pay(type: String, invs: Array) -> void:
	var cost: Dictionary = MODULES[type].cost
	for id in cost:
		var need := int(cost[id])
		for inv in invs:
			need -= (inv as Inventory).remove(id, need)
			if need <= 0:
				break


static func cost_text(type: String) -> String:
	var parts := PackedStringArray()
	var cost: Dictionary = MODULES[type].cost
	for id in cost:
		parts.append("%s %d" % [Items.name_of(id), int(cost[id])])
	return ", ".join(parts)
