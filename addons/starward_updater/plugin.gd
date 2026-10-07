@tool
extends EditorPlugin
## Registers the Kotlin updater AAR (built by CI from android_plugin/) for Android exports.

var _export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	const AAR := "starward_updater/bin/starward-updater-release.aar"

	func _get_name() -> String:
		return "StarwardUpdater"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		if not FileAccess.file_exists("res://addons/" + AAR):
			push_warning("StarwardUpdater: %s not built, exporting without the updater plugin" % AAR)
			return PackedStringArray()
		return PackedStringArray([AAR])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray(["androidx.core:core:1.13.1"])
