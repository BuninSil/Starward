class_name Crafting
extends RefCounted
## Recipes (turn resources into products) and the two ways products go back into
## the ship: propellant into the tanks, oxygen into the suit.

const RECIPES := [
	{"id": "oxygen", "name": "Кислород", "out": 1, "in": {"ice": 10}, "hint": "электролиз льда"},
	{"id": "fuel", "name": "Топливо", "out": 1, "in": {"ice": 20}, "hint": "лёд → метан и кислород"},
	{"id": "metal", "name": "Металл", "out": 1, "in": {"ore": 10}, "hint": "плавка руды"},
	{"id": "parts", "name": "Детали", "out": 1, "in": {"metal": 2}, "hint": "станок"},
]

const FUEL_PER_UNIT := 10.0      ## kg of propellant in one "fuel" item
const O2_PER_UNIT := 600.0       ## seconds of breathing in one "oxygen" item


## How many of each input are available across the given inventories.
static func _have(invs: Array, id: String) -> int:
	var c := 0
	for inv in invs:
		c += (inv as Inventory).count(id)
	return c


static func can_craft(recipe: Dictionary, invs: Array) -> bool:
	for id in recipe["in"]:
		if _have(invs, id) < int(recipe["in"][id]):
			return false
	return true


## Takes the inputs (ship first, then suit) and puts the product in `dest`.
## Returns "" or why it failed.
static func craft(recipe: Dictionary, invs: Array, dest: Inventory) -> String:
	if not can_craft(recipe, invs):
		return "Не хватает сырья"
	var probe := Inventory.from_data(dest.to_data(), dest.size())
	if probe.add(recipe.id, int(recipe.out)) > 0:
		return "Нет места в грузе"
	for id in recipe["in"]:
		var need := int(recipe["in"][id])
		for inv in invs:
			need -= (inv as Inventory).remove(id, need)
			if need <= 0:
				break
	dest.add(recipe.id, int(recipe.out))
	return ""


## Pours fuel items into the stages with engines, bottom (active) stage first.
## Returns kg added.
static func refuel(v: Vessel, invs: Array) -> float:
	var added := 0.0
	for i in range(v.stages.size() - 1, -1, -1):
		var s: Dictionary = v.stages[i]
		if not s.get("has_engine", false):
			continue
		while float(s.fuel_max) - float(s.fuel) >= FUEL_PER_UNIT * 0.5 and _have(invs, "fuel") > 0:
			for inv in invs:
				if (inv as Inventory).remove("fuel", 1) == 1:
					break
			var put := minf(FUEL_PER_UNIT, float(s.fuel_max) - float(s.fuel))
			s.fuel = float(s.fuel) + put
			added += put
	return added
