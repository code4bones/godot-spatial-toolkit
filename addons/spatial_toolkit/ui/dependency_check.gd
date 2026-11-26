@tool
extends VBoxContainer

const ImportService := preload("res://addons/spatial_toolkit/core/map_import_service.gd")
const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")

var _service := ImportService.new()
var _check: Button
var _cancel: Button
var _result: RichTextLabel

func _ready() -> void:
	_service.set_process(false)
	add_child(_service)
	_service.completed.connect(_on_completed)

	var actions := HBoxContainer.new()
	add_child(actions)
	_check = Button.new()
	_check.name = "CheckDependencies"
	_check.text = "Проверить зависимости"
	_check.tooltip_text = "Проверяет выбранный Python, pyproj и GEOS."
	_check.pressed.connect(_check_dependencies)
	actions.add_child(_check)
	_cancel = Button.new()
	_cancel.text = "Отменить"
	_cancel.hide()
	_cancel.pressed.connect(_service.cancel)
	actions.add_child(_cancel)

	_result = RichTextLabel.new()
	_result.name = "DependencyCheckResult"
	_result.custom_minimum_size.y = 92.0 * EditorInterface.get_editor_scale()
	_result.selection_enabled = true
	_result.hide()
	add_child(_result)

func _exit_tree() -> void:
	_service.shutdown()

func _check_dependencies() -> void:
	if _service.busy:
		return
	_result.show()
	var started := _service.check_dependencies(Settings.python_executable())
	if not started.get("ok", false):
		_on_completed(started)
		return
	_check.disabled = true
	_cancel.show()
	_result.text = "Проверка зависимостей…"

func _on_completed(result: Dictionary) -> void:
	_check.disabled = false
	_cancel.hide()
	if not result.get("ok", false):
		_result.text = "Проверка отменена." if result.get("cancelled", false) else str(result.get("error", "Проверка не удалась."))
		return
	var versions: Dictionary = result.get("dependencies", {})
	_result.text = "Зависимости доступны.\nPython %s\npyproj %s\nGEOS %s" % [
		versions["python"], versions["pyproj"], versions["GEOS"]]
