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
var flat_spots: Array = []   ## [[fixed_normal: DVec3, radius_m: float]] forced to height 0 (pads)


static func load_for(id: String, detail_m: float, seed_v: int) -> Terrain:
	var t := Terrain.new()
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


## Height above the reference radius (game metres) for a body-fixed unit vector.
## Oceans (negative) are treated as the sea surface for bodies with atmosphere.
func height_at(n: DVec3, radius: float, ocean := true) -> float:
	var r := n.length()
	var lat := rad_to_deg(asin(clampf(n.y / r, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(-n.z, n.x))
	var h := map_height(lat, lon)
	if detail_amp > 0.0:
		# Detail in metres along the surface; fades out under the sea.
		var p := n.mul(radius / r)
		var d := _noise.get_noise_3d(p.x, p.y, p.z) * detail_amp
		h += d * clampf(h / 50.0 + 0.5, 0.0, 1.0) if ocean else d
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
