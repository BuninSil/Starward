extends Node3D
## Title screen / main menu: the real Earth (NASA Blue Marble) with the Moon on
## the right, the menu on the dark side on the left. Play, rocket choice,
## rocket showcase, settings (graphics, updates, console, log), quit.

const ConsoleScript := preload("res://scripts/ui/debug_console.gd")
const UpdateDialogScript := preload("res://scripts/ui/update_dialog.gd")
const ShowcaseScript := preload("res://scripts/flight/parts_showcase.gd")

const ACCENT := Color(1.0, 0.62, 0.22)
const TEXT := Color(0.93, 0.95, 1.0)
const DIM := Color(0.58, 0.66, 0.8)

## Menu cards for the prebuilt rockets.
const ROCKETS := [
	{"id": "moon", "name": "Лунная ракета", "info": "Полёт к Луне: посадка, выход на поверхность и возврат домой.\n6 ступеней · посадочный модуль на ногах · парашют"},
	{"id": "orbit", "name": "Ракета «Орбита»", "info": "Лёгкая ракета для первых полётов: взлёт, орбита Земли, спуск на парашюте.\n3 ступени · капсула с парашютом"},
]

@onready var _planet: Node3D = $Planet
@onready var _sun: DirectionalLight3D = $Sun
@onready var _atmosphere: MeshInstance3D = $Atmosphere
@onready var _camera: Camera3D = $Camera3D

var _ui: Control
var _moon: MeshInstance3D
var _console: PanelContainer
var _settings: Control
var _console_button: Button
var _update_dialog: UpdateDialogScript
var _update_status: Label
var _gfx_button: Button
var _rocket_cards: Array[Button] = []
var _rocket_info: Label
var _update_banner: Button
var _t := 0.0


func _notification(what: int) -> void:
	# Android "back": close the open panel, quit from the menu itself.
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if _console and _console.visible:
			_console.hide()
		elif _settings and _settings.visible:
			_settings.hide()
		elif _update_dialog and _update_dialog.visible:
			_update_dialog.hide()
		else:
			get_tree().quit()


func _ready() -> void:
	Log.info("Boot: %s v%s build %s (%s), renderer=%s, device=%s" % [
		ProjectSettings.get_setting("application/config/name"),
		_version_name(), _version_code(),
		ProjectSettings.get_setting("starward/build/commit"),
		RenderingServer.get_current_rendering_method(),
		OS.get_model_name(),
	])
	_setup_scene()
	_build_ui()
	Log.line_added.connect(func(_l: String, _lv: int) -> void: _update_console_button())
	Updater.update_available.connect(func(info: Dictionary) -> void:
		Updater.offered_tag = str(info.tag)
		_show_update_banner(info)
		_update_dialog.show_for(info))
	Updater.check_finished.connect(func(_has: bool, msg: String) -> void: _update_status.text = msg)
	Updater.check_on_startup()
	# Back from a flight: the check already ran, show what it found.
	var info: Dictionary = Updater.latest
	if not info.is_empty() and int(info.version_code) > Updater.current_version_code() \
			and str(info.apk_url) != "":
		_show_update_banner(info)
		if Updater.offered_tag != str(info.tag) and not Updater.is_downloading:
			Updater.offered_tag = str(info.tag)
			_update_dialog.show_for(info)


func _process(delta: float) -> void:
	_t += delta
	_planet.rotate_object_local(Vector3.UP, delta * 0.03)
	_moon.rotate_object_local(Vector3.UP, delta * 0.02)
	# Slow drift of the camera so the picture is alive.
	_camera.position = Vector3(-1.05 + sin(_t * 0.07) * 0.04, 0.12 + sin(_t * 0.05) * 0.03, 3.3)


func _version_name() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


func _version_code() -> int:
	return int(ProjectSettings.get_setting("starward/build/version_code", 0))


# --- 3D backdrop ----------------------------------------------------------------

