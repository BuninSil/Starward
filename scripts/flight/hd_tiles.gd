extends Node
## High-resolution colour tiles for a body's surface around the vessel, in two
## levels (like the streamed terrain of big games):
##   level 0: 2×2 full-resolution tiles under the vessel (≈ 130–250 km);
##   level 1: 2×2 tiles of the coarse 8192-wide map (tools/build_tile_levels.py),
##            out to the horizon from orbit (≈ 270–1000 km).
## Tiles are published as GitHub prereleases `maps-<id>-v1` (tools/build_tiles.py)
## and downloaded on demand, cached in user://tiles/<id>/. Offline or missing
## tiles: nothing happens and the surface keeps the global map. Decoding and
## mipmaps run on a worker thread; only the texture upload is on the main thread.

signal tiles_ready(body: CelestialBody, texture: Texture2D, rect: Rect2, level: int)

const BASE_URL := "https://github.com/BuninSil/Starward/releases/download/maps-%s-v1/%s"
const BODIES := ["earth", "moon", "mars", "mercury", "venus"]
const L1_WIDTH := 8192
const LEVELS := 2

var _http: HTTPRequest
var _dl: Array[PackedStringArray] = []  ## download queue: [id, file]
var _dl_busy := false
var _meta := {}                         ## id -> tiles.json dictionary
var _failed := {}                       ## id or "id:l1" -> true when unreachable
var _jobs: Array = [null, null]         ## per level: block being fetched / composed
var _cur: Array = [{}, {}]              ## per level: block shown {id, x0, y0}
var _tasks: Array[int] = []             ## worker tasks still running


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	add_child(_http)
	_http.request_completed.connect(_on_done)


func _exit_tree() -> void:
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()


## Called every frame with the vessel's body-fixed direction for each wanted level.
func want(body: CelestialBody, fixed_dir: DVec3, level := 0) -> void:
	var id := body.id
	if not id in BODIES or _failed.has(id) or _failed.has(_fkey(id, level)) or _jobs[level] != null:
		return
	if not _meta.has(id):
		_fetch_meta(id)
		return
	var m: Dictionary = _meta[id]
	var cols := int(m.cols)
	var rows := int(m.rows)
	var fmt := "%s_%d_%d.jpg"
	if level == 1:
		var f := int(m.width) / L1_WIDTH
		if f < 2:
			return   # the full set is coarse already
		cols /= f
		rows /= f
		fmt = "%s_l1_%d_%d.jpg"
	var ll := CelestialBody.lat_lon(fixed_dir)
	var u := (ll.y + 180.0) / 360.0 * float(cols)
	var v := (90.0 - ll.x) / 180.0 * float(rows)
	# Keep the block while the point stays near its centre (no flip-flop on a line).
	var cur: Dictionary = _cur[level]
	if cur.get("id", "") == id:
		var cu := u - (float(cur.x0) + 1.0)
		cu -= roundf(cu / float(cols)) * float(cols)
		if absf(cu) < 0.75 and absf(v - (float(cur.y0) + 1.0)) < 0.75:
			return
	# The 2×2 block whose centre is nearest to the point.
	var x0 := posmod(int(roundf(u - 1.0)), cols)
	var y0 := clampi(int(roundf(v - 1.0)), 0, rows - 2)
	if cur.get("id", "") == id and cur.x0 == x0 and cur.y0 == y0:
		return
	var files := PackedStringArray()
	for dy in 2:
		for dx in 2:
			files.append(fmt % [id, posmod(x0 + dx, cols), y0 + dy])
	_jobs[level] = {"body": body, "id": id, "level": level, "x0": x0, "y0": y0,
		"cols": cols, "rows": rows, "files": files, "composing": false}
	for f in files:
		if not FileAccess.file_exists(_cache_path(id, f)):
			_enqueue(id, f)
	_check_jobs()


static func _fkey(id: String, level: int) -> String:
	return id if level == 0 else "%s:l%d" % [id, level]


func _cache_path(id: String, file: String) -> String:
	return "user://tiles/%s/%s" % [id, file]


func _fetch_meta(id: String) -> void:
	var file := "%s_tiles.json" % id
	var path := _cache_path(id, file)
	if FileAccess.file_exists(path):
		_load_meta(id, path)
		return
	_enqueue(id, file)


func _load_meta(id: String, path: String) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) == TYPE_DICTIONARY and d.has("cols"):
		_meta[id] = d
	else:
		_failed[id] = true


