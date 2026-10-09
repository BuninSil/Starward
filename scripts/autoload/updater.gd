extends Node
## Self-update from GitHub Releases (public repo, no tokens in the APK).
## Startup check runs once per launch; network errors only go to the log.

signal update_available(info: Dictionary)
signal check_finished(has_update: bool, message: String)
signal download_progress(downloaded: int, total: int)
signal download_finished(ok: bool, message: String)

const REPO := "BuninSil/Starward"
const API_LATEST := "https://api.github.com/repos/%s/releases/latest" % REPO
const PLUGIN_SINGLETON := "StarwardUpdater"
const TIMEOUT_SEC := 15.0
const RETRY_DELAY_SEC := 2.0
const DOWNLOAD_ATTEMPTS := 3
const RESUME_RECHECK_SEC := 600.0   ## re-check on app resume if the last check is older

## Last found release: {tag, version_code, name, notes, apk_url, apk_size, html_url}
var latest: Dictionary = {}
var is_checking := false
var is_downloading := false

var _startup_checked := false
var _retried := false
var _last_check_msec := -1
var _check_request: HTTPRequest
var _download_request: HTTPRequest
var _download_path := ""


func current_version_code() -> int:
	return int(ProjectSettings.get_setting("starward/build/version_code", 0))


func current_version_name() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## "v0.1.42" -> 42, anything else -> -1.
static func version_code_from_tag(tag: String) -> int:
	var re := RegEx.create_from_string("^v?\\d+\\.\\d+\\.(\\d+)$")
	var m := re.search(tag.strip_edges())
	return int(m.get_string(1)) if m else -1


func check_on_startup() -> void:
	if _startup_checked:
		return
	_startup_checked = true
	if current_version_code() <= 0:
		Log.info("Updater: local build (version_code 0), startup check skipped")
		return
	check_now()


func _notification(what: int) -> void:
	# After the app was in background Android may have dropped its sockets;
	# re-check if the last check is old enough.
	if what == NOTIFICATION_APPLICATION_RESUMED and _startup_checked and current_version_code() > 0:
		if _last_check_msec < 0 or Time.get_ticks_msec() - _last_check_msec > RESUME_RECHECK_SEC * 1000.0:
			Log.info("Updater: app resumed, re-checking in a moment")
			# Not from inside the notification: the tree may be busy (add_child fails),
			# and the network needs a moment to come back after the app wakes up.
			_last_check_msec = Time.get_ticks_msec()
			get_tree().create_timer(2.0).timeout.connect(check_now)


func check_now() -> void:
	_retried = false
	_start_check()


func _start_check() -> void:
	if is_checking:
		return
	is_checking = true
	_last_check_msec = Time.get_ticks_msec()
	# Fresh HTTPRequest every time: a node reused after background can hold a dead connection.
	if _check_request != null:
		_check_request.queue_free()
	_check_request = HTTPRequest.new()
	_check_request.timeout = TIMEOUT_SEC
	_check_request.request_completed.connect(_on_check_completed)
	add_child(_check_request)
	Log.info("Updater: checking %s (current build %d)" % [API_LATEST, current_version_code()])
	var err := _check_request.request(API_LATEST, _headers("application/vnd.github+json"))
	if err != OK:
		_finish_check(false, "Не удалось отправить запрос (код %d)" % err)


