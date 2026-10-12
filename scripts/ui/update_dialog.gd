extends Control
## Release notes card, two uses:
##  * show_for(info): "Доступно обновление" with Update / Later and download progress;
##  * show_whats_new(info): "Что нового" once after an update was installed.
## The notes come from the GitHub release body: "## title" per change with a
## bullet list under it (see build.yml), rendered as tidy sections.

const ACCENT := Color(1.0, 0.62, 0.22)
const TEXT := Color(0.93, 0.95, 1.0)
const DIM := Color(0.6, 0.67, 0.8)
const GREEN := Color(0.45, 0.9, 0.55)

var _panel: PanelContainer
var _badge: Label
var _title: Label
var _sub: Label
var _notes: RichTextLabel
var _progress: ProgressBar
var _status: Label
var _update_btn: Button
var _later_btn: Button
var _browser_btn: Button


static func _box(bg: Color, border: Color, bw := 1, radius := 16, mx := 24, my := 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	return sb


func _button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(200, 66)
	b.add_theme_font_size_override("font_size", 24)
	if primary:
		var n := _box(ACCENT, ACCENT, 0, 14)
		var p := _box(ACCENT.darkened(0.2), ACCENT, 0, 14)
		b.add_theme_stylebox_override("normal", n)
		b.add_theme_stylebox_override("hover", n)
		b.add_theme_stylebox_override("pressed", p)
		b.add_theme_stylebox_override("disabled", _box(ACCENT.darkened(0.5), ACCENT.darkened(0.5), 0, 14))
		for k in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(k, Color(0.08, 0.05, 0.02))
		b.add_theme_color_override("font_disabled_color", Color(0.1, 0.07, 0.04))
	else:
		var n := _box(Color(0.08, 0.1, 0.16, 0.9), Color(1, 1, 1, 0.12), 1, 14)
		b.add_theme_stylebox_override("normal", n)
		b.add_theme_stylebox_override("hover", n)
		b.add_theme_stylebox_override("pressed", _box(Color(0.14, 0.17, 0.26), ACCENT, 2, 14))
		b.add_theme_color_override("font_color", TEXT)
		b.add_theme_color_override("font_hover_color", TEXT)
	return b


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0.01, 0.03, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(820, 0)
	_panel.add_theme_stylebox_override("panel", _box(Color(0.03, 0.05, 0.09, 0.97), Color(1, 1, 1, 0.1), 1, 22, 32, 26))
	center.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_panel.add_child(box)

	# Header: small badge, big title, version line.
	_badge = Label.new()
	_badge.add_theme_font_size_override("font_size", 17)
	_badge.add_theme_color_override("font_color", ACCENT)
	box.add_child(_badge)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 40)
	_title.add_theme_color_override("font_color", TEXT)
	box.add_child(_title)
	_sub = Label.new()
	_sub.add_theme_font_size_override("font_size", 19)
	_sub.add_theme_color_override("font_color", DIM)
	box.add_child(_sub)

	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.08)
	line.custom_minimum_size = Vector2(0, 2)
	box.add_child(line)

	_notes = RichTextLabel.new()
	_notes.bbcode_enabled = true
	_notes.custom_minimum_size = Vector2(0, 280)
	_notes.fit_content = false
	_notes.scroll_active = true
	_notes.add_theme_font_size_override("normal_font_size", 20)
	_notes.add_theme_font_size_override("bold_font_size", 21)
	_notes.add_theme_color_override("default_color", Color(0.82, 0.86, 0.94))
	_notes.add_theme_constant_override("line_separation", 4)
	box.add_child(_notes)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 14)
	_progress.max_value = 1.0
	_progress.step = 0.001
	_progress.show_percentage = false
	_progress.add_theme_stylebox_override("background", _box(Color(1, 1, 1, 0.08), Color(0, 0, 0, 0), 0, 7, 0, 0))
	_progress.add_theme_stylebox_override("fill", _box(ACCENT, ACCENT, 0, 7, 0, 0))
	_progress.hide()
	box.add_child(_progress)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_color", DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(750, 0)
	_status.hide()
	box.add_child(_status)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 12)
	box.add_child(buttons)
	_browser_btn = _button("Скачать в браузере", false)
	_browser_btn.hide()
	_browser_btn.pressed.connect(Updater.open_in_browser)
	buttons.add_child(_browser_btn)
	_later_btn = _button("Позже", false)
	_later_btn.pressed.connect(hide)
	buttons.add_child(_later_btn)
	_update_btn = _button("Обновить", true)
	_update_btn.custom_minimum_size.x = 240
	_update_btn.pressed.connect(_on_update)
	buttons.add_child(_update_btn)

	Updater.download_progress.connect(_on_progress)
	Updater.download_finished.connect(_on_download_finished)
	hide()