func _enqueue(id: String, file: String) -> void:
	for e in _dl:
		if e[0] == id and e[1] == file:
			return
	_dl.append(PackedStringArray([id, file]))
	_next()


func _next() -> void:
	if _dl_busy:
		return
	while not _dl.is_empty():
		var id := _dl[0][0]
		var f := _dl[0][1]
		if FileAccess.file_exists(_cache_path(id, f)):
			_dl.pop_front()
			continue
		_dl_busy = true
		DirAccess.make_dir_recursive_absolute("user://tiles/%s" % id)
		_http.download_file = _cache_path(id, f) + ".part"
		var err := _http.request(BASE_URL % [id, f])
		if err != OK:
			_dl_busy = false
			_give_up(id, f, "request error %d" % err)
			continue
		return


func _on_done(result: int, code: int, _headers: PackedStringArray, _body_bytes: PackedByteArray) -> void:
	_dl_busy = false
	if _dl.is_empty():
		return
	var id := _dl[0][0]
	var file := _dl[0][1]
	_dl.pop_front()
	var part := _cache_path(id, file) + ".part"
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(part)
		_give_up(id, file, "HTTP %d / result %d for %s" % [code, result, file])
	else:
		DirAccess.rename_absolute(part, _cache_path(id, file))
		if file.ends_with("_tiles.json"):
			_load_meta(id, _cache_path(id, file))
			Log.info("HD tiles: %s ready (%s)" % [id, str(_meta.get(id, "failed"))])
		_check_jobs()
	_next()


## No retry this session (offline / not published): the whole body when its
## full tiles fail, only the coarse level when that one is missing.
func _give_up(id: String, file: String, why: String) -> void:
	var level := 1 if file.contains("_l1_") else 0
	Log.info("HD tiles: %s level %d unavailable: %s" % [id, level, why])
	_failed[_fkey(id, level)] = true
	for l in LEVELS:
		var j = _jobs[l]
		if j != null and j.id == id and (level == 0 or l == level) and not j.composing:
			_jobs[l] = null
	var keep: Array[PackedStringArray] = []
	for e in _dl:
		if e[0] != id or (level == 1 and not e[1].contains("_l1_")):
			keep.append(e)
	_dl = keep


func _check_jobs() -> void:
	for l in LEVELS:
		var j = _jobs[l]
		if j == null or j.composing:
			continue
		var ready := true
		for f in j.files:
			if not FileAccess.file_exists(_cache_path(j.id, f)):
				ready = false
				break
		if ready:
			j.composing = true
			var paths := PackedStringArray()
			for f in j.files:
				paths.append(_cache_path(j.id, f))
			_tasks.append(WorkerThreadPool.add_task(_compose.bind(j, paths)))


## Worker thread: decode the 2×2 tiles into one image with mipmaps.
func _compose(job: Dictionary, paths: PackedStringArray) -> void:
	var img: Image = null
	var t := 0
	for i in 4:
		var tile := Image.new()
		if tile.load_jpg_from_buffer(FileAccess.get_file_as_bytes(paths[i])) != OK:
			img = null
			break
		tile.convert(Image.FORMAT_RGB8)
		if img == null:
			t = tile.get_width()
			img = Image.create(t * 2, t * 2, false, Image.FORMAT_RGB8)
		img.blit_rect(tile, Rect2i(0, 0, t, t), Vector2i((i % 2) * t, (i / 2) * t))
	if img != null:
		img.generate_mipmaps()
	_finish.call_deferred(job, img, paths)


func _finish(job: Dictionary, img: Image, paths: PackedStringArray) -> void:
	for i in range(_tasks.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_tasks[i])
			_tasks.remove_at(i)
	var l: int = job.level
	_jobs[l] = null
	if img == null:
		for p in paths:
			DirAccess.remove_absolute(p)   # broken download: fetch again next time
		_failed[_fkey(job.id, l)] = true
		Log.info("HD tiles: %s level %d: bad tile" % [job.id, l])
		return
	_cur[l] = {"id": job.id, "x0": job.x0, "y0": job.y0}
	var tex := ImageTexture.create_from_image(img)
	var rect := Rect2(float(job.x0) / float(job.cols), float(job.y0) / float(job.rows),
		2.0 / float(job.cols), 2.0 / float(job.rows))
	Log.info("HD tiles: %s level %d block %d,%d loaded" % [job.id, l, job.x0, job.y0])
	tiles_ready.emit(job.body, tex, rect, l)
