class_name ShipModel
extends RefCounted
## Procedural model of the ship «Стриж» (Elite Dangerous style craft), clean
## SFS/KSP look like the rockets. Frame of the vessel: +Y up (it lands on its
## belly), -Z forward, origin on the ground under the gear. Returns the engine
## exhausts as [position, radius] (they fire along +Z).

const WHITE := Color(0.82, 0.83, 0.84)
const GREY := Color(0.33, 0.34, 0.37)
const DARK := Color(0.1, 0.1, 0.11)
const ORANGE := Color(0.95, 0.48, 0.1)
const GLASS := Color(0.05, 0.08, 0.12)
const GEAR_H := 1.1     ## belly height above the ground
const AXIS_Y := GEAR_H + 0.75   ## fuselage axis height
const COCKPIT_HOLE := [2, 4, 7] ## fuselage quads cut away under the canopy (z -5.5..-2, 60°..120°)
const CANOPY_HINGE := Vector3(0, AXIS_Y + 0.62, -2.2)


static func _mat(c: Color, metal := 0.1, rough := 0.45, emit := Color.BLACK) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	if emit != Color.BLACK:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = 2.0
	return m


static func _mesh(p: Node3D, mesh: Mesh, mat: Material, pos := Vector3.ZERO, basis := Basis()) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(basis, pos)
	p.add_child(mi)
	return mi


