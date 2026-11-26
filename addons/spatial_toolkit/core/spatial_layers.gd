@tool
extends RefCounted
## Generated hierarchy, membership and inherited values.

const Groups := preload("res://addons/spatial_toolkit/core/facade_groups.gd")
const Layer := preload("res://addons/spatial_toolkit/core/spatial_layer_3d.gd")
const BuildingLayer := preload("res://addons/spatial_toolkit/core/spatial_building_layer_3d.gd")


static func layer_for(roots: Dictionary, groups: Dictionary, kind: String,
		feature: MeshInstance3D, owner: Node, osm_rules: Dictionary = {}) -> Node:
	var layer: SpatialLayer3D = roots[kind]
	var tags: Dictionary = feature.get_meta("source_tags", {})
	match kind:
		"Buildings":
			var id := Groups.group_id(feature, osm_rules)
			@warning_ignore("integer_division")
			var height := id / Groups.BUCKET_COUNT
			var area := id % Groups.BUCKET_COUNT
			layer = _subgroup(layer, groups, "height:%d" % height,
				"Height_%s_m" % _range_name(Groups.height_label(height, osm_rules)), owner)
			layer = _subgroup(layer, groups, "area:%d" % area,
				"Area_%s_m2" % _range_name(Groups.area_label(area, osm_rules)), owner)
		"Landuse":
			var landuse := _tag(tags, "landuse")
			if _tag(tags, "leisure") == "park":
				landuse = "park"
			layer = _tag_group(layer, groups, landuse, owner)
		"Roads":
			layer = _tag_group(layer, groups, _tag(tags, "surface"), owner)
		"Paths":
			layer = _tag_group(layer, groups, _tag(tags, "highway"), owner)
			layer = _tag_group(layer, groups, _tag(tags, "surface"), owner)
		"Water":
			layer = _tag_group(layer, groups, _tag(tags, "water"), owner)
		"PlannedRoads":
			layer = _tag_group(layer, groups, _tag(tags, "highway"), owner)
	return layer


static func new_root(kind: String) -> SpatialLayer3D:
	var layer := BuildingLayer.new() if kind == "Buildings" else Layer.new()
	layer.name = kind
	layer.style_key = kind
	layer.style_kind = kind
	return layer


static func _range_name(label: String) -> String:
	return label.replace("< ", "under_").replace("–", "-").replace(".", "_")


static func _subgroup(parent: SpatialLayer3D, groups: Dictionary, id: String,
		label: String, owner: Node) -> SpatialLayer3D:
	var key := parent.style_key + "/" + id.uri_encode()
	if parent.style_kind == "Buildings":
		key = parent.style_key + "/" + id
	if groups.has(key):
		return groups[key]
	var layer := new_root(parent.style_kind)
	layer.name = label
	layer.style_key = key
	parent.add_child(layer, true)
	layer.owner = owner
	groups[key] = layer
	return layer


static func _tag_group(parent: SpatialLayer3D, groups: Dictionary, id: String, owner: Node) -> SpatialLayer3D:
	return _subgroup(parent, groups, id, id.capitalize().validate_node_name(), owner)


static func _tag(tags: Dictionary, name: String) -> String:
	var value := str(tags.get(name, "")).strip_edges().to_lower()
	return value if not value.is_empty() else "unspecified"


static func meshes(layer: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if layer != null:
		_collect_meshes(layer, result)
	return result


static func _collect_meshes(layer: Node, result: Array[MeshInstance3D]) -> void:
	if layer is MeshInstance3D:
		result.append(layer)
		return
	for child in layer.get_children():
		if child is MeshInstance3D:
			result.append(child)
		elif child is SpatialLayer3D:
			_collect_meshes(child, result)


static func buildings(map: Node) -> Array[MeshInstance3D]:
	return meshes(map.get_node_or_null("Generated/Buildings")) if map != null else []


static func root_kind(mesh: Node) -> String:
	if mesh is SpatialLayer3D:
		return mesh.style_kind
	var parent := mesh.get_parent()
	if parent is SpatialLayer3D:
		return parent.style_kind
	return str(parent.name) if parent != null else ""


static func style_nodes(map: Node) -> Array[SpatialLayer3D]:
	var result: Array[SpatialLayer3D] = []
	if map == null:
		return result
	var ground := map.get_node_or_null("FlatGround") as SpatialLayer3D
	if ground != null:
		result.append(ground)
	var generated := map.get_node_or_null("Generated")
	if generated != null:
		_collect_style_nodes(generated, result)
	return result


static func _collect_style_nodes(parent: Node, result: Array[SpatialLayer3D]) -> void:
	for child in parent.get_children():
		if child is SpatialLayer3D:
			result.append(child)
			_collect_style_nodes(child, result)


static func building_group_key(id: int) -> String:
	@warning_ignore("integer_division")
	var height := id / Groups.BUCKET_COUNT
	var area := id % Groups.BUCKET_COUNT
	return "Buildings/height:%d/area:%d" % [height, area]


static func node_for_building_group(map: Node, id: int) -> SpatialBuildingLayer3D:
	var key := building_group_key(id)
	for layer in style_nodes(map):
		if layer.style_key == key:
			return layer as SpatialBuildingLayer3D
	return null


static func effective(mesh_or_layer: Node) -> Dictionary:
	var values := {}
	var layer := mesh_or_layer as SpatialLayer3D
	if layer == null:
		layer = mesh_or_layer.get_parent() as SpatialLayer3D
	while layer != null:
		values.merge(layer.style_values())
		layer = layer.get_parent() as SpatialLayer3D
	return values


static func can_assign_material(layer: SpatialLayer3D, material: Material) -> bool:
	var appearance := load("res://addons/spatial_toolkit/core/layer_appearance.gd") as Script
	return appearance.can_assign_material(layer, material)


static func apply(map: Node) -> void:
	if map == null or map.has_meta("scene_bake"):
		return
	var appearance := load("res://addons/spatial_toolkit/core/layer_appearance.gd") as Script
	appearance.apply(map)
