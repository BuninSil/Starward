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
