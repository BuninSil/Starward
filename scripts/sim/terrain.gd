class_name Terrain
extends RefCounted
## Surface height of a body: global map (NASA, assets/planets/<id>_height.bin,
## int16 metres at real scale, equirectangular) + small procedural detail, all
## divided by the game scale. Pure data: safe on worker threads and in tests.

var width := 0
var height := 0
var scale_div := 10.0
var _data := PackedByteArray()
var _noise := FastNoiseLite.new()
var detail_amp := 0.0        ## game metres of procedural detail
var has_ocean := false       ## negative heights are sea: the surface is clamped to 0
var flat_spots: Array = []   ## [[fixed_normal: DVec3, radius_m: float, height]] forced flat (pads)
var _craters: Array = []     ## [[dist_noise, value_noise, cell_m, depth_ratio]] small procedural craters
var _hills: FastNoiseLite = null   ## ridged hills / ridges (visual relief near the ground)
var hills_amp := 0.0
var _field: Array = []       ## crater field layers: [cell_m, fill, seed, rot rows (3 DVec3)]


static func load_for(id: String, detail_m: float, seed_v: int, ocean := false) -> Terrain:
	var t := Terrain.new()
	t.has_ocean = ocean
	t.detail_amp = detail_m
	t._noise.seed = seed_v
	t._noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	t._noise.fractal_octaves = 5
	t._noise.frequency = 1.0 / 2500.0   # in game metres
	var meta_path := "res://assets/planets/%s.json" % id
	if not FileAccess.file_exists(meta_path):
		return t   # flat body (maps not fetched yet)
	var meta = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	if typeof(meta) != TYPE_DICTIONARY:
		return t
	t.width = int(meta.width)
	t.height = int(meta.height)
	t.scale_div = float(meta.get("scale_div", 10.0))
	t._data = FileAccess.get_file_as_bytes("res://assets/planets/%s_height.bin" % id)
	if t._data.size() != t.width * t.height * 2:
		t.width = 0
		t._data = PackedByteArray()
	return t


func has_map() -> bool:
	return width > 0


## Raw map height (game metres) at lat/lon degrees, bilinear.
func map_height(lat: float, lon: float) -> float:
	if width == 0:
		return 0.0
	var fx := (lon + 180.0) / 360.0 * width - 0.5
	var fy := (90.0 - lat) / 180.0 * height - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - x0
	var ty := fy - y0
	var h00 := _px(x0, y0)
	var h10 := _px(x0 + 1, y0)
	var h01 := _px(x0, y0 + 1)
	var h11 := _px(x0 + 1, y0 + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), ty) / scale_div


func _px(x: int, y: int) -> float:
	x = posmod(x, width)
	y = clampi(y, 0, height - 1)
	return float(_data.decode_s16((y * width + x) * 2))


## Ridged hills of `amp` game metres with ~`wavelength` m spacing.
func set_hills(amp: float, wavelength: float, seed_v: int) -> void:
	_hills = FastNoiseLite.new()
	_hills.seed = seed_v
	_hills.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_hills.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_hills.fractal_octaves = 4
	_hills.frequency = 1.0 / wavelength
	hills_amp = amp


## Adds a layer of small bowl craters with rims (airless bodies): one possible
## crater per cell of `cell_m` game metres, ~30% of cells stay empty.
func add_crater_layer(cell_m: float, depth_ratio: float, seed_v: int) -> void:
	var d := FastNoiseLite.new()
	d.noise_type = FastNoiseLite.TYPE_CELLULAR
	d.fractal_type = FastNoiseLite.FRACTAL_NONE
	d.frequency = 1.0 / cell_m
	d.seed = seed_v
	d.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	d.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	var v: FastNoiseLite = d.duplicate()
	v.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	_craters.append([d, v, cell_m, depth_ratio])


func _crater_height(p: DVec3) -> float:
	var h := 0.0
	for c in _craters:
		var val: float = (c[1] as FastNoiseLite).get_noise_3d(p.x, p.y, p.z)
		if val < -0.4:
			continue
		var f1: float = (c[0] as FastNoiseLite).get_noise_3d(p.x, p.y, p.z) + 1.0   # cell units
		var rc := lerpf(0.16, 0.42, (val + 0.4) / 1.4)
		var x := f1 / rc
		if x > 1.8:
			continue
		var depth: float = c[3] * 2.0 * rc * c[2]
		if x < 1.0:
			h -= depth * (1.0 - x * x)
		h += depth * 0.35 * exp(-pow((x - 1.0) / 0.28, 2.0))
	return h