func _setup_scene() -> void:
	var earth := StandardMaterial3D.new()
	earth.albedo_texture = load("res://assets/planets/earth_color.jpg")
	earth.normal_enabled = true
	earth.normal_texture = load("res://assets/planets/earth_normal.png")
	earth.normal_scale = 0.6
	earth.roughness = 0.75
	var surface := _planet.get_node("Surface") as MeshInstance3D
	surface.material_override = earth
	_planet.transform = Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(-23.4)), Vector3.ZERO)
	_planet.rotate_object_local(Vector3.UP, deg_to_rad(200.0))

	_moon = MeshInstance3D.new()
	var mm := SphereMesh.new()
	mm.radius = 0.27
	mm.height = 0.54
	mm.radial_segments = 64
	mm.rings = 32
	_moon.mesh = mm
	var mmat := StandardMaterial3D.new()
	mmat.albedo_texture = load("res://assets/planets/moon_color.jpg")
	mmat.normal_enabled = true
	mmat.normal_texture = load("res://assets/planets/moon_normal.png")
	mmat.roughness = 1.0
	_moon.material_override = mmat
	_moon.position = Vector3(3.4, 1.7, -3.2)
	add_child(_moon)

	# Sun from the upper left front: day side towards the viewer, terminator on the right.
	_sun.light_energy = 1.9
	_sun.look_at_from_position(Vector3.ZERO, Vector3(1.0, -0.3, -0.35), Vector3.UP)
	var am := _atmosphere.mesh as SphereMesh
	am.radius = 1.03
	am.height = 2.06
	var atmo := (_atmosphere.mesh as SphereMesh).material as ShaderMaterial
	atmo.set_shader_parameter("sun_dir_world", _sun.global_transform.basis.z)
	_camera.fov = 48.0
	# A hint of earthshine/starlight so the night side still reads as a disc.
	var env := ($WorldEnvironment as WorldEnvironment).environment
	env.ambient_light_color = Color(0.1, 0.12, 0.18)


# --- UI -------------------------------------------------------------------------

func _style(bg: Color, border: Color, border_w := 0, radius := 14) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


