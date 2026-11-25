@tool
extends VBoxContainer

const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")
const GroundEdit := preload("res://addons/spatial_toolkit/ui/ground_style_edit.gd")

var _undo: EditorUndoRedoManager
var _editor: EditorInterface
var _map: Node3D
var _layers := OptionButton.new()
var _picker := EditorResourcePicker.new()
var _color := ColorPickerButton.new()
var _apply := Button.new()
var _reset_material := Button.new()
var _reset_color := Button.new()
var _assigned_material: Resource
var _assigned_override: Resource
var _assigned_color := Color.WHITE
var _assigned_color_override: Variant
var _material_dirty := false
var _color_dirty := false
var _refreshing := false
var _busy := false

func setup(editor: EditorInterface, undo: EditorUndoRedoManager) -> void:
	_editor = editor
	_undo = undo
	name = "GroundStyle"
	var label := Label.new()
	label.text = "Земля"
	add_child(label)
	_layers.name = "GroundLayer"
	_layers.fit_to_longest_item = false
	_layers.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_layers.item_selected.connect(func(_index: int) -> void: _refresh_assignment(true, true))
	add_child(_layers)
	_picker.name = "GroundMaterial"
	_picker.base_type = "Material,Texture2D"
	_picker.resource_changed.connect(func(_resource: Resource) -> void:
		if not _refreshing:
			_material_dirty = true
			_refresh_buttons())
	_picker.resource_selected.connect(func(resource: Resource, _inspect: bool) -> void:
		_editor.inspect_object(resource, "", true))
	add_child(_picker)
	var row := HBoxContainer.new()
	add_child(row)
	var color_label := Label.new()
	color_label.text = "Цвет земли"
	color_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(color_label)
	_color.name = "GroundColor"
	_color.edit_alpha = false
	_color.custom_minimum_size.x = 44
	_color.color_changed.connect(func(_value: Color) -> void:
		if not _refreshing:
			_color_dirty = true
			_refresh_buttons())
	row.add_child(_color)
	_apply.text = "Применить к земле"
	_apply.pressed.connect(_apply_changes)
	add_child(_apply)
	var resets := HBoxContainer.new()
	add_child(resets)
	_reset_material.text = "Сбросить материал"
	_reset_material.pressed.connect(_restore_material)
	resets.add_child(_reset_material)
	_reset_color.text = "Сбросить цвет"
	_reset_color.pressed.connect(_restore_color)
	resets.add_child(_reset_color)
	if _undo != null:
		_undo.version_changed.connect(_refresh_assignment, CONNECT_DEFERRED)
	refresh_scene(_editor.get_edited_scene_root())

func refresh_scene(scene: Node) -> void:
	_map = scene as Node3D
	_layers.clear()
	if is_instance_valid(_map):
		for slot in Ground.LABELS.size():
			var count := Ground.targets(_map, slot).size()
			if count > 0:
				_layers.add_item("%s (%d)" % [Ground.LABELS[slot], count], slot)
	visible = _layers.item_count > 0
	_refresh_assignment(true, true)

func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_buttons()

func _slot() -> int:
	return _layers.get_selected_id() if _layers.selected >= 0 else -1

func _refresh_assignment(force_material := false, force_color := false) -> void:
	if not is_instance_valid(_map) or _slot() < 0:
		_refresh_buttons()
		return
	var slot := _slot()
	var material := Ground.selected_material(_map, slot)
	var override := Ground.override_material(_map, slot)
	var color := Ground.selected_color(_map, slot)
	var color_override: Variant = Ground.override_color(_map, slot)
	_refreshing = true
	if force_material or material != _assigned_material or override != _assigned_override:
		_picker.edited_resource = material
		_material_dirty = false
	if force_color or color != _assigned_color or color_override != _assigned_color_override:
		_color.color = color
		_color_dirty = false
	_assigned_material = material
	_assigned_override = override
	_assigned_color = color
	_assigned_color_override = color_override
	_refreshing = false
	_refresh_buttons()

func _refresh_buttons() -> void:
	var editable := is_instance_valid(_map) and _slot() >= 0 and _undo != null and not _busy
	_layers.disabled = not editable
	_picker.editable = editable
	_color.disabled = not editable
	var material := _picker.edited_resource
	var valid := material == null or Ground.supports_material(material)
	_apply.disabled = not editable or not valid or not (_material_dirty or _color_dirty)
	_reset_material.disabled = not editable or _assigned_override == null
	_reset_color.disabled = not editable or _assigned_color_override == null
	_picker.tooltip_text = "Материал или текстура земли" if valid else "Выберите текстуру или материал с цветовой текстурой"

func _apply_changes() -> void:
	if _apply.disabled:
		return
	var material := _picker.edited_resource if _material_dirty else Ground.override_material(_map, _slot())
	var color: Variant = _color.color if _color_dirty else Ground.override_color(_map, _slot())
	GroundEdit.commit(_undo, _map, _slot(), material, color)
	_refresh_assignment(true, true)

func _restore_material() -> void:
	if _reset_material.disabled:
		return
	GroundEdit.commit(_undo, _map, _slot(), null, Ground.override_color(_map, _slot()))
	_refresh_assignment(true, false)

func _restore_color() -> void:
	if _reset_color.disabled:
		return
	GroundEdit.commit(_undo, _map, _slot(), Ground.override_material(_map, _slot()), null)
	_refresh_assignment(false, true)
