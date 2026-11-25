@tool
extends VBoxContainer

const Colors := preload("res://addons/spatial_toolkit/core/facade_colors.gd")

var _undo: EditorUndoRedoManager
var _map: Node3D
var _groups := {}
var _types := OptionButton.new()
var _color := ColorPickerButton.new()
var _apply := Button.new()
var _reset := Button.new()
var _busy := false

func setup(undo: EditorUndoRedoManager) -> void:
	_undo = undo
	name = "FacadeColors"
	var label := Label.new()
	label.text = "Цвета фасадов по типу"
	add_child(label)
	var row := HBoxContainer.new()
	add_child(row)
	_types.name = "BuildingType"
	_types.fit_to_longest_item = false
	_types.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_types.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_types.item_selected.connect(func(_index: int) -> void: _refresh_color())
	row.add_child(_types)
	_color.name = "BaseColor"
	_color.custom_minimum_size.x = 44
	_color.edit_alpha = false
	row.add_child(_color)
	var actions := HBoxContainer.new()
	add_child(actions)
	_apply.text = "Применить цвет"
	_apply.pressed.connect(func() -> void: _set_color(_color.color))
	actions.add_child(_apply)
	_reset.text = "Сбросить"
	_reset.pressed.connect(func() -> void: _set_color(null))
	actions.add_child(_reset)
	if _undo != null:
		_undo.version_changed.connect(_refresh_groups, CONNECT_DEFERRED)
	_refresh_groups()

func refresh_scene(root: Node) -> void:
	_map = root as Node3D
	_refresh_groups()

func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_buttons()

func _refresh_groups() -> void:
	var previous := _type_id()
	_groups = Colors.groups(_map if is_instance_valid(_map) else null)
	_types.clear()
	var sorted := _groups.keys()
	sorted.sort_custom(func(a: String, b: String) -> bool:
		return str(Colors.LABELS.get(a, a)).naturalnocasecmp_to(str(Colors.LABELS.get(b, b))) < 0)
	for kind: String in sorted:
		_types.add_item("%s (%d)" % [Colors.LABELS.get(kind, kind), _groups[kind].size()])
		var index := _types.item_count - 1
		_types.set_item_metadata(index, kind)
		_types.get_popup().set_item_tooltip(index, "building=" + kind)
		if kind == previous:
			_types.select(index)
	visible = not _groups.is_empty()
	_refresh_color()

func _type_id() -> String:
	return str(_types.get_item_metadata(_types.selected)) if _types.selected >= 0 else ""

func _rules() -> Dictionary:
	return _map.get_meta(Colors.RULES, {}) if is_instance_valid(_map) else {}

func _refresh_color() -> void:
	var kind := _type_id()
	var rules := _rules()
	if _groups.has(kind):
		_color.color = rules[kind] if rules.has(kind) else Colors.sample_color(_groups[kind][0])
		_color.tooltip_text = "Цвет типа здания" if rules.has(kind) else "Исходный цвет одного здания из группы"
	_refresh_buttons()

func _refresh_buttons() -> void:
	var editable := _undo != null and not _busy and _groups.has(_type_id())
	_types.disabled = not editable
	_color.disabled = not editable
	_apply.disabled = not editable
	_reset.disabled = not editable or not _rules().has(_type_id())

func _set_color(color: Variant) -> void:
	var kind := _type_id()
	if _busy or _undo == null or not is_instance_valid(_map) or not _groups.has(kind):
		return
	var previous := _rules()
	if previous.get(kind) == color:
		return
	var rules := previous.duplicate()
	if color == null:
		rules.erase(kind)
	else:
		rules[kind] = color
	_undo.create_action("Изменить базовый цвет фасадов", UndoRedo.MERGE_DISABLE, _map)
	_undo.add_do_method(_map, "set_meta", Colors.RULES, rules if not rules.is_empty() else null)
	_undo.add_undo_method(_map, "set_meta", Colors.RULES, previous if _map.has_meta(Colors.RULES) else null)
	for change in Colors.changes(_groups[kind], color):
		var building: MeshInstance3D = change["building"]
		var property: String = change["property"]
		_undo.add_do_property(building, property, change["material"])
		_undo.add_undo_property(building, property, building.get(property))
	_undo.commit_action()
	_refresh_color()