## Large left-aligned menu entry. `primary` = the orange «Играть».
func _menu_button(text: String, cb: Callable, primary := false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(440, 92 if primary else 70)
	b.add_theme_font_size_override("font_size", 38 if primary else 28)
	if primary:
		b.add_theme_stylebox_override("normal", _style(ACCENT, ACCENT.lightened(0.3), 0))
		b.add_theme_stylebox_override("hover", _style(ACCENT.lightened(0.1), ACCENT.lightened(0.3), 0))
		b.add_theme_stylebox_override("pressed", _style(ACCENT.darkened(0.2), ACCENT, 0))
		for k in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(k, Color(0.08, 0.05, 0.02))
	else:
		var n := _style(Color(0.05, 0.07, 0.12, 0.55), Color(1, 1, 1, 0.1), 1)
		var p := _style(Color(0.12, 0.16, 0.26, 0.85), ACCENT, 2)
		b.add_theme_stylebox_override("normal", n)
		b.add_theme_stylebox_override("hover", n)
		b.add_theme_stylebox_override("pressed", p)
		b.add_theme_color_override("font_color", TEXT)
		b.add_theme_color_override("font_hover_color", TEXT)
		b.add_theme_color_override("font_pressed_color", ACCENT)
	b.pressed.connect(cb)
	return b


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)

	# Darkening gradient on the left so the menu reads over any backdrop.
	var shade := TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(0, 0.01, 0.03, 0.85))
	g.set_color(1, Color(0, 0.01, 0.03, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 256
	gt.height = 4
	shade.texture = gt
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.anchor_bottom = 1.0
	shade.anchor_right = 0.6
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(shade)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.anchor_bottom = 1.0
	col.offset_left = 64
	col.offset_top = 40
	col.offset_bottom = -32
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	_ui.add_child(col)

	var title := Label.new()
	title.text = str(ProjectSettings.get_setting("application/config/name")).to_upper()
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	fv.spacing_glyph = 14
	fv.variation_embolden = 0.6
	title.add_theme_font_override("font", fv)
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", TEXT)
	col.add_child(title)
	var tag := Label.new()
	tag.text = "КОСМИЧЕСКИЙ СИМУЛЯТОР"
	var tv := FontVariation.new()
	tv.base_font = ThemeDB.fallback_font
	tv.spacing_glyph = 6
	tag.add_theme_font_override("font", tv)
	tag.add_theme_font_size_override("font_size", 22)
	tag.add_theme_color_override("font_color", ACCENT)
	col.add_child(tag)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	col.add_child(gap)

	col.add_child(_menu_button("▶  ИГРАТЬ", _play, true))

	# Rocket choice: two cards side by side, the selected one outlined.
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 10)
	col.add_child(cards)
	for r in ROCKETS:
		var c := Button.new()
		c.text = r.name
		c.toggle_mode = true
		c.focus_mode = Control.FOCUS_NONE
		c.custom_minimum_size = Vector2(215, 62)
		c.add_theme_font_size_override("font_size", 22)
		var n := _style(Color(0.05, 0.07, 0.12, 0.55), Color(1, 1, 1, 0.1), 1, 12)
		n.content_margin_left = 12
		n.content_margin_right = 12
		var sel := _style(Color(0.16, 0.12, 0.08, 0.85), ACCENT, 2, 12)
		sel.content_margin_left = 12
		sel.content_margin_right = 12
		c.add_theme_stylebox_override("normal", n)
		c.add_theme_stylebox_override("hover", n)
		c.add_theme_stylebox_override("pressed", sel)
		c.add_theme_stylebox_override("hover_pressed", sel)
		c.add_theme_color_override("font_color", DIM)
		c.add_theme_color_override("font_hover_color", DIM)
		c.add_theme_color_override("font_pressed_color", TEXT)
		c.add_theme_color_override("font_hover_pressed_color", TEXT)
		var id: String = r.id
		c.pressed.connect(func() -> void: _select_rocket(id))
		cards.add_child(c)
		_rocket_cards.append(c)
	_rocket_info = Label.new()
	_rocket_info.custom_minimum_size = Vector2(440, 0)
	_rocket_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rocket_info.add_theme_font_size_override("font_size", 18)
	_rocket_info.add_theme_color_override("font_color", DIM)
	col.add_child(_rocket_info)
	_select_rocket(Vessel.design)

	# Secondary entries in one row.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	for e in [["Ракеты", func() -> void:
				ShowcaseScript.return_scene = "res://scenes/boot.tscn"
				get_tree().change_scene_to_file("res://scenes/parts_showcase.tscn")],
			["Настройки", func() -> void: _settings.visible = not _settings.visible],
			["Выход", func() -> void: get_tree().quit()]]:
		var b := _menu_button(e[0], e[1])
		b.alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.custom_minimum_size = Vector2(140, 64)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 22)
		var st := b.get_theme_stylebox("normal") as StyleBoxFlat
		st.content_margin_left = 8
		st.content_margin_right = 8
		row.add_child(b)

	# Version, bottom-right, quiet.
	var version := Label.new()
	version.text = "v%s · сборка %d" % [_version_name(), _version_code()]
	version.add_theme_font_size_override("font_size", 20)
	version.add_theme_color_override("font_color", Color(0.6, 0.66, 0.78, 0.8))
	version.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	version.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ui.add_child(version)

	# "Update available" pill, top-right (hidden until a newer release is known).
	_update_banner = Button.new()
	_update_banner.focus_mode = Control.FOCUS_NONE
	_update_banner.add_theme_font_size_override("font_size", 22)
	_update_banner.add_theme_stylebox_override("normal", _style(Color(0.1, 0.35, 0.2, 0.9), Color(0.5, 1, 0.6), 2, 30))
	_update_banner.add_theme_stylebox_override("hover", _style(Color(0.1, 0.35, 0.2, 0.9), Color(0.5, 1, 0.6), 2, 30))
	_update_banner.add_theme_stylebox_override("pressed", _style(Color(0.15, 0.45, 0.25, 0.95), Color(0.5, 1, 0.6), 2, 30))
	_update_banner.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	_update_banner.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_update_banner.hide()
	_update_banner.pressed.connect(func() -> void:
		if not Updater.latest.is_empty():
			_update_dialog.show_for(Updater.latest))
	_ui.add_child(_update_banner)

	_settings = _build_settings()
	_settings.hide()
	_ui.add_child(_settings)

	_update_dialog = UpdateDialogScript.new()
	_ui.add_child(_update_dialog)

	_console = ConsoleScript.new()
	_console.hide()
	_ui.add_child(_console)