func show_for(info: Dictionary) -> void:
	_badge.text = "ДОСТУПНО ОБНОВЛЕНИЕ"
	_title.text = "Версия %s" % str(info.get("tag", "")).trim_prefix("v")
	var size_mb := float(info.get("apk_size", 0)) / 1048576.0
	_sub.text = "Сейчас установлена %s%s" % [Updater.current_version_name(),
		"  ·  загрузка %.0f МБ" % size_mb if size_mb > 0.0 else ""]
	_notes.text = render_notes(str(info.get("notes", "")))
	_notes.scroll_to_line(0)
	_progress.hide()
	_status.hide()
	_browser_btn.hide()
	_later_btn.text = "Позже"
	_update_btn.show()
	_update_btn.disabled = false
	_update_btn.text = "Обновить"
	show()


## After an update was installed: what changed, one button.
func show_whats_new(info: Dictionary) -> void:
	_badge.text = "ОБНОВЛЕНИЕ УСТАНОВЛЕНО"
	_title.text = "Что нового в %s" % str(info.get("tag", "")).trim_prefix("v")
	_sub.text = "Игра обновилась до последней версии"
	_notes.text = render_notes(str(info.get("notes", "")))
	_notes.scroll_to_line(0)
	_progress.hide()
	_status.hide()
	_browser_btn.hide()
	_update_btn.hide()
	_later_btn.text = "Отлично"
	show()


func _on_update() -> void:
	_update_btn.disabled = true
	_update_btn.text = "Загрузка…"
	_progress.value = 0.0
	_progress.show()
	_set_status("Скачиваю обновление…")
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
		_update_btn.text = "Установить"
		_set_status("Открываю установщик Android. Если он попросит разрешить установку из этого источника — разреши и нажми «Установить».")
	else:
		_update_btn.text = "Повторить"
		_set_status(message)
	_browser_btn.show()


func _set_status(text: String) -> void:
	_status.text = text
	_status.show()


## Release body (markdown) -> BBCode: "## title" become bold headings, "- x"
## bullets, the technical footer after "---" and commit hashes are dropped.
static func render_notes(md: String) -> String:
	var out := PackedStringArray()
	var hash_re := RegEx.create_from_string("\\s*\\([0-9a-f]{7}\\)\\s*$")
	for raw in md.split("\n"):
		var l := raw.strip_edges()
		if l == "---":
			break
		if l.is_empty() or l.begins_with("Изменения с") or l.begins_with("Первый релиз"):
			continue
		l = hash_re.sub(l, "").replace("`", "").replace("[", "(").replace("]", ")")
		if l.begins_with("## "):
			if not out.is_empty():
				out.append("")
			out.append("[b][color=#eef2ff]%s[/color][/b]" % l.substr(3))
		elif l.begins_with("- "):
			out.append("[indent][color=#ff9e38]•[/color]  [color=#b8c2d8]%s[/color][/indent]" % l.substr(2))
		else:
			out.append(l)
	if out.is_empty():
		return "[color=#9aa8c8]Описание изменений не указано.[/color]"
	return "\n".join(out)
