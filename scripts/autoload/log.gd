extends Node
## Central log. Captures everything the engine prints (print, push_warning,
## push_error, script errors) through a custom Logger, keeps the last
## MAX_LINES in memory for the in-game console and can copy them to clipboard.

signal line_added(line: String, level: int)

enum Level { INFO, WARN, ERROR }

const MAX_LINES := 1000

var _lines: Array[String] = []
var _levels: Array[int] = []
var _mutex := Mutex.new()
var _logger: _CaptureLogger


func _init() -> void:
	_logger = _CaptureLogger.new(self)
	OS.add_logger(_logger)


func _exit_tree() -> void:
	OS.remove_logger(_logger)


func info(msg: String) -> void:
	print("[I] ", msg)


func warn(msg: String) -> void:
	# push_warning also reaches the logger, but adds a noisy backtrace header.
	print("[W] ", msg)


func error(msg: String) -> void:
	push_error(msg)


func get_lines() -> Array[String]:
	_mutex.lock()
	var copy := _lines.duplicate()
	_mutex.unlock()
	return copy


func get_levels() -> Array[int]:
	_mutex.lock()
	var copy := _levels.duplicate()
	_mutex.unlock()
	return copy


func error_count() -> int:
	_mutex.lock()
	var n := _levels.count(Level.ERROR)
	_mutex.unlock()
	return n


func get_text() -> String:
	var header := "%s v%s (build %s, %s)\n%s %s | %s\n\n" % [
		ProjectSettings.get_setting("application/config/name"),
		ProjectSettings.get_setting("application/config/version"),
		ProjectSettings.get_setting("starward/build/version_code"),
		ProjectSettings.get_setting("starward/build/commit"),
		OS.get_name(), OS.get_version(), OS.get_model_name(),
	]
	return header + "\n".join(get_lines())


func copy_to_clipboard() -> void:
	DisplayServer.clipboard_set(get_text())
	info("Log copied to clipboard (%d lines)" % _lines.size())


## Called from any thread by the logger.
func _append(text: String, level: int) -> void:
	var stamp := Time.get_time_string_from_system()
	var line := "%s %s" % [stamp, text.strip_edges(false, true)]
	_mutex.lock()
	_lines.append(line)
	_levels.append(level)
	if _lines.size() > MAX_LINES:
		_lines.pop_front()
		_levels.pop_front()
	_mutex.unlock()
	line_added.emit.call_deferred(line, level)


class _CaptureLogger extends Logger:
	var _owner: WeakRef

	func _init(owner: Node) -> void:
		_owner = weakref(owner)

	func _log_message(message: String, error: bool) -> void:
		var o = _owner.get_ref()
		if o == null:
			return
		var level := Level.INFO
		if error:
			level = Level.ERROR
		elif message.begins_with("[W] "):
			level = Level.WARN
		o._append(message, level)

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			script_backtraces: Array[ScriptBacktrace]) -> void:
		var o = _owner.get_ref()
		if o == null:
			return
		var msg := rationale if not rationale.is_empty() else code
		var kind := "ERROR"
		var level := Level.ERROR
		if error_type == ERROR_TYPE_WARNING:
			kind = "WARNING"
			level = Level.WARN
		elif error_type == ERROR_TYPE_SCRIPT:
			kind = "SCRIPT ERROR"
		elif error_type == ERROR_TYPE_SHADER:
			kind = "SHADER ERROR"
		var where := "%s (%s:%d)" % [function, file, line]
		for bt in script_backtraces:
			if bt.get_frame_count() > 0:
				where = "%s (%s:%d)" % [bt.get_frame_function(0), bt.get_frame_file(0), bt.get_frame_line(0)]
				break
		o._append("%s: %s\n    at %s" % [kind, msg, where], level)
