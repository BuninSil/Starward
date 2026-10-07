extends Node3D
## Boot / title screen for stage 1: shows build version, a rotating placeholder
## planet (proves the 3D renderer works on the device) and debug tools.

const ConsoleScript := preload("res://scripts/ui/debug_console.gd")
const UpdateDialogScript := preload("res://scripts/ui/update_dialog.gd")

@onready var _planet: Node3D = $Planet
@onready var _sun: DirectionalLight3D = $Sun
@onready var _atmosphere: MeshInstance3D = $Atmosphere

var _ui: Control
var _overlay: Label
var _console: PanelContainer
var _debug_menu: PanelContainer
var _console_button: Button
var _update_dialog: UpdateDialogScript
var _update_status: Label
var _overlay_timer := 0.0


func _ready() -> void:
	Log.info("Boot: %s v%s build %s (%s), renderer=%s, device=%s" % [
		ProjectSettings.get_setting("application/config/name"),
		_version_name(), _version_code(),
		ProjectSettings.get_setting("starward/build/commit"),
		RenderingServer.get_current_rendering_method(),
		OS.get_model_name(),
	])
	var mat := (_atmosphere.mesh as SphereMesh).material as ShaderMaterial
	mat.set_shader_parameter("sun_dir_world", _sun.global_transform.basis.z)
	_build_ui()
	Log.line_added.connect(func(_l: String, _lv: int) -> void: _update_console_button())
	Updater.update_available.connect(_update_dialog.show_for)
	Updater.check_finished.connect(func(_has: bool, msg: String) -> void: _update_status.text = msg)
	Updater.check_on_startup()


func _process(delta: float) -> void:
	_planet.rotate_object_local(Vector3.UP, delta * 0.08)
	_overlay_timer -= delta
	if _overlay_timer <= 0.0:
		_overlay_timer = 0.25
		_update_overlay()


func _version_name() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


func _version_code() -> int:
	return int(ProjectSettings.get_setting("starward/build/version_code", 0))


# --- UI -----------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)

	# Title, top-left.
	var title_box := VBoxContainer.new()
	title_box.position = Vector2(48, 36)
	_ui.add_child(title_box)
	var title := Label.new()
	title.text = str(ProjectSettings.get_setting("application/config/name")).to_upper()
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	title.add_theme_constant_override("outline_size", 0)
	title_box.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Этап 1 · тест автообновления"
	subtitle.add_theme_font_size_override("font_size", 26)
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.68, 0.9))
	title_box.add_child(subtitle)

	# Version, bottom-left, large: the main thing to check after install.
	var version := Label.new()
	version.text = "v%s  ·  build %d" % [_version_name(), _version_code()]
	version.add_theme_font_size_override("font_size", 44)
	version.add_theme_color_override("font_color", Color(1.0, 0.83, 0.43))
	version.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 48)
	version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ui.add_child(version)

	# Debug overlay, top-right.
	_overlay = Label.new()
	_overlay.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_overlay.add_theme_font_size_override("font_size", 18)
	_overlay.add_theme_color_override("font_color", Color(0.6, 0.95, 0.7))
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	_overlay.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_ui.add_child(_overlay)

	# Buttons, bottom-right.
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 16)
	buttons.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 40)
	buttons.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	buttons.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ui.add_child(buttons)

	_console_button = Button.new()
	_console_button.pressed.connect(func() -> void: _console.visible = not _console.visible)
	buttons.add_child(_console_button)
	_update_console_button()

	var debug_button := Button.new()
	debug_button.text = "Дебаг"
	debug_button.pressed.connect(func() -> void: _debug_menu.visible = not _debug_menu.visible)
	buttons.add_child(debug_button)

	_debug_menu = _build_debug_menu()
	_debug_menu.hide()
	_ui.add_child(_debug_menu)

	_update_dialog = UpdateDialogScript.new()
	_ui.add_child(_update_dialog)

	_console = ConsoleScript.new()
	_console.hide()
	_ui.add_child(_console)


func _build_debug_menu() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 40)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var header := Label.new()
	header.text = "Дебаг-меню"
	header.add_theme_font_size_override("font_size", 30)
	box.add_child(header)

	var check := Button.new()
	check.text = "Проверить обновление сейчас"
	check.pressed.connect(func() -> void:
		_update_status.text = "Проверяю…"
		Updater.check_now())
	box.add_child(check)

	_update_status = Label.new()
	_update_status.text = "Обновления: ещё не проверялись"
	_update_status.add_theme_font_size_override("font_size", 20)
	_update_status.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85))
	box.add_child(_update_status)

	var copy := Button.new()
	copy.text = "Скопировать лог"
	copy.pressed.connect(Log.copy_to_clipboard)
	box.add_child(copy)

	var close := Button.new()
	close.text = "Закрыть"
	close.pressed.connect(panel.hide)
	box.add_child(close)
	return panel


func _update_console_button() -> void:
	if _console_button == null:
		return
	var errors := Log.error_count()
	_console_button.text = "Консоль" if errors == 0 else "Консоль (%d ош.)" % errors


func _update_overlay() -> void:
	_overlay.text = "FPS %d\nv%s (%d)\n%s · %s\n%s" % [
		Engine.get_frames_per_second(),
		_version_name(), _version_code(),
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name(),
		OS.get_model_name(),
	]
