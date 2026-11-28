@tool
extends RefCounted
## Resolves layer settings into the generated meshes' saved render materials.

const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const Style := preload("res://addons/spatial_toolkit/core/map_style_module.gd")
const Ground := preload("res://addons/spatial_toolkit/core/ground_styles.gd")
const Roofs := preload("res://addons/spatial_toolkit/core/roof_styles.gd")
const Groups := preload("res://addons/spatial_toolkit/core/facade_groups.gd")
const Colors := preload("res://addons/spatial_toolkit/core/facade_colors.gd")
const Windows := preload("res://addons/spatial_toolkit/core/facade_windows.gd")
const WindowPreview := preload("res://addons/spatial_toolkit/runtime/facade_window_preview.gd")
const ORIGINAL := &"spatial_layer_original_material"


static func can_assign_material(_layer: SpatialLayer3D, material: Material) -> bool:
	return material == null or material is StandardMaterial3D or Ground.supports_material(material)


static func apply(map: Node) -> void:
	var cache := {}
	var bank: Resource = map.get("attribute_bank") if "attribute_bank" in map else null
	var defaults: Dictionary = bank.facade_colors if bank != null else {}
	var window_count := 0
	var window_buildings := 0
	for layer in Layers.style_nodes(map):
		for mesh in _direct_meshes(layer):
			if mesh.mesh == null:
				continue
			var settings := Layers.effective(mesh)
			if layer.style_kind == "Buildings":
				if not defaults.is_empty():
					var base: Variant = defaults.get(Colors.type_id(mesh))
					if base is Color:
						settings["base_tint"] = base
				var individual := mesh.get_meta(Groups.INDIVIDUAL) as Material if mesh.has_meta(Groups.INDIVIDUAL) else null
				if individual != null:
					settings["material"] = individual
				if settings.has("roof_variants"):
					var variant := Roofs.pick_variant(mesh, settings["roof_variants"])
					settings.erase("roof_variants")
					settings.erase("roof_material")
					if variant != null:
						var roof_settings := variant.style_values()
						for field: String in roof_settings:
							settings["roof_" + field] = roof_settings[field]
			_apply_mesh(mesh, layer.style_kind, settings, float(map.get_meta("world_scale", 1.0)), cache)
			if layer.style_kind == "Buildings" and mesh.has_meta(Windows.METADATA):
				var count := int(mesh.get_meta(Windows.METADATA).get("count", 0))
				window_count += count
				window_buildings += int(count > 0)
	var generated := map.get_node_or_null("Generated")
	if generated != null:
		var modules: Dictionary = generated.get_meta("modules", {})
		if modules.has("facade_windows"):
			modules["facade_windows"]["count"] = window_count
			modules["facade_windows"]["buildings"] = window_buildings