## Flat plate from a polygon in the XZ plane (convex or simple), thickness t,
## bevelled edge look from slightly smaller top/bottom faces.
static func _plate(poly: PackedVector2Array, t: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := poly.size()
	var idx := Geometry2D.triangulate_polygon(poly)
	for side in [1.0, -1.0]:
		st.set_normal(Vector3(0, side, 0))
		for k in range(0, idx.size(), 3):
			var order := [idx[k], idx[k + 1], idx[k + 2]] if side < 0.0 else [idx[k], idx[k + 2], idx[k + 1]]
			for j in order:
				st.add_vertex(Vector3(poly[j].x, side * t * 0.5, poly[j].y))
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var e := (b - a).normalized()
		var nrm := Vector3(e.y, 0, -e.x)
		var c := (a + b) * 0.5
		var centre := Vector2.ZERO
		for q in poly:
			centre += q
		centre /= n
		if Vector2(nrm.x, nrm.z).dot(c - centre) < 0.0:
			nrm = -nrm
		var quad := [Vector3(a.x, t * 0.5, a.y), Vector3(b.x, t * 0.5, b.y), Vector3(b.x, -t * 0.5, b.y), Vector3(a.x, -t * 0.5, a.y)]
		st.set_normal(nrm)
		var tri := [0, 1, 2, 0, 2, 3] if nrm.cross(quad[1] - quad[0]).dot(quad[3] - quad[0]) < 0.0 else [0, 2, 1, 0, 3, 2]
		for j in tri:
			st.add_vertex(quad[j])
	return st.commit()


## A body of revolution along Z from a profile [(z, r), ...] (front to back).
## hole = [profile index, first k, last k]: quads left out (the cockpit opening).
static func _lathe_z(profile: Array, segs := 20, squash := 1.0, hole := [-1, 0, 0]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in profile.size() - 1:
		var p0: Vector2 = profile[i]
		var p1: Vector2 = profile[i + 1]
		for k in segs:
			if i == hole[0] and k >= hole[1] and k <= hole[2]:
				continue
			var a0 := TAU * k / segs
			var a1 := TAU * (k + 1) / segs
			var v := [
				Vector3(cos(a0) * p0.y, sin(a0) * p0.y * squash, p0.x),
				Vector3(cos(a1) * p0.y, sin(a1) * p0.y * squash, p0.x),
				Vector3(cos(a1) * p1.y, sin(a1) * p1.y * squash, p1.x),
				Vector3(cos(a0) * p1.y, sin(a0) * p1.y * squash, p1.x),
			]
			for j in [0, 2, 1, 0, 3, 2]:
				var q: Vector3 = v[j]
				st.set_normal(Vector3(q.x, q.y / maxf(squash * squash, 0.01), 0).normalized())
				st.add_vertex(q)
	st.generate_normals()
	return st.commit()


static func build(root: Node3D) -> Array:
	var hull := _mat(WHITE, 0.15, 0.4)
	var grey := _mat(GREY, 0.6, 0.4)
	var dark := _mat(DARK, 0.4, 0.5)
	var orange := _mat(ORANGE, 0.0, 0.5)
	var y := AXIS_Y
	# Fuselage: pointed nose to a wide, slightly flattened body.
	var body := _lathe_z([Vector2(-8.5, 0.0), Vector2(-7.6, 0.45), Vector2(-5.5, 1.05), Vector2(-2.0, 1.35),
		Vector2(3.5, 1.35), Vector2(6.0, 1.15), Vector2(6.6, 0.9)], 24, 0.62, COCKPIT_HOLE)
	_mesh(root, body, hull, Vector3(0, y, 0))
	# Orange stripe band and dark belly panel.
	_mesh(root, _lathe_z([Vector2(-4.2, 1.27), Vector2(-3.6, 1.32)], 24, 0.63, [0, 4, 7]), orange, Vector3(0, y, 0))
	_mesh(root, _plate(PackedVector2Array([Vector2(-0.9, -5.5), Vector2(0.9, -5.5), Vector2(1.1, 5.8), Vector2(-1.1, 5.8)]), 0.08), dark,
		Vector3(0, y - 0.82, 0))
	# Swept wings with orange tips.
	var wing := PackedVector2Array([Vector2(1.2, -1.5), Vector2(6.0, 3.0), Vector2(6.2, 4.6), Vector2(1.2, 4.2)])
	for sx in [-1.0, 1.0]:
		var poly := PackedVector2Array()
		for q in wing:
			poly.append(Vector2(q.x * sx, q.y))
		if sx < 0.0:
			poly.reverse()
		_mesh(root, _plate(poly, 0.22), hull, Vector3(0, y - 0.25, 0))
		var tip := PackedVector2Array([Vector2(5.4 * sx, 2.4), Vector2(6.25 * sx, 3.1), Vector2(6.3 * sx, 4.6), Vector2(5.5 * sx, 4.5)])
		if sx < 0.0:
			tip.reverse()
		_mesh(root, _plate(tip, 0.24), orange, Vector3(0, y - 0.25, 0))
		# Tail fin.
		var fin := PackedVector2Array([Vector2(0.0, 2.8), Vector2(1.6, 5.0), Vector2(1.7, 6.2), Vector2(0.0, 6.0)])
		_mesh(root, _plate(fin, 0.16), hull, Vector3(sx * 1.6, y + 0.5, 0), Basis(Vector3.FORWARD, sx * deg_to_rad(-70.0)))
	# Engine nacelles with nozzles at the back.
	var exhausts := []
	for sx in [-1.0, 1.0]:
		var nac := _lathe_z([Vector2(1.0, 0.0), Vector2(1.6, 0.55), Vector2(6.4, 0.62), Vector2(7.0, 0.55)], 16)
		_mesh(root, nac, grey, Vector3(sx * 2.0, y - 0.1, 0))
		var noz := _lathe_z([Vector2(7.0, 0.5), Vector2(7.8, 0.62), Vector2(7.85, 0.6)], 16)
		_mesh(root, noz, dark, Vector3(sx * 2.0, y - 0.1, 0))
		var glow := CylinderMesh.new()
		glow.top_radius = 0.45
		glow.bottom_radius = 0.45
		glow.height = 0.05
		_mesh(root, glow, _mat(DARK, 0.0, 0.5, Color(1.0, 0.45, 0.15) * 0.3), Vector3(sx * 2.0, y - 0.1, 7.7),
			Basis(Vector3.RIGHT, PI * 0.5))
		exhausts.append([Vector3(sx * 2.0, y - 0.1, 7.85), 0.55])
	# Navigation lights on the wing tips (red left, green right) and a white tail light.
	for l in [[Vector3(-6.25, y - 0.2, 4.0), Color(1, 0.1, 0.1)], [Vector3(6.25, y - 0.2, 4.0), Color(0.1, 1, 0.2)],
			[Vector3(0, y + 0.9, 6.4), Color(1, 1, 1)]]:
		var s := SphereMesh.new()
		s.radius = 0.09
		s.height = 0.18
		_mesh(root, s, _mat(DARK, 0.0, 0.3, l[1]), l[0])
	# Dark gear bays under the nose and the nacelles.
	for b in [[Vector3(0, GEAR_H + 0.02, -4.3), Vector2(0.55, 1.7)], [Vector3(-2.0, GEAR_H + 0.12, 3.3), Vector2(0.6, 1.7)],
			[Vector3(2.0, GEAR_H + 0.12, 3.3), Vector2(0.6, 1.7)]]:
		var h: Vector2 = b[1] * 0.5
		_mesh(root, _plate(PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]), 0.04),
			_mat(Color(0.02, 0.02, 0.022), 0.2, 0.8), b[0])
	return exhausts


