extends Node
## High-resolution colour tiles for the ground near the vessel. Tiles are published
## as GitHub prereleases `maps-<id>-v1` (tools/build_tiles.py) and downloaded on
## demand, cached in user://tiles/<id>/. Offline or missing tiles: nothing happens
## and the ground keeps the global map. One 2×2 block (≈ 70–250 km) at a time.

signal tiles_ready(body: CelestialBody, texture: Texture2D, rect: Rect2)

const BASE_URL := "https://github.com/BuninSil/Starward/releases/download/maps-%s-v1/%s"
const BODIES := ["earth", "moon", "mars", "mercury", "venus"]

var _http: HTTPRequest
var _queue: Array[String] = []          ## file names to fetch for the current request
var _body: CelestialBody = null
var _block := Vector3i(-1, -1, -1)      ## (x0, y0, body hash) of the block in use / in flight
var _meta := {}                         ## id -> tiles.json dictionary
var _busy := false
var _failed := {}                       ## id -> true when the tile set is unreachable


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	add_child(_http)
	_http.request_completed.connect(_on_done)


## Called every few frames with the vessel's body-fixed direction while low.
func want(body: CelestialBody, fixed_dir: DVec3) -> void:
	if not body.id in BODIES or _failed.has(body.id):
		return
	if not _meta.has(body.id):
		if not _busy:
			_body = body
			_fetch_meta(body.id)
		return
	var m: Dictionary = _meta[body.id]
	var ll := CelestialBody.lat_lon(fixed_dir)
	var u := (ll.y + 180.0) / 360.0 * float(m.cols)
	var v := (90.0 - ll.x) / 180.0 * float(m.rows)
	# The 2×2 block whose centre is nearest to the point.
	var x0 := int(floor(u - 0.5))
	var y0 := clampi(int(floor(v - 0.5)), 0, int(m.rows) - 2)
	x0 = posmod(x0, int(m.cols))
	var key := Vector3i(x0, y0, hash(body.id))
	if key == _block or _busy:
		return
	_block = key
	_body = body
	_queue.clear()
	for dy in 2:
		for dx in 2:
			_queue.append("%s_%d_%d.jpg" % [body.id, posmod(x0 + dx, int(m.cols)), y0 + dy])
	_next()


func _cache_path(id: String, file: String) -> String:
	return "user://tiles/%s/%s" % [id, file]


func _fetch_meta(id: String) -> void:
	var path := _cache_path(id, "%s_tiles.json" % id)
	if FileAccess.file_exists(path):
		_load_meta(id, path)
		return
	_busy = true
	_queue = ["%s_tiles.json" % id]
	_start(id, _queue[0])


func _load_meta(id: String, path: String) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) == TYPE_DICTIONARY and d.has("cols"):
		_meta[id] = d
	else:
		_failed[id] = true


func _next() -> void:
	while not _queue.is_empty():
		var f: String = _queue[0]
		if FileAccess.file_exists(_cache_path(_body.id, f)):
			_queue.pop_front()
			continue
		_busy = true
		_start(_body.id, f)
		return
	_busy = false
	_compose()


func _start(id: String, file: String) -> void:
	DirAccess.make_dir_recursive_absolute("user://tiles/%s" % id)
	_http.download_file = _cache_path(id, file) + ".part"
	var err := _http.request(BASE_URL % [id, file])
	if err != OK:
		_give_up(id, "request error %d" % err)


func _on_done(result: int, code: int, _headers: PackedStringArray, _body_bytes: PackedByteArray) -> void:
	var id: String = _body.id
	var file: String = _queue[0] if not _queue.is_empty() else ""
	var part := _cache_path(id, file) + ".part"
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(part)
		_give_up(id, "HTTP %d / result %d for %s" % [code, result, file])
		return
	DirAccess.rename_absolute(part, _cache_path(id, file))
	_queue.pop_front()
	if file.ends_with("_tiles.json"):
		_busy = false
		_load_meta(id, _cache_path(id, file))
		Log.info("HD tiles: %s ready (%s)" % [id, str(_meta.get(id, "failed"))])
		return
	_next()


func _give_up(id: String, why: String) -> void:
	Log.info("HD tiles: %s unavailable: %s" % [id, why])
	_busy = false
	_queue.clear()
	_block = Vector3i(-1, -1, -1)
	_failed[id] = true   # no retry this session (offline / not published)


func _compose() -> void:
	var m: Dictionary = _meta[_body.id]
	var t: int = m.tile
	var img := Image.create(t * 2, t * 2, false, Image.FORMAT_RGB8)
	for dy in 2:
		for dx in 2:
			var f := "%s_%d_%d.jpg" % [_body.id, posmod(_block.x + dx, int(m.cols)), _block.y + dy]
			var tile := Image.new()
			if tile.load_jpg_from_buffer(FileAccess.get_file_as_bytes(_cache_path(_body.id, f))) != OK:
				_give_up(_body.id, "bad tile " + f)
				return
			tile.convert(Image.FORMAT_RGB8)
			img.blit_rect(tile, Rect2i(0, 0, t, t), Vector2i(dx * t, dy * t))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var rect := Rect2(float(_block.x) / float(m.cols), float(_block.y) / float(m.rows),
		2.0 / float(m.cols), 2.0 / float(m.rows))
	Log.info("HD tiles: %s block %d,%d loaded" % [_body.id, _block.x, _block.y])
	tiles_ready.emit(_body, tex, rect)
