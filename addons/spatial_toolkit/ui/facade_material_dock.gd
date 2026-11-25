@tool
extends VBoxContainer

const Groups := preload("res://addons/spatial_toolkit/core/facade_groups.gd")
const Roofs := preload("res://addons/spatial_toolkit/core/roof_styles.gd")
const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")
const GroundEdit := preload("res://addons/spatial_toolkit/ui/ground_style_edit.gd")
const Style := preload("res://addons/spatial_toolkit/core/map_style_module.gd")
const Catalog := preload("res://addons/spatial_toolkit/ui/material_catalog.gd")

var _editor: EditorInterface
var _undo: EditorUndoRedoManager
var _target := OptionButton.new()
var _group := OptionButton.new()
var _preview := CheckBox.new()
var _preview_hidden: Array[VisualInstance3D] = []
var _picker := EditorResourcePicker.new()
var _picker_label := Label.new()
var _assigned_material: Resource
var _show_selection := false
var _roof_defaults: Dictionary = {}
var _status := Label.new()
var _only: Button
var _inherit: Button
var _apply: Button
var _reset_ground: Button

func setup(editor: EditorInterface, undo: EditorUndoRedoManager) -> void:
	_editor = editor
	_undo = undo
	name = "Asset Browser"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_target.add_item("Фасады")
	_target.add_item("Крыши")
	_target.add_item("Земля")
	_target.item_selected.connect(func(_index: int) -> void: _refresh())
	add_child(_target)
	var group_row := HBoxContainer.new()
	add_child(group_row)
	_group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group.allow_reselect = true
	_group.item_selected.connect(func(_index: int) -> void:
		_show_selection = false
		_sync_assignment(true)
		_update_preview())
	group_row.add_child(_group)
	var refresh := _button(group_row, "↻", _refresh)
	refresh.tooltip_text = "Обновить группы открытой карты"
	_preview.text = "Preview"
	_preview.tooltip_text = "Показать только здания выбранной группы в 3D-редакторе"
	_preview.toggled.connect(func(_enabled: bool) -> void: _update_preview())
	add_child(_preview)
	_picker_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_picker_label)
	_picker.base_type = "Material"
	_picker.resource_changed.connect(func(_resource: Resource) -> void: _refresh_buttons())
	_picker.resource_selected.connect(func(resource: Resource, _inspect: bool) -> void:
		_editor.inspect_object(resource, "", true))
	add_child(_picker)
	_apply = _button(self, "Применить к группе", _apply_group)
	_reset_ground = _button(self, "Вернуть исходный материал земли", _restore_ground_material)
	_only = _button(self, "Применить к выбранным зданиям", _apply_individual)
	_inherit = _button(self, "Вернуть материал группы", _inherit_group)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	var catalog := Catalog.new()
	catalog.setup(_editor)
	catalog.material_imported.connect(func(material: StandardMaterial3D) -> void:
		_picker.edited_resource = material
		_refresh_buttons())
	add_child(catalog)
	_editor.get_selection().selection_changed.connect(_selection_changed)
	_undo.version_changed.connect(_sync_assignment, CONNECT_DEFERRED)
	refresh_scene(_map())