## Crater field (airless bodies): layers of hashed 3D cells, one possible crater
## per cell, with a known centre, radius and age. Layers = [[cell_m, fill], ...]
## from big to small; the same areal fill per layer gives a power law (many
## small, few big). Old craters are shallow and rounded, young ones (~12 %)
## deep and sharp, with a bright ejecta blanket and rays (surface_marks()).
## A crater's whole footprint (rays included) stays within 0.5 cell of its
## centre, so a point only needs the 2×2×2 nearest cells per layer.
func set_crater_field(layers: Array, seed_v: int) -> void:
	_field.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	for i in layers.size():
		# Random rotation per layer, so cell grids never line up.
		var q := Quaternion(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized(),
			rng.randf() * TAU)
		var bs := Basis(q)
		var cell := float(layers[i][0])
		# [cell, fill (0..1023), seed, then the rotation rows pre-divided by cell]
		_field.append([cell, int(float(layers[i][1]) * 1024.0), seed_v * 31 + i * 7919,
			bs.x.x / cell, bs.x.y / cell, bs.x.z / cell,
			bs.y.x / cell, bs.y.y / cell, bs.y.z / cell,
			bs.z.x / cell, bs.z.y / cell, bs.z.z / cell])


## Height (x = 0) and marks (x = 1: [ejecta brightness, rockiness]) of the field.
## Hot path (every terrain query): one inline 64-bit hash per cell, its bit
## fields give presence, age, radius and centre.
func _field_eval(p: DVec3, want_marks: bool) -> Array:
	var h := 0.0
	var bright := 0.0
	var rocky := 0.0
	var px := p.x
	var py := p.y
	var pz := p.z
	for L in _field:
		var lx: float = L[3] * px + L[4] * py + L[5] * pz
		var ly: float = L[6] * px + L[7] * py + L[8] * pz
		var lz: float = L[9] * px + L[10] * py + L[11] * pz
		var fill: int = L[1]
		var sd: int = L[2]
		var bx := floori(lx - 0.5)
		var by := floori(ly - 0.5)
		var bz := floori(lz - 0.5)
		for c in 8:
			var cx := bx + (c & 1)
			var cy := by + ((c >> 1) & 1)
			var cz := bz + (c >> 2)
			var hc := (cx * 73856093) ^ (cy * 19349663) ^ (cz * 83492791) ^ sd
			hc = ((hc >> 16) ^ hc) * 0x45d9f3b
			hc = ((hc >> 16) ^ hc) * 0x45d9f3b
			hc = (hc >> 16) ^ hc
			if (hc & 1023) >= fill:
				continue
			var ox := float(cx) + float((hc >> 30) & 1023) / 1024.0 - lx
			var oy := float(cy) + float((hc >> 40) & 1023) / 1024.0 - ly
			var oz := float(cz) + float((hc >> 50) & 1023) / 1024.0 - lz
			var d2 := ox * ox + oy * oy + oz * oz
			if d2 > 0.25:
				continue   # nothing reaches beyond half a cell
			var age := float((hc >> 10) & 1023) / 1024.0
			var ur := float((hc >> 20) & 1023) / 1024.0
			var young := age < 0.12
			# Radius in cells; young craters smaller so their rays fit the cell.
			var rr := (0.05 + 0.09 * ur) if young else (0.08 + 0.23 * ur * sqrt(ur))
			var x := sqrt(d2) / rr
			if x > (3.5 if young else 1.6):
				continue
			var r_m := rr * float(L[0])
			if young:
				var depth := 0.42 * r_m
				if x < 1.0:
					h -= depth * (1.0 - x * x)
				h += depth * 0.32 * exp(-pow((x - 1.0) / 0.16, 2.0))
				if x > 1.0:
					h += depth * 0.1 * exp(-(x - 1.0) * 2.5) * (1.0 - smoothstep(2.0, 3.5, x))
			else:
				var fresh := 1.0 - age   # 1 = recent, 0 = ancient (nearly erased)
				var depth2 := r_m * (0.1 + 0.3 * fresh)
				if x < 1.0:
					var b := 1.0 - x * x
					h -= depth2 * b * b * (3.0 - 2.0 * b) * 0.9
				h += depth2 * (0.12 + 0.18 * fresh) * exp(-pow((x - 1.0) / (0.4 - 0.2 * fresh), 2.0)) \
					* (1.0 - smoothstep(1.3, 1.6, x))
			if want_marks:
				if young:
					var k := 1.0 - age / 0.12
					if x > 0.7:
						var blanket := exp(-(x - 1.0) * 2.2) if x > 1.0 else 1.0
						# Rays: angle around the centre in a tangent frame of the crater.
						var cn := p.normalized()
						var t1 := cn.cross(DVec3.new(0, 1, 0) if absf(cn.y) < 0.9 else DVec3.new(1, 0, 0)).normalized()
						var t2 := cn.cross(t1)
						# Offset back in body axes (the rows are orthonormal / cell).
						var c2: float = L[0] * L[0]
						var off := DVec3.new((L[3] * ox + L[6] * oy + L[9] * oz) * c2,
							(L[4] * ox + L[7] * oy + L[10] * oz) * c2, (L[5] * ox + L[8] * oy + L[11] * oz) * c2)
						var ang := atan2(off.dot(t2), off.dot(t1))
						var h2 := ((hc >> 7) ^ hc) * 0x2545f491
						var nr := 5.0 + float(h2 & 7)
						var ph1 := float((h2 >> 8) & 1023) / 1024.0 * TAU
						var ph2 := float((h2 >> 18) & 1023) / 1024.0 * TAU
						var ray := pow(maxf(0.0, cos(ang * nr + ph1) * 0.6 + cos(ang * (nr * 2.0 + 1.0) + ph2) * 0.4), 3.0)
						bright = maxf(bright, k * (blanket * 0.8 + ray * exp(-(x - 1.0) * 0.6) * 0.9 * smoothstep(0.9, 1.3, x))
							* (1.0 - smoothstep(2.6, 3.5, x)))
					rocky = maxf(rocky, k * exp(-pow((x - 1.0) / 0.35, 2.0)))
				else:
					rocky = maxf(rocky, (1.0 - age) * 0.5 * exp(-pow((x - 0.85) / 0.3, 2.0)))
	return [h, bright, rocky]


