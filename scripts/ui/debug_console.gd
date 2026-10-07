extends PanelContainer
## In-game log console: shows Log lines (errors in red), copies log to clipboard.

const LEVEL_COLORS := {
	0: "#c9d4e6",
	1: "#ffd36e",
	2: "#ff6b6b",
}

var _text: RichTextLabel
var _only_errors: CheckButton


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 24
	offset_top = 24
	offset_right = -24
	offset_bottom = -24

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	box.add_child(header)

	var title := Label.new()
	title.text = "Консоль"
	title.add_theme_font_size_override("font_size", 32)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_only_errors = CheckButton.new()
	_only_errors.text = "Только ошибки"
	_only_errors.toggled.connect(func(_on: bool) -> void: _rebuild())
	header.add_child(_only_errors)

	var copy := Button.new()
	copy.text = "Скопировать лог"
	copy.pressed.connect(_on_copy)
	header.add_child(copy)

	var close := Button.new()
	close.text = "Закрыть"
	close.pressed.connect(hide)
	header.add_child(close)

	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.scroll_following = true
	_text.selection_enabled = true
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_size_override("normal_font_size", 18)
	box.add_child(_text)

	Log.line_added.connect(_on_line_added)
	visibility_changed.connect(func() -> void:
		if visible:
			_rebuild())
	_rebuild()


func _rebuild() -> void:
	_text.clear()
	var lines := Log.get_lines()
	var levels := Log.get_levels()
	for i in lines.size():
		_add(lines[i], levels[i])


func _add(line: String, level: int) -> void:
	if _only_errors.button_pressed and level == Log.Level.INFO:
		return
	_text.push_color(Color(LEVEL_COLORS.get(level, "#ffffff")))
	_text.add_text(line + "\n")
	_text.pop()


func _on_line_added(line: String, level: int) -> void:
	if visible:
		_add(line, level)


func _on_copy() -> void:
	Log.copy_to_clipboard()