func _select_rocket(id: String) -> void:
	Vessel.design = id
	for i in ROCKETS.size():
		_rocket_cards[i].set_pressed_no_signal(ROCKETS[i].id == id)
		if ROCKETS[i].id == id:
			_rocket_info.text = ROCKETS[i].info


func _play() -> void:
	get_tree().change_scene_to_file("res://scenes/flight.tscn")


func _show_update_banner(info: Dictionary) -> void:
	_update_banner.text = "⬇  Доступно обновление %s" % info.get("tag", "")
	_update_banner.show()


func _build_settings() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color(0.03, 0.05, 0.1, 0.94), Color(1, 1, 1, 0.12), 1, 18))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 48)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var head := Label.new()
	head.text = "Настройки"
	head.add_theme_font_size_override("font_size", 32)
	head.add_theme_color_override("font_color", TEXT)
	box.add_child(head)

	_gfx_button = _menu_button("", func() -> void:
		Graphics.set_quality(Graphics.LOW if Graphics.quality == Graphics.HIGH else Graphics.HIGH)
		_gfx_button.text = "Графика: " + Graphics.label())
	_gfx_button.text = "Графика: " + Graphics.label()
	box.add_child(_gfx_button)
	var gfx_hint := Label.new()
	gfx_hint.text = "Низкая — без теней и детального грунта, для слабых телефонов"
	gfx_hint.custom_minimum_size = Vector2(440, 0)
	gfx_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gfx_hint.add_theme_font_size_override("font_size", 17)
	gfx_hint.add_theme_color_override("font_color", DIM)
	box.add_child(gfx_hint)

	box.add_child(_menu_button("Проверить обновление", func() -> void:
		_update_status.text = "Проверяю…"
		Updater.check_now()))
	_update_status = Label.new()
	_update_status.text = "Обновления: ещё не проверялись"
	_update_status.custom_minimum_size = Vector2(440, 0)
	_update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_update_status.add_theme_font_size_override("font_size", 18)
	_update_status.add_theme_color_override("font_color", DIM)
	box.add_child(_update_status)

	var dev := HBoxContainer.new()
	dev.add_theme_constant_override("separation", 10)
	box.add_child(dev)
	_console_button = _menu_button("Консоль", func() -> void: _console.visible = not _console.visible)
	_console_button.custom_minimum_size = Vector2(215, 60)
	_console_button.add_theme_font_size_override("font_size", 22)
	dev.add_child(_console_button)
	var copy := _menu_button("Скопировать лог", Log.copy_to_clipboard)
	copy.custom_minimum_size = Vector2(215, 60)
	copy.add_theme_font_size_override("font_size", 22)
	dev.add_child(copy)
	_update_console_button()

	box.add_child(_menu_button("Закрыть", panel.hide))
	return panel


func _update_console_button() -> void:
	if _console_button == null:
		return
	var errors := Log.error_count()
	_console_button.text = "Консоль" if errors == 0 else "Консоль (%d ош.)" % errors