## Cockpit canopy on a hinge at its back edge (opens front up, like a
## fighter's). Returns the pivot.
static func build_canopy(root: Node3D) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = "Canopy"
	pivot.position = CANOPY_HINGE
	root.add_child(pivot)
	var canopy := _lathe_z([Vector2(-6.3, 0.0), Vector2(-5.6, 0.45), Vector2(-4.2, 0.62), Vector2(-2.8, 0.5), Vector2(-2.2, 0.0)], 16, 0.7)
	var glass := _mat(GLASS, 0.6, 0.08)
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED   # seen from below when open
	_mesh(pivot, canopy, glass, Vector3(0, 0, -CANOPY_HINGE.z))
	var rim := _lathe_z([Vector2(-6.25, 0.08), Vector2(-5.6, 0.5), Vector2(-4.2, 0.67), Vector2(-2.8, 0.55), Vector2(-2.25, 0.08)], 16, 0.12)
	_mesh(pivot, rim, _mat(GREY, 0.6, 0.4), Vector3(0, -0.02, -CANOPY_HINGE.z))
	return pivot


## Cockpit tub under the canopy (seen only with it open): walls, floor, seat,
## console with lit screens, stick, a lamp.
static func build_cockpit(root: Node3D) -> Node3D:
	var cab := Node3D.new()
	cab.name = "Cockpit"
	root.add_child(cab)
	var wall := _mat(Color(0.5, 0.52, 0.55), 0.1, 0.8)
	wall.cull_mode = BaseMaterial3D.CULL_DISABLED
	var y0 := AXIS_Y - 0.25
	var y1 := AXIS_Y + 0.72
	var z0 := -5.5
	var z1 := -2.0
	var w := 0.56
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := [
		[Vector3(-w, y0, z0), Vector3(w, y0, z0), Vector3(w, y0, z1), Vector3(-w, y0, z1)],   # floor
		[Vector3(-w, y0, z0), Vector3(-w, y1, z0), Vector3(-w, y1, z1), Vector3(-w, y0, z1)],  # left
		[Vector3(w, y0, z0), Vector3(w, y1, z0), Vector3(w, y1, z1), Vector3(w, y0, z1)],      # right
		[Vector3(-w, y0, z0), Vector3(-w, y1 - 0.15, z0), Vector3(w, y1 - 0.15, z0), Vector3(w, y0, z0)],  # front
		[Vector3(-w, y0, z1), Vector3(-w, y1, z1), Vector3(w, y1, z1), Vector3(w, y0, z1)],    # back
	]
	for q in quads:
		var n: Vector3 = (q[1] - q[0]).cross(q[3] - q[0]).normalized()
		st.set_normal(n)
		for i in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(q[i])
	_mesh(cab, st.commit(), wall)
	var fabric := _mat(Color(0.2, 0.24, 0.32), 0.0, 0.9)
	var seat_back := BoxMesh.new()
	seat_back.size = Vector3(0.62, 0.95, 0.14)
	_mesh(cab, seat_back, fabric, Vector3(0, y0 + 0.62, -2.55), Basis(Vector3.RIGHT, deg_to_rad(-15.0)))
	var seat_pan := BoxMesh.new()
	seat_pan.size = Vector3(0.62, 0.14, 0.6)
	_mesh(cab, seat_pan, fabric, Vector3(0, y0 + 0.28, -2.9))
	var head := BoxMesh.new()
	head.size = Vector3(0.36, 0.26, 0.12)
	_mesh(cab, head, _mat(ORANGE, 0.0, 0.6), Vector3(0, y0 + 1.15, -2.45), Basis(Vector3.RIGHT, deg_to_rad(-15.0)))
	var stick := CylinderMesh.new()
	stick.top_radius = 0.025
	stick.bottom_radius = 0.035
	stick.height = 0.4
	_mesh(cab, stick, _mat(DARK, 0.3, 0.5), Vector3(0, y0 + 0.3, -3.45))
	# Console under the front of the canopy, facing the seat.
	var console := Node3D.new()
	console.position = Vector3(0, y0 + 0.55, -4.25)
	console.rotation.x = deg_to_rad(-40.0)
	cab.add_child(console)
	var board := BoxMesh.new()
	board.size = Vector3(1.0, 0.5, 0.08)
	_mesh(console, board, _mat(Color(0.08, 0.08, 0.09), 0.2, 0.6))
	for sc in [[-0.3, Color(0.25, 0.75, 1.0)], [0.0, Color(1.0, 0.55, 0.15)], [0.3, Color(0.25, 0.75, 1.0)]]:
		var q := BoxMesh.new()
		q.size = Vector3(0.26, 0.2, 0.01)
		_mesh(console, q, _mat(Color(0.02, 0.02, 0.03), 0.0, 0.3, sc[1] * 0.5), Vector3(float(sc[0]), 0.06, 0.045))
	for k in 7:
		var b := BoxMesh.new()
		b.size = Vector3(0.05, 0.03, 0.02)
		_mesh(console, b, _mat(DARK, 0.0, 0.4, (ORANGE if k % 2 == 0 else Color(0.8, 0.9, 1.0)) * 0.3), Vector3(-0.36 + k * 0.12, -0.17, 0.045))
	var lamp := OmniLight3D.new()
	lamp.light_color = Color(0.75, 0.85, 1.0)
	lamp.light_energy = 1.4
	lamp.omni_range = 3.0
	lamp.position = Vector3(0, y0 + 0.9, -3.8)
	cab.add_child(lamp)
	cab.visible = false
	return cab