func _button(parent: Control, caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _map() -> Node3D:
	return _editor.get_edited_scene_root() as Node3D

func _buildings() -> Array[MeshInstance3D]:
	var buildings: Array[MeshInstance3D] = []
	var map := _map()
	var layer := map.get_node_or_null("Generated/Buildings") if map != null else null
	if layer != null:
		for child in layer.get_children():
			if child is MeshInstance3D and child.mesh != null:
				buildings.append(child)
	return buildings

func _selected_buildings() -> Array[MeshInstance3D]:
	var selected: Array[MeshInstance3D] = []
	var map := _map()
	var layer := map.get_node_or_null("Generated/Buildings") if map != null else null
	if layer == null:
		return selected
	for node in _editor.get_selection().get_selected_nodes():
		if node is MeshInstance3D and node.get_parent() == layer and node.mesh != null:
			selected.append(node)
	return selected

func refresh_scene(_root: Node) -> void:
	_show_selection = not _selected_buildings().is_empty()
	_refresh()

func _exit_tree() -> void:
	_clear_preview()

func _clear_preview() -> void:
	for visual in _preview_hidden:
		if is_instance_valid(visual):
			RenderingServer.instance_set_visible(visual.get_instance(), visual.is_visible_in_tree())
	_preview_hidden.clear()

func _hide_preview_visual(node: Node) -> void:
	if node is VisualInstance3D:
		RenderingServer.instance_set_visible(node.get_instance(), false)
		_preview_hidden.append(node)
	for child in node.get_children():
		_hide_preview_visual(child)

func _roof_mode() -> bool:
	return _target.selected == 1

func _ground_mode() -> bool:
	return _target.selected == 2

func _building_group(building: MeshInstance3D) -> int:
	return Roofs.variant_id(building) if _roof_mode() else Groups.group_id(building)

func _update_preview() -> void:
	_clear_preview()
	var id := _group.get_selected_id()
	if _ground_mode() or not _preview.button_pressed or id < 0:
		return
	var selected_sources := {}
	for building in _buildings():
		if _building_group(building) == id:
			selected_sources[building.get_meta("source_id", "")] = true
			for alias in building.get_meta("coincident_source_ids", []):
				selected_sources[alias] = true
		else:
			_hide_preview_visual(building)
	var map := _map()
	var windows := map.get_node_or_null("BreakableWindows") if map != null else null
	if windows != null:
		for window in windows.get_children():
			if not selected_sources.has(window.get_meta("source_id", "")):
				_hide_preview_visual(window)

func _refresh() -> void:
	_preview.visible = not _ground_mode()
	if _ground_mode():
		_refresh_ground()
		return
	var previous := _group.get_selected_id()
	var selected := _selected_buildings()
	if _show_selection and not selected.is_empty():
		previous = _building_group(selected[0])
	var counts := {}
	for building in _buildings():
		var id := _building_group(building)
		counts[id] = counts.get(id, 0) + 1
	_group.clear()
	var ids := counts.keys()
	var roof_mode := _roof_mode()
	if roof_mode and not counts.is_empty():
		ids = range(Roofs.DEFAULTS.size())
	ids.sort()
	for id: int in ids:
		var label := "Вариант %d" % (id + 1) if roof_mode else Groups.label(id)
		_group.add_item("%s (%d)" % [label, counts.get(id, 0)], id)
	if ids.has(previous):
		_group.select(_group.get_item_index(previous))
	_status.text = "Откройте сцену карты Spatial." if ids.is_empty() else ""
	_preview.disabled = ids.is_empty()
	_sync_assignment(true)
	_update_preview()

func _refresh_ground() -> void:
	var previous := _group.get_selected_id()
	var map := _map()
	_group.clear()
	for slot in Ground.LABELS.size():
		var surfaces := Ground.targets(map, slot)
		if not surfaces.is_empty():
			_group.add_item("%s (%d)" % [Ground.LABELS[slot], surfaces.size()], slot)
	var index := _group.get_item_index(previous)
	if index >= 0:
		_group.select(index)
	_show_selection = false
	_status.text = "Откройте сцену карты Spatial." if _group.item_count == 0 else ""
	_sync_assignment(true)
	_update_preview()

func _selection_changed() -> void:
	if _ground_mode():
		return
	var selected := _selected_buildings()
	_show_selection = not selected.is_empty()
	if _show_selection:
		var index := _group.get_item_index(_building_group(selected[0]))
		if index >= 0:
			_group.select(index)
	_sync_assignment(true)
	_update_preview()

func _albedo(material: Material) -> Texture2D:
	if material is StandardMaterial3D:
		return material.albedo_texture
	if material is ShaderMaterial:
		return material.get_shader_parameter("road_albedo") as Texture2D
	return null

func _sync_assignment(reset_picker := false) -> void:
	var map := _map()
	var id := _group.get_selected_id()
	var roof_mode := _roof_mode()
	var assigned: Resource
	_picker_label.text = "Материал крыши" if roof_mode else "Материал группы"
	if map != null and id >= 0:
		if _ground_mode():
			_picker_label.text = "Материал земли"
			assigned = Ground.selected_material(map, id)
		elif roof_mode:
			assigned = _roof_material(map, id)
		else:
			var selected := _selected_buildings()
			if not _show_selection or selected.is_empty():
				var groups: Dictionary = map.get_meta(Groups.GROUPS, {})
				assigned = groups.get(id) as Material
			else:
				_picker_label.text = "Материал фасада" if selected.size() == 1 else "Материал фасадов"
				assigned = Groups.selected_material(map, selected[0])
				for index in range(1, selected.size()):
					if Groups.selected_material(map, selected[index]) != assigned:
						_picker_label.text = "Выбраны фасады с разными материалами"
						assigned = null
						break
	if reset_picker or assigned != _assigned_material:
		if assigned is Texture2D:
			var texture_material := StandardMaterial3D.new()
			texture_material.resource_name = assigned.resource_path.get_file()
			texture_material.albedo_texture = assigned
			_picker.edited_resource = texture_material
		else:
			_picker.edited_resource = assigned
	_assigned_material = assigned
	_refresh_buttons()

func _roof_material(map: Node3D, id: int) -> Material:
	var variants: Dictionary = map.get_meta(Roofs.SLOTS, {})
	var assigned := variants.get(id) as Material
	if assigned != null:
		return assigned
	if not _roof_defaults.has(id):
		var material := Roofs.default_material(id)
		if material != null:
			_roof_defaults[id] = material
	return _roof_defaults.get(id) as Material

func _refresh_buttons() -> void:
	var ground_mode := _ground_mode()
	var usable := _albedo(_picker.edited_resource as Material) != null
	if ground_mode:
		usable = Ground.supports_material(_picker.edited_resource)
	var roof_mode := _roof_mode()
	var selected := _selected_buildings()
	var id := _group.get_selected_id()
	_apply.text = "Применить к крышам варианта" if roof_mode else "Применить к группе"
	if ground_mode:
		_apply.text = "Применить к земле"
	_apply.disabled = not usable or id < 0
	_only.visible = not roof_mode and not ground_mode
	_inherit.visible = not roof_mode and not ground_mode
	_reset_ground.visible = ground_mode
	_reset_ground.disabled = not ground_mode or id < 0 or Ground.override_material(_map(), id) == null
	_only.disabled = not usable or selected.is_empty()
	_inherit.disabled = selected.is_empty()


func _apply_group() -> void:
	var map := _map()
	var id := _group.get_selected_id()
	var resource := _picker.edited_resource
	if map == null or resource == null or id < 0 or _apply.disabled:
		return
	if _ground_mode():
		var ground_count := GroundEdit.commit(_undo, map, id, resource, Ground.override_color(map, id))
		_sync_assignment(true)
		_status.text = "Обновлено поверхностей земли · %d" % ground_count
		return
	var material := resource as Material
	var roof_mode := _roof_mode()
	var key := Roofs.SLOTS if roof_mode else Groups.GROUPS
	var previous: Dictionary = map.get_meta(key, {})
	var rules := previous.duplicate()
	rules[id] = material
	var action := "Apply roof material variant" if roof_mode else "Apply facade material to building group"
	_undo.create_action(action, UndoRedo.MERGE_DISABLE, map)
	_undo.add_do_method(map, "set_meta", key, rules)
	_undo.add_undo_method(map, "set_meta", key, previous if map.has_meta(key) else null)
	var count := 0
	for building in _buildings():
		if _building_group(building) == id and (roof_mode or not building.has_meta(Groups.INDIVIDUAL)):
			count += int(_track_update(building, material, roof_mode))
	_undo.commit_action()
	_show_selection = false
	_sync_assignment(true)
	_status.text = "Обновлено крыш · %d" % count if roof_mode else "Обновлено зданий в группе · %d" % count

func _restore_ground_material() -> void:
	var map := _map()
	var id := _group.get_selected_id()
	if map == null or id < 0 or not _ground_mode():
		return
	var count := GroundEdit.commit(_undo, map, id, null, Ground.override_color(map, id))
	_sync_assignment(true)
	_status.text = "Обновлено поверхностей земли · %d" % count

func _apply_individual() -> void:
	_set_individual(_picker.edited_resource as Material)

func _inherit_group() -> void:
	_set_individual(null)

func _set_individual(material: Material) -> void:
	var selected := _selected_buildings()
	var map := _map()
	if map == null or selected.is_empty():
		return
	var rules: Dictionary = map.get_meta(Groups.GROUPS, {})
	_undo.create_action("Set individual facade material", UndoRedo.MERGE_DISABLE, map)
	var count := 0
	for building in selected:
		var chosen := material if material != null else rules.get(Groups.group_id(building)) as Material
		if not _track_update(building, chosen):
			continue
		var previous: Variant = building.get_meta(Groups.INDIVIDUAL) if building.has_meta(Groups.INDIVIDUAL) else null
		_undo.add_do_method(building, "set_meta", Groups.INDIVIDUAL, material)
		_undo.add_undo_method(building, "set_meta", Groups.INDIVIDUAL, previous)
		count += 1
	_undo.commit_action()
	_selection_changed()
	_status.text = "Обновлено выбранных зданий: %d" % count

func _track_update(building: MeshInstance3D, material: Material, roof_mode := false) -> bool:
	var changes := Roofs.updates(building, material) if roof_mode else Style.facade_updates(building, material)
	for change in changes:
		_undo.add_do_property(building, change["property"], change["material"])
		_undo.add_undo_property(building, change["property"], building.get(change["property"]))
	return not changes.is_empty()