static func _direct_meshes(layer: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if layer is MeshInstance3D:
		result.append(layer as MeshInstance3D)
	else:
		for child in layer.get_children():
			if child is MeshInstance3D and child.has_meta("source_id"):
				result.append(child)
	return result


static func _apply_mesh(mesh: MeshInstance3D, kind: String, settings: Dictionary,
		scale_factor: float, cache: Dictionary) -> void:
	if kind == "Buildings":
		var layout := settings.get("window_layout") as SpatialWindowLayout
		settings.erase("window_layout")
		if layout != null or mesh.has_meta(Windows.BASE_LAYOUT):
			var atlas := Windows.relayout(mesh, layout, _has_facade_material(mesh))
			if not atlas.is_empty():
				settings["window_layout_atlas"] = atlas
	if mesh.material_override != null:
		_apply_slot(mesh, "material_override", mesh.material_override, kind, settings, scale_factor, cache)
		return
	var modeled_openings: PackedInt32Array = mesh.get_meta("measured_opening_surfaces", PackedInt32Array())
	for index in mesh.mesh.get_surface_count():
		if index in modeled_openings:
			continue
		var active := mesh.get_active_material(index)
		var overrides := settings
		if kind == "Buildings" and index == int(mesh.get_meta("foundation_surface_index", -1)):
			var foundation_tint: Variant = settings.get("tint", settings.get("base_tint"))
			overrides = {"tint": foundation_tint} if foundation_tint is Color else {}
		elif kind == "Buildings" and index == int(mesh.get_meta("floor_surface_index", -1)):
			overrides = {}
		_apply_slot(mesh, "surface_material_override/%d" % index, active, kind, overrides, scale_factor, cache)


static func _apply_slot(mesh: MeshInstance3D, slot: String, active: Material, kind: String,
		settings: Dictionary, scale_factor: float, cache: Dictionary) -> void:
	if active == null:
		return
	var own := mesh.get(slot) as Material
	var original: Array = own.get_meta(ORIGINAL, [active, own]) if own != null else [active, null]
	if settings.is_empty():
		if own != original[1]:
			mesh.set(slot, original[1])
		return
	var key := [kind, original, settings]
	if not cache.has(key):
		var source := original[0] as Material
		var updated := _material(source, kind, settings, scale_factor)
		if updated != source:
			updated.set_meta(ORIGINAL, original)
			cache[key] = updated
		else:
			cache[key] = original[1]
	mesh.set(slot, cache[key])


static func _material(source: Material, kind: String, settings: Dictionary, scale_factor: float) -> Material:
	var selected := settings.get("material") as Material
	var tint: Variant = settings.get("tint")
	var repeat_m := float(settings.get("texture_repeat_m", 0.0))
	var facade := source as ShaderMaterial
	if _uses_shader(facade, Style.FACADE_SHADER_PATH):
		return _facade(facade, selected, tint, repeat_m, settings)
	if kind != "Buildings" and facade != null and selected != null and can_assign_material(null, selected):
		var textured := Ground._make_surface(facade, Ground.BACKGROUND if kind == "FlatGround" else 1,
			selected, scale_factor)
		textured.render_priority = facade.render_priority
		_set_surface_values(textured, tint, repeat_m, scale_factor)
		return textured
	if facade != null and (facade.shader == Ground.FLAT or facade.shader == Ground.TEXTURED or facade.shader == Ground.TERRAIN):
		var edited := facade.duplicate() as ShaderMaterial
		_set_surface_values(edited, tint, repeat_m, scale_factor)
		return edited
	if source is StandardMaterial3D:
		var use_selected := selected is StandardMaterial3D
		var original := (selected if use_selected else source) as StandardMaterial3D
		if tint == null and not use_selected:
			tint = settings.get("base_tint")
		var repeat_texture := repeat_m > 0.0 and original.albedo_texture != null
		if not use_selected and tint == null and not repeat_texture:
			return source
		var standard := original.duplicate() as StandardMaterial3D
		if tint is Color:
			standard.albedo_color = tint
		if repeat_texture:
			standard.uv1_triplanar = true
			standard.uv1_scale = Vector3.ONE / (repeat_m * scale_factor)
		return standard
	return source


static func _facade(source: ShaderMaterial, selected: Material, tint: Variant,
		repeat_m: float, settings: Dictionary) -> ShaderMaterial:
	var edited: ShaderMaterial
	if selected != null:
		edited = Style._selected_facade(source, selected)
		if selected is StandardMaterial3D and selected.albedo_texture == null:
			edited = Style._selected_facade(source, null)
			edited.set_shader_parameter("wall_color", selected.albedo_color)
	var roof := Roofs.styled_material(edited if edited != null else source,
		settings.get("roof_material") as Material, settings.get("roof_tint"),
		float(settings.get("roof_texture_repeat_m", 0.0)))
	if roof != null:
		edited = roof
	if edited == null:
		edited = source.duplicate() as ShaderMaterial
	if tint is Color:
		edited.set_shader_parameter("wall_color", tint)
	elif settings.get("base_tint") is Color \
			and not (selected is StandardMaterial3D and selected.albedo_texture == null):
		edited.set_shader_parameter("wall_color", settings["base_tint"])
	if repeat_m > 0.0 and edited.get_shader_parameter("finish_albedo") is Texture2D:
		edited.set_shader_parameter("finish_repeat_m", repeat_m)
	if settings.has("facade_variation"):
		edited.set_shader_parameter("facade_texture_blend", settings["facade_variation"])
	if settings.has("facade_weathering"):
		edited.set_shader_parameter("facade_weathering_strength", settings["facade_weathering"])
	if settings.has("decorative_windows"):
		edited.set_shader_parameter("hide_decorative_windows", int(settings["decorative_windows"]) == 2)
	var window_style := settings.get("window_style") as SpatialWindowStyle
	if window_style != null:
		edited.set_shader_parameter("match_window_palette", true)
		edited.set_shader_parameter("window_frame_color", window_style.frame_color)
		edited.set_shader_parameter("glass_color", window_style.glass_color)
		edited.set_shader_parameter("window_grille_style", window_style.distant_grille)
	if settings.has("window_layout_atlas"):
		WindowPreview.configure_section_layout(edited, settings["window_layout_atlas"],
			float(source.get_shader_parameter("floor_height")))
	return edited


static func _has_facade_material(mesh: MeshInstance3D) -> bool:
	for surface in mesh.mesh.get_surface_count():
		if _uses_shader(mesh.get_active_material(surface) as ShaderMaterial, Style.FACADE_SHADER_PATH):
			return true
	return false


static func _set_surface_values(material: ShaderMaterial, tint: Variant, repeat_m: float,
		scale_factor: float) -> void:
	var textured := material.shader == Ground.TEXTURED or material.shader == Ground.TERRAIN
	if tint is Color:
		material.set_shader_parameter("surface_tint" if textured else "surface_color", tint)
	if textured and repeat_m > 0.0:
		material.set_shader_parameter("repeat_size", repeat_m * scale_factor)


static func _uses_shader(material: ShaderMaterial, path: String) -> bool:
	return material != null and material.shader != null and material.shader.resource_path == path