## Landing gear (kept apart from the merged hull: it moves). A leg: pivot at
## the bay (folds backwards about X into the hull), a fixed oleo sleeve and a
## sliding piston with the pad (shock absorber). Returns
## [{pivot, slide, axis, angle}] for rocket_view's gear animation.
static func build_gear(root: Node3D) -> Array:
	var grey := _mat(GREY, 0.6, 0.4)
	var dark := _mat(DARK, 0.4, 0.5)
	var steel := _mat(Color(0.75, 0.76, 0.78), 0.8, 0.25)
	var out := []
	for g in [Vector3(0, 0, -5.0), Vector3(-2.0, 0, 2.6), Vector3(2.0, 0, 2.6)]:
		var top := GEAR_H + 0.35
		var pivot := Node3D.new()
		pivot.position = g + Vector3(0, top, 0)
		root.add_child(pivot)
		var sleeve := CylinderMesh.new()
		sleeve.top_radius = 0.17
		sleeve.bottom_radius = 0.17
		sleeve.height = 0.6
		sleeve.radial_segments = 10
		_mesh(pivot, sleeve, grey, Vector3(0, -0.3, 0))
		var slide := Node3D.new()
		pivot.add_child(slide)
		var rod := CylinderMesh.new()
		rod.top_radius = 0.1
		rod.bottom_radius = 0.1
		rod.height = top - 0.1
		rod.radial_segments = 8
		_mesh(slide, rod, steel, Vector3(0, -(top - 0.1) * 0.5 - 0.1, 0))
		var pad := CylinderMesh.new()
		pad.top_radius = 0.36
		pad.bottom_radius = 0.42
		pad.height = 0.14
		pad.radial_segments = 12
		_mesh(slide, pad, dark, Vector3(0, -top + 0.07, 0))
		# Folds backwards (+Z): the leg lies along the hull in its bay.
		out.append({"pivot": pivot, "slide": slide, "axis": Vector3.RIGHT, "angle": -PI * 0.5, "base": Basis()})
	return out