func _on_check_completed(result: int, code: int, _headers_in: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		if not _retried:
			# One silent retry: first request after resume often fails.
			_retried = true
			is_checking = false
			Log.info("Updater: request failed (result %d), retrying in %.0f s" % [result, RETRY_DELAY_SEC])
			var timer := Timer.new()
			timer.one_shot = true
			timer.wait_time = RETRY_DELAY_SEC
			timer.timeout.connect(func() -> void:
				timer.queue_free()
				_start_check())
			add_child(timer)
			timer.start()
			return
		_finish_check(false, "Сеть недоступна (result %d)" % result)
		return
	if code == 404:
		_finish_check(false, "Релизов пока нет")
		return
	if code != 200:
		_finish_check(false, "GitHub ответил HTTP %d" % code)
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		_finish_check(false, "Не удалось разобрать ответ GitHub")
		return

	var tag := str(data.get("tag_name", ""))
	var remote_code := version_code_from_tag(tag)
	var info := {
		"tag": tag,
		"version_code": remote_code,
		"name": str(data.get("name", tag)),
		"notes": str(data.get("body", "")),
		"html_url": str(data.get("html_url", "")),
		"apk_url": "",
		"apk_size": 0,
	}
	for asset in data.get("assets", []):
		if str(asset.get("name", "")).ends_with(".apk"):
			info.apk_url = str(asset.get("browser_download_url", ""))
			info.apk_size = int(asset.get("size", 0))
			break
	latest = info
	Log.info("Updater: latest %s (code %d), apk=%s" % [tag, remote_code, info.apk_url])

	if remote_code <= current_version_code():
		_finish_check(false, "Установлена последняя версия (v%s)" % current_version_name())
		return
	if info.apk_url.is_empty():
		_finish_check(false, "В релизе %s нет APK" % tag)
		return
	_finish_check(true, "Доступна %s" % tag)
	update_available.emit(info)


func _finish_check(has_update: bool, message: String) -> void:
	is_checking = false
	Log.info("Updater: " + message)
	check_finished.emit(has_update, message)


# --- Download & install -------------------------------------------------------

var _download_attempt := 0


func download_and_install() -> void:
	if latest.is_empty() or is_downloading:
		return
	var dir := OS.get_cache_dir().path_join("updates")
	DirAccess.make_dir_recursive_absolute(dir)
	_download_path = dir.path_join("starward-%s.apk" % latest.tag)

	# Already downloaded (e.g. user came back from the "allow installs" screen).
	if FileAccess.file_exists(_download_path) and _file_size(_download_path) == latest.apk_size:
		Log.info("Updater: using already downloaded %s" % _download_path)
		_install(_download_path)
		return
	_cleanup_old_apks(dir)

	is_downloading = true
	_download_attempt = 0
	_start_download()


## A fresh HTTPRequest per attempt: after a failed connect (seen on phones as
## result 2 right after the github.com redirect) a reused one fails instantly.
func _start_download() -> void:
	if _download_request != null:
		_download_request.cancel_request()
		_download_request.queue_free()
	_download_request = HTTPRequest.new()
	_download_request.use_threads = true
	_download_request.download_chunk_size = 256 * 1024
	_download_request.request_completed.connect(_on_download_completed)
	add_child(_download_request)
	_download_request.download_file = _download_path
	Log.info("Updater: downloading %s -> %s" % [latest.apk_url, _download_path])
	var err := _download_request.request(latest.apk_url, _headers("application/octet-stream"))
	if err != OK:
		_finish_download(false, "Не удалось начать загрузку (код %d)" % err)


func _process(_delta: float) -> void:
	if is_downloading and _download_request:
		var total := _download_request.get_body_size()
		if total <= 0:
			total = int(latest.get("apk_size", 0))
		download_progress.emit(_download_request.get_downloaded_bytes(), total)


func _on_download_completed(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_download_attempt += 1
		if _download_attempt < DOWNLOAD_ATTEMPTS:
			Log.warn("Updater: download failed (result %d, HTTP %d), retry %d" % [result, code, _download_attempt])
			get_tree().create_timer(3.0).timeout.connect(_start_download)
			return
		_finish_download(false, "Не удалось скачать (result %d, HTTP %d). Открываю загрузку в браузере." % [result, code])
		open_in_browser()
		return
	var size := _file_size(_download_path)
	if latest.apk_size > 0 and size != latest.apk_size:
		_finish_download(false, "Файл повреждён: %d из %d байт" % [size, latest.apk_size])
		return
	_finish_download(true, "Загружено, запускаю установку")
	_install(_download_path)


func _finish_download(ok: bool, message: String) -> void:
	is_downloading = false
	if ok:
		Log.info("Updater: " + message)
	else:
		Log.warn("Updater: " + message)
		DirAccess.remove_absolute(_download_path)
	download_finished.emit(ok, message)


func _install(path: String) -> void:
	# 1) Our Kotlin plugin: FileProvider over cache/updates + package installer.
	if Engine.has_singleton(PLUGIN_SINGLETON):
		var plugin := Engine.get_singleton(PLUGIN_SINGLETON)
		var err := str(plugin.installApk(path))
		if err.is_empty():
			Log.info("Updater: installer started via plugin")
			return
		Log.warn("Updater: plugin install failed: " + err)
	else:
		Log.warn("Updater: plugin %s not available" % PLUGIN_SINGLETON)

	# 2) Godot's own FileProvider only covers user:// (files dir): copy there and open.
	if OS.get_name() == "Android":
		var user_copy := OS.get_user_data_dir().path_join("update.apk")
		if DirAccess.copy_absolute(path, user_copy) == OK and OS.shell_open(user_copy) == OK:
			Log.info("Updater: installer started via OS.shell_open")
			return
		Log.warn("Updater: OS.shell_open fallback failed")

	# 3) Last resort: let the browser download it.
	open_in_browser()


func open_in_browser() -> void:
	var url := str(latest.get("apk_url", ""))
	if url.is_empty():
		url = "https://github.com/%s/releases/latest" % REPO
	Log.info("Updater: opening in browser " + url)
	OS.shell_open(url)


func _cleanup_old_apks(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".apk"):
			DirAccess.remove_absolute(dir.path_join(f))
	var user_copy := OS.get_user_data_dir().path_join("update.apk")
	if FileAccess.file_exists(user_copy):
		DirAccess.remove_absolute(user_copy)


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else -1


func _headers(accept: String) -> PackedStringArray:
	return PackedStringArray([
		"Accept: " + accept,
		"User-Agent: Starward-Updater/" + current_version_name(),
		"X-GitHub-Api-Version: 2022-11-28",
	])