func has_crater_field() -> bool:
	return not _field.is_empty()


## Ejecta brightness (bright blankets and rays of young craters) and rockiness
## (crater walls and rims) at a body-fixed unit vector, 0..1 each.
func surface_marks(n: DVec3, radius: float) -> Vector2:
	if _field.is_empty():
		return Vector2.ZERO
	var e := _field_eval(n.mul(radius / n.length()), true)
	return Vector2(clampf(e[1], 0.0, 1.0), clampf(e[2], 0.0, 1.0))


## Coarse height for the far globe mesh: map only (no detail, no pads), sunk by
## the deepest procedural detail so it never pokes through the ground patch.
func globe_height(lat: float, lon: float) -> float:
	var h := map_height(lat, lon)
	return (maxf(h, 0.0) if has_ocean else h) - detail_depth()


## Deepest procedural detail below the map surface (noise + craters), game metres.
func detail_depth() -> float:
	var d := detail_amp
	for c in _craters:
		d += float(c[3]) * 2.0 * 0.42 * float(c[2])
	for L in _field:
		d += 0.28 * 0.31 * float(L[0])
	return d


## Height above the reference radius (game metres) for a body-fixed unit vector.
## On bodies with oceans negative heights are the sea surface (0).
func height_at(n: DVec3, radius: float) -> float:
	var ocean := has_ocean
	var r := n.length()
	var lat := rad_to_deg(asin(clampf(n.y / r, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(-n.z, n.x))
	var h := map_height(lat, lon)
	if detail_amp > 0.0:
		# Detail in metres along the surface; fades out under the sea.
		var p := n.mul(radius / r)
		var d := _noise.get_noise_3d(p.x, p.y, p.z) * detail_amp
		h += d * clampf(h / 50.0 + 0.5, 0.0, 1.0) if ocean else d
	if not _craters.is_empty():
		h += _crater_height(n.mul(radius / r))
	if not _field.is_empty():
		h += float(_field_eval(n.mul(radius / r), false)[0])
	if _hills != null:
		var q := n.mul(radius / r)
		h += (_hills.get_noise_3d(q.x, q.y, q.z) * 0.5 + 0.5) * hills_amp
	if ocean:
		h = maxf(h, 0.0)
	for f in flat_spots:
		var fn: DVec3 = f[0]
		var dist := acos(clampf(fn.dot(n) / r, -1.0, 1.0)) * radius
		var rad: float = f[1]
		if dist < rad * 2.0:
			var w := clampf((dist - rad) / rad, 0.0, 1.0)
			h = lerpf(f[2], h, w * w * (3.0 - 2.0 * w))
	return h


## Height at the flat spot centre is fixed to the terrain there (so pads sit on the map).
func add_flat_spot(n: DVec3, radius_m: float, body_radius: float) -> void:
	var h := height_at(n, body_radius)
	flat_spots.append([n.normalized(), radius_m, h])
