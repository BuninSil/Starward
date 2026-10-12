class_name Items
extends RefCounted
## Item registry: everything that can lie in an inventory slot. Mass is per
## unit (kg), `stack` is how many units fit in one slot. Colours are the slot
## icons until real icons exist. Resources by body and crafting come in 6b.

const DEFS := {
	"ice": {"name": "Лёд", "mass": 1.0, "stack": 250, "color": Color(0.7, 0.88, 1.0), "kind": "resource"},
	"ore": {"name": "Руда", "mass": 1.0, "stack": 250, "color": Color(0.62, 0.45, 0.36), "kind": "resource"},
	"regolith": {"name": "Реголит", "mass": 1.0, "stack": 250, "color": Color(0.6, 0.6, 0.58), "kind": "resource"},
	"fuel": {"name": "Топливо", "mass": 10.0, "stack": 100, "color": Color(1.0, 0.62, 0.22), "kind": "product"},
	"oxygen": {"name": "Кислород", "mass": 5.0, "stack": 20, "color": Color(0.45, 0.9, 0.6), "kind": "product"},
	"metal": {"name": "Металл", "mass": 5.0, "stack": 50, "color": Color(0.78, 0.8, 0.84), "kind": "product"},
	"parts": {"name": "Детали", "mass": 2.0, "stack": 50, "color": Color(0.95, 0.85, 0.35), "kind": "product"},
	"sample": {"name": "Образец грунта", "mass": 0.5, "stack": 10, "color": Color(0.85, 0.55, 0.85), "kind": "science"},
}


static func exists(id: String) -> bool:
	return DEFS.has(id)


static func name_of(id: String) -> String:
	return str(DEFS.get(id, {}).get("name", id))


static func mass_of(id: String) -> float:
	return float(DEFS.get(id, {}).get("mass", 0.0))


static func stack_of(id: String) -> int:
	return int(DEFS.get(id, {}).get("stack", 1))


static func color_of(id: String) -> Color:
	return DEFS.get(id, {}).get("color", Color.WHITE)
