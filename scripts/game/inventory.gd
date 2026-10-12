class_name Inventory
extends RefCounted
## Slot inventory: `slots` holds {id, n} or null. Each slot carries one item
## type up to its stack size. Mass is the honest sum of what is inside.

signal changed

var title := ""
var slots: Array = []


func _init(n_slots := 12, label := "") -> void:
	title = label
	slots.resize(n_slots)


func size() -> int:
	return slots.size()


## Adds up to n units, filling partial stacks first. Returns what did not fit.
func add(id: String, n: int) -> int:
	if n <= 0 or not Items.exists(id):
		return n
	var cap := Items.stack_of(id)
	for i in slots.size():
		var s = slots[i]
		if s != null and s.id == id and s.n < cap:
			var put := mini(n, cap - int(s.n))
			s.n += put
			n -= put
			if n == 0:
				break
	for i in slots.size():
		if n == 0:
			break
		if slots[i] == null:
			var put := mini(n, cap)
			slots[i] = {"id": id, "n": put}
			n -= put
	changed.emit()
	return n


## Removes up to n units of id. Returns how many were removed.
func remove(id: String, n: int) -> int:
	var taken := 0
	for i in range(slots.size() - 1, -1, -1):
		var s = slots[i]
		if s == null or s.id != id:
			continue
		var t := mini(n - taken, int(s.n))
		s.n -= t
		taken += t
		if s.n <= 0:
			slots[i] = null
		if taken >= n:
			break
	if taken > 0:
		changed.emit()
	return taken


func count(id: String) -> int:
	var c := 0
	for s in slots:
		if s != null and s.id == id:
			c += int(s.n)
	return c


func mass() -> float:
	var m := 0.0
	for s in slots:
		if s != null:
			m += Items.mass_of(s.id) * float(s.n)
	return m


func used() -> int:
	var c := 0
	for s in slots:
		if s != null:
			c += 1
	return c


## Moves the stack in slot i into `other` (as much as fits). Returns units moved.
func move_slot_to(i: int, other: Inventory) -> int:
	var s = slots[i]
	if s == null:
		return 0
	var left := other.add(s.id, int(s.n))
	var moved := int(s.n) - left
	if left == 0:
		slots[i] = null
	else:
		s.n = left
	if moved > 0:
		changed.emit()
	return moved


func to_data() -> Dictionary:
	var arr: Array = []
	for s in slots:
		arr.append(null if s == null else {"id": s.id, "n": int(s.n)})
	return {"title": title, "slots": arr}


static func from_data(d: Dictionary, fallback_size := 12) -> Inventory:
	var src: Array = d.get("slots", [])
	var inv := Inventory.new(maxi(src.size(), fallback_size), str(d.get("title", "")))
	for i in src.size():
		var s = src[i]
		if s is Dictionary and Items.exists(str(s.get("id", ""))) and int(s.get("n", 0)) > 0:
			inv.slots[i] = {"id": str(s.id), "n": int(s.n)}
	return inv
