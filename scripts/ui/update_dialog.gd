extends Control
## "Update available" modal: release notes, Update / Later, download progress.

var _panel: PanelContainer
var _title: Label
var _notes: RichTextLabel
var _progress: ProgressBar
var _status: Label
var _update_btn: Button
var _later_btn: Button
var _browser_btn: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(760, 0)
	center.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	_panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 36)
	_title.add_theme_color_override("font_color", Color(1.0, 0.83, 0.43))
	box.add_child(_title)

	var current := Label.new()
	current.text = "Сейчас установлена v%s" % Updater.current_version_name()
	current.add_theme_font_size_override("font_size", 20)
	current.add_theme_color_override("font_color", Color(0.55, 0.65, 0.8))
	box.add_child(current)

	_notes = RichTextLabel.new()
	_notes.custom_minimum_size = Vector2(0, 260)
	_notes.selection_enabled = true
	box.add_child(_notes)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 30)
	_progress.max_value = 1.0
	_progress.step = 0.001
	_progress.hide()
	box.add_child(_progress)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 20)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.hide()
	box.add_child(_status)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 16)
	box.add_child(buttons)

	_browser_btn = Button.new()
	_browser_btn.text = "Скачать в браузере"
	_browser_btn.hide()
	_browser_btn.pressed.connect(Updater.open_in_browser)
	buttons.add_child(_browser_btn)

	_later_btn = Button.new()
	_later_btn.text = "Позже"
	_later_btn.pressed.connect(hide)
	buttons.add_child(_later_btn)

	_update_btn = Button.new()
	_update_btn.text = "Обновить"
	_update_btn.custom_minimum_size = Vector2(220, 0)
	_update_btn.pressed.connect(_on_update)
	buttons.add_child(_update_btn)

	Updater.download_progress.connect(_on_progress)
	Updater.download_finished.connect(_on_download_finished)
	hide()


func show_for(info: Dictionary) -> void:
	_title.text = "Доступно обновление %s" % info.get("tag", "")
	_notes.text = _clean_notes(str(info.get("notes", "")))
	_progress.hide()
	_status.hide()
	_browser_btn.hide()
	_update_btn.disabled = false
	_update_btn.text = "Обновить"
	show()


func _on_update() -> void:
	_update_btn.disabled = true
	_update_btn.text = "Загрузка…"
	_progress.value = 0.0
	_progress.show()
	_set_status("Скачиваю APK…")
	Updater.download_and_install()


func _on_progress(downloaded: int, total: int) -> void:
	if total > 0:
		_progress.value = float(downloaded) / float(total)
		_set_status("Скачано %.1f из %.1f МБ" % [downloaded / 1048576.0, total / 1048576.0])
	else:
		_set_status("Скачано %.1f МБ" % (downloaded / 1048576.0))


func _on_download_finished(ok: bool, message: String) -> void:
	_update_btn.disabled = false
	if ok:
		_progress.value = 1.0
		_update_btn.text = "Установить ещё раз"
		_set_status("Открываю установщик Android. Если он попросит разрешить установку из этого источника — разреши и нажми «Установить ещё раз».")
	else:
		_update_btn.text = "Повторить"
		_set_status(message)
	_browser_btn.show()


func _set_status(text: String) -> void:
	_status.text = text
	_status.show()


## Release body is markdown; RichTextLabel shows it as plain text, so drop the noise.
func _clean_notes(md: String) -> String:
	var out := PackedStringArray()
	for line in md.split("\n"):
		var l := line.strip_edges(false, true)
		if l == "---":
			continue
		l = l.replace("`", "")
		if l.begins_with("- "):
			l = "• " + l.substr(2)
		out.append(l)
	return "\n".join(out).strip_edges()
