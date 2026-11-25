@tool
extends RefCounted
## Deterministic, reversible decoration of native static maps. No source mutation.
signal progress(message: String, fraction: float)
const GEOMETRY := preload("res://addons/spatial_toolkit/core/world_style_geometry.gd")
const GENERATOR := "spatial_toolkit.world_style.v1"
const GENERATOR_VERSION := "0.7.0"
const FINGERPRINT_SCHEMA := 3
const TECH_ARCHETYPES := ["layered_armor", "structural_ribs", "cellular_reactor", "segmented_hull"]
const TECH_SHADER := "res://addons/spatial_toolkit/materials/alien_tech_facade.gdshader"
const PALETTE := {"dark_concrete": Color("26313e"), "oxidized_metal": Color("34434b"), "dark_glass": Color("172536")}
const GLYPHS := {"0": [14,17,19,21,25,17,14], "1": [4,12,4,4,4,4,14], "2": [14,17,1,2,4,8,31], "3": [30,1,1,14,1,1,30], "4": [2,6,10,18,31,2,2], "5": [31,16,16,30,1,1,30], "6": [14,16,16,30,17,17,14], "7": [31,1,2,4,8,8,8], "8": [14,17,17,14,17,17,14], "9": [14,17,17,15,1,1,14], "a": [14,17,17,31,17,17,17], "b": [30,17,17,30,17,17,30], "c": [15,16,16,16,16,16,15], "d": [30,17,17,17,17,17,30], "e": [31,16,16,30,16,16,31], "f": [31,16,16,30,16,16,16]}
var _busy := false
var _chunks: Dictionary = {}
var _materials: Dictionary = {}
var _report: Dictionary = {}
var _manifest: Dictionary = {}
var _spec: Dictionary = {}
var _scale := 1.0
var _seed := 0
var _error := ""
var _host: Node
var _cancelled: Callable
var _unit_box: BoxMesh

func validate_spec(spec: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	if not _integer(spec.get("schema_version")) or int(spec.get("schema_version", 0)) != 1:
		errors.append("schema_version должен быть 1.")
	if not spec.get("id") is String or str(spec.get("id", "")).strip_edges().is_empty():
		errors.append("id должен быть непустой строкой.")
	if not _integer(spec.get("seed")):
		errors.append("seed должен быть конечным целым числом.")
	for name: String in ["target", "facades", "rooftops", "signage", "performance"]:
		if not spec.get(name) is Dictionary:
			errors.append(name + " должен быть объектом.")
	if not errors.is_empty():
		return errors
	var facades: Dictionary = spec["facades"]
	if facades.has("technology"):
		if not facades["technology"] is Dictionary:
			errors.append("facades.technology должен быть объектом.")
		else:
			var technology: Dictionary = facades["technology"]
			if not technology.get("enabled") is bool:
				errors.append("facades.technology.enabled должен быть bool.")
			if technology.get("enabled", false):
				var archetypes: Variant = technology.get("archetypes")
				if not archetypes is Array or archetypes.is_empty():
					errors.append("technology.archetypes должен содержать известные варианты.")
				else:
					for name: Variant in archetypes:
						if not name is String or not name in TECH_ARCHETYPES:
							errors.append("Неизвестный технологический вариант: " + str(name))
				for key: String in ["panel_scale_m", "emission_strength"]:
					var value: Variant = technology.get(key)
					if not _number(value) or float(value) < 0.0 or (key == "panel_scale_m" and float(value) == 0.0):
						errors.append("technology." + key + " имеет неверный диапазон.")
	if spec["target"].get("preserve_source_geometry") != true:
		errors.append("target.preserve_source_geometry должен быть true.")
	for key: String in ["neon", "windows"]:
		if not facades.get(key) is Dictionary:
			errors.append("facades." + key + " должен быть объектом.")
	if not errors.is_empty():
		return errors
	for pair: Array in [[facades["neon"], "probability"], [facades["windows"], "lit_probability"], [spec["rooftops"], "prop_probability"], [spec["signage"], "large_sign_probability"]]:
		var value: Variant = pair[0].get(pair[1])
		if not _number(value) or float(value) < 0.0 or float(value) > 1.0:
			errors.append(str(pair[1]) + " должен быть от 0 до 1.")
	for pair: Array in [[facades["neon"], "enabled"], [facades["windows"], "enabled"], [spec["rooftops"], "vents"], [spec["rooftops"], "antennas"], [spec["signage"], "enabled"], [spec["signage"], "allow_generated_images"], [spec["performance"], "prefer_multimesh"]]:
		if not pair[0].get(pair[1]) is bool:
			errors.append(str(pair[1]) + " должен быть bool.")
	var palette: Variant = facades.get("palette")
	if not palette is Array or palette.is_empty():
		errors.append("facades.palette должен содержать известные имена материалов.")
	else:
		for color: Variant in palette:
			if not color is String or not PALETTE.has(color):
				errors.append("Неизвестный материал палитры: " + str(color))
	var colors: Variant = facades["neon"].get("colors")
	if not colors is Array or colors.is_empty():
		errors.append("facades.neon.colors должен содержать #RRGGBB.")
	else:
		for color: Variant in colors:
			if not color is String or str(color).length() != 7 or not str(color).begins_with("#") or not str(color).substr(1).is_valid_hex_number():
				errors.append("Цвет должен иметь формат #RRGGBB: " + str(color))
	var performance: Dictionary = spec["performance"]
	for key: String in ["max_dynamic_lights_per_chunk", "max_buildings", "max_decor_instances", "max_skin_triangles"]:
		var value: Variant = performance.get(key, 0 if key == "max_dynamic_lights_per_chunk" else 100000)
		if not _integer(value) or float(value) < (0 if key == "max_dynamic_lights_per_chunk" else 1):
			errors.append("performance." + key + " имеет неверный бюджет.")
	for key: String in ["chunk_size_m", "visibility_range_m"]:
		if performance.has(key) and (not _number(performance[key]) or float(performance[key]) < 0.0 or (key == "chunk_size_m" and float(performance[key]) == 0.0)):
			errors.append("performance." + key + " имеет неверный диапазон.")
	if spec["signage"].get("allow_generated_images", false):
		errors.append("v1 использует только процедурные вывески; generated images не поддерживаются.")
	if performance.get("prefer_multimesh") != true:
		errors.append("v1 требует performance.prefer_multimesh=true.")
	if spec.has("environment"):
		if not spec["environment"] is Dictionary:
			errors.append("environment должен быть объектом.")
		else:
			var environment: Dictionary = spec["environment"]
			if str(environment.get("preset", "source")) != "source" or environment.get("fog", false) != false or environment.get("wet_asphalt", false) != false:
				errors.append("v1 сохраняет source environment; night/fog/wet_asphalt отложены.")
	return errors

func apply(map: Node3D, spec: Dictionary, host: Node, cancelled: Callable = Callable()) -> Dictionary:
	if _busy:
		return _failure("Уже выполняется стилизация.")
	var errors := validate_spec(spec)
	if not errors.is_empty():
		return _failure(" ".join(errors))
	var existing := _existing(map)
	if not existing.get("ok", false):
		return existing
	if map.has_meta("scene_bake"):
		return _failure("Выберите исходную незапечённую карту для стилизации.")
	var buildings := map.get_node_or_null("Generated/Buildings")
	var generated := map.get_node_or_null("Generated")
	if buildings == null or generated == null or not generated.has_meta("source"):
		return _failure("Нужна исходная Generated/Buildings карта Spatial Toolkit.")
	var source_meshes: Array[MeshInstance3D] = []
	var identities := {}
	for child: Node in buildings.get_children():
		if not child is MeshInstance3D or not child.has_meta("source_id"):
			continue
		var identity := str(child.get_meta("source_id"))
		if identities.has(identity):
			return _failure("Повторный source_id: " + identity)
		identities[identity] = true
		if child.mesh == null or child.get_script() != null or child.mesh.get_blend_shape_count() > 0 or not child.skeleton.is_empty():
			return _failure("Нужен статический меш: " + identity)
		if GEOMETRY.relative(child, map).basis.determinant() <= 0.000001:
			return _failure("Mirrored/вырожденный transform не поддерживается: " + identity)
		var ancestor: Node = child
		while ancestor != map:
			if ancestor is Node3D and ancestor.top_level:
				return _failure("top_level исходного узла не поддерживается: " + identity)
			ancestor = ancestor.get_parent()
		for surface: int in child.mesh.get_surface_count():
			if child.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				return _failure("Нужны треугольники: " + identity)
		source_meshes.append(child)
	if source_meshes.is_empty():
		return _failure("Нет исходных зданий для стилизации.")
	source_meshes.sort_custom(func(a: MeshInstance3D, b: MeshInstance3D): return str(a.get_meta("source_id")) < str(b.get_meta("source_id")))
	if source_meshes.size() > int(spec["performance"].get("max_buildings", 10000)):
		return _failure("Превышен бюджет зданий; StyleLayer не изменён.")
	_scale = float(map.get_meta("world_scale", generated.get_meta("world_scale", 1.0)))
	if not is_finite(_scale) or _scale <= 0:
		return _failure("world_scale должен быть положительным.")
	_busy = true
	_host = host
	_cancelled = cancelled
	_spec = spec.duplicate(true)
	_seed = int(spec["seed"])
	_chunks = {}
	_materials = {}
	_error = ""
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE
	_report = {"buildings": source_meshes.size(), "skin_triangles": 0, "decor_instances": 0, "chunks": 0,
		"mesh_instances": 0, "multimesh_instances": 0, "materials": 0, "dynamic_lights": 0, "skipped": 0,
		"facade_mode": "procedural_alien_hull" if _technology_enabled() else "legacy_cyberpunk",
		"decor_transform_storage": "CPU-authored public MultiMesh.buffer, 12 row-major floats per 3D transform; persistent in GPU and headless saves",
		"archetype_counts": {}, "wall_triangles_styled": 0, "roof_triangles_styled": 0,
		"wall_orientation_triangles": {"pos_x": 0, "neg_x": 0, "pos_z": 0, "neg_z": 0},
		"cladding_render_policy": {"pass": "transparent_alpha_1", "depth_test": true, "depth_write": false, "receive_shadows": false, "lighting": "Source diffuse lighting retained; decorative shell does not receive source self-shadow acne", "render_priority": -75, "offset_source_m": 0.025, "order": "after map layers, before floor -70 and foundation -60"},
		"limitations": ["Procedural decorative cladding/panels, not surveyed OSM or BIM facade semantics", "No source geometry/material/collision/environment changes", "No dynamic lights; emission glow depends on renderer", "Night/fog/wet asphalt, texture generation, runtime animation and baked-map styling deferred"]}
	if _technology_enabled():
		_report["cladding_render_policy"]["lighting"] = "Unshaded procedural art lighting; source caster shadow acne cannot affect the decorative hull"
		_report["cladding_render_policy"]["coverage"] = "Every eligible source wall and roof triangle, independent of sparse decoration candidate limits"
		_report["cladding_render_policy"]["coordinates"] = "Per-feature local source-metre UV plus float CUSTOM0/1; no large district-position shader arithmetic"
	_manifest = {"schema_version": 1, "generator": GENERATOR, "generator_version": GENERATOR_VERSION,
		"style_id": str(spec["id"]), "style_seed": _seed, "units": "gameplay_meters", "world_scale": _scale,
		"spec": spec.duplicate(true), "features": [], "assets": [], "batches": [], "source_metadata": _metadata(generated),
		"cladding_render_policy": _report["cladding_render_policy"].duplicate(true),
		"geometry_policy": "Offset exact source wall/roof triangles; keep floors/foundations and actual apertures clear; decorative boxes have no collision"}
	for index: int in source_meshes.size():
		if _is_cancelled():
			_busy = false
			return {"ok": false, "cancelled": true, "error": "Стилизация отменена; StyleLayer не изменён."}
		await _build_feature(source_meshes[index], map)
		if _is_cancelled():
			_busy = false
			return {"ok": false, "cancelled": true, "error": "Стилизация отменена; StyleLayer не изменён."}
		if not _error.is_empty():
			_busy = false
			return _failure(_error)
		if (index + 1) % 8 == 0:
			progress.emit("Стилизация зданий %d/%d…" % [index + 1, source_meshes.size()], 0.05 + 0.70 * float(index + 1) / source_meshes.size())
			await host.get_tree().process_frame
	var branch := Node3D.new()
	branch.name = "GeneratedStyle"
	branch.set_meta("generated_by", GENERATOR)
	branch.set_meta("generator_version", GENERATOR_VERSION)
	branch.set_meta("fingerprint_schema", FINGERPRINT_SCHEMA)
	branch.set_meta("style_id", str(spec["id"]))
	branch.set_meta("style_seed", _seed)
	var chunk_keys: Array = _chunks.keys()
	chunk_keys.sort()
	for chunk_id: String in chunk_keys:
		if _is_cancelled():
			branch.free()
			_busy = false
			return {"ok": false, "cancelled": true, "error": "Стилизация отменена; StyleLayer не изменён."}
		_build_chunk(branch, chunk_id)
		await host.get_tree().process_frame
	if _is_cancelled():
		branch.free()
		_busy = false
		return {"ok": false, "cancelled": true, "error": "Стилизация отменена; StyleLayer не изменён."}
	_report["chunks"] = chunk_keys.size()
	_report["materials"] = _materials.size()
	_manifest["counts"] = _report.duplicate(true)
	for key: String in _materials:
		var material: Material = _materials[key]
		if material is ShaderMaterial:
			_manifest["assets"].append({"type": "ShaderMaterial", "id": key, "shader_path": TECH_SHADER, "shader_code_sha256": material.shader.code.sha256_text(),
				"provenance": "Project-authored analytic alien armour, ribs, reactor cells and hull panels; no external textures or AI image assets",
				"render_priority": material.render_priority, "panel_scale_m": material.get_shader_parameter("panel_scale_m"), "emission_strength": material.get_shader_parameter("emission_strength"),
				"attributes": {"UV": "feature-local source metre tangent/Y or roof XZ", "UV2": "normalized connected coplanar wall region, roof uses feature XZ bounds", "CUSTOM0_RGBA_FLOAT": "feature seed, archetype index, source height, roof flag", "CUSTOM1_RGBA_FLOAT": "linear accent RGB and stable face orientation phase"}})
		else:
			var standard := material as StandardMaterial3D
			_manifest["assets"].append({"type": "StandardMaterial3D", "id": key, "provenance": "Procedural project material, no external asset", "albedo_srgb": str(standard.albedo_color), "emissive": standard.emission_enabled,
				"transparency": standard.transparency, "depth_draw_mode": standard.depth_draw_mode, "receive_shadows": not standard.disable_receive_shadows, "render_priority": standard.render_priority})
	_manifest["assets"].append({"type": "BoxMesh", "id": "unit_box", "provenance": "Godot primitive; project-authored transforms and bitmap hexadecimal glyphs"})
	branch.set_meta("style_report", _report.duplicate(true))
	branch.set_meta("content_fingerprint", GEOMETRY.fingerprint(branch))
	var layer := map.get_node_or_null("StyleLayer") as Node3D
	if layer == null:
		layer = Node3D.new()
		layer.name = "StyleLayer"
		layer.set_meta("generated_by", GENERATOR)
		map.add_child(layer)
		layer.owner = map
	var previous := layer.get_node_or_null("GeneratedStyle")
	if previous != null:
		layer.remove_child(previous)
		previous.free()
	layer.add_child(branch)
	_set_owner(branch, map)
	_busy = false
	progress.emit("StyleLayer готов.", 1.0)
	return {"ok": true, "report": _report, "manifest": _manifest}

func remove(map: Node3D) -> Dictionary:
	if _busy:
		return _failure("Уже выполняется стилизация.")
	var existing := _existing(map)
	if not existing.get("ok", false):
		return existing
	var layer := map.get_node_or_null("StyleLayer")
	var branch := layer.get_node_or_null("GeneratedStyle") if layer != null else null
	if branch == null:
		return {"ok": true, "removed": false, "report": {"removed": false}}
	layer.remove_child(branch)
	branch.free()
	if layer.get_child_count() == 0 and layer.get_meta("generated_by", "") == GENERATOR:
		layer.get_parent().remove_child(layer)
		layer.free()
	return {"ok": true, "removed": true, "report": {"removed": true}}

func _existing(map: Node3D) -> Dictionary:
	var layer := map.get_node_or_null("StyleLayer")
	if layer == null:
		return {"ok": true}
	if not layer is Node3D:
		return _failure("Имя StyleLayer занято пользовательским узлом другого типа.")
	if layer.transform != Transform3D.IDENTITY or layer.top_level or layer.get_script() != null:
		return _failure("StyleLayer должен иметь единичный transform без скрипта; пользовательский слой сохранён.")
	var branch := layer.get_node_or_null("GeneratedStyle")
	if branch != null:
		if str(branch.get_meta("generated_by", "")) != GENERATOR:
			return _failure("StyleLayer/GeneratedStyle занят пользовательским узлом.")
		if str(branch.get_meta("content_fingerprint", "")) != GEOMETRY.fingerprint(branch):
			if int(branch.get_meta("fingerprint_schema", 0)) < FINGERPRINT_SCHEMA:
				return _failure("Слой предыдущей версии не прошёл проверку целостности. Сохраните его и создайте оформление из исходной карты.")
			return _failure("Сгенерированный StyleLayer изменён пользователем; сохраните эти изменения отдельно перед заменой.")
	return {"ok": true}

func _build_feature(mesh: MeshInstance3D, map: Node3D) -> void:
	var identity := str(mesh.get_meta("source_id"))
	var transform := GEOMETRY.relative(mesh, map)
	var bounds: AABB = transform * mesh.get_aabb()
	var size := float(_spec["performance"].get("chunk_size_m", 5000.0))
	var center := bounds.get_center()
	var cell := Vector2i(floori(center.x / size), floori(center.z / size))
	var chunk_id := "Chunk_%d_%d" % [cell.x, cell.y]
	if not _chunks.has(chunk_id):
		_chunks[chunk_id] = {"origin": Vector3(cell.x * size, 0, cell.y * size), "skins": {}, "boxes": {}}
	var chunk: Dictionary = _chunks[chunk_id]
	var record := {"source_id": identity, "source_node": str(map.get_path_to(mesh)), "chunk_id": chunk_id,
		"skin_triangles": 0, "decor_instances": 0, "assumption": "Procedural cladding, emissive accents and industrial props; no surveyed facade semantics"}
	var palette: Array = _spec["facades"]["palette"]
	var material_key := str(palette[mini(int(GEOMETRY.roll(_seed, identity, "palette") * palette.size()), palette.size() - 1)])
	var colors: Array = _spec["facades"]["neon"]["colors"]
	var accent := "neon_" + str(mini(int(GEOMETRY.roll(_seed, identity, "accent") * colors.size()), colors.size() - 1))
	var technology: Dictionary = {}
	if _technology_enabled():
		var variants: Array = _spec["facades"]["technology"]["archetypes"]
		var variant := str(variants[mini(int(GEOMETRY.roll(_seed, identity, "technology_variant") * variants.size()), variants.size() - 1)])
		var accent_color := Color(str(colors[accent.trim_prefix("neon_").to_int()])).srgb_to_linear()
		technology = {"seed": GEOMETRY.roll(_seed, identity, "technology_seed") * 4096.0, "variant": TECH_ARCHETYPES.find(variant), "origin": bounds.position,
			"source_height": bounds.size.y / _scale, "accent": accent_color}
		material_key = "alien_tech"
		record["archetype"] = variant
		record["technology_seed"] = technology["seed"]
		record["material_id"] = material_key
		record["wall_triangles_styled"] = 0
		record["wall_orientation_triangles"] = {"pos_x": 0, "neg_x": 0, "pos_z": 0, "neg_z": 0}
		_report["archetype_counts"][variant] = int(_report["archetype_counts"].get(variant, 0)) + 1
	var neon: bool = _spec["facades"]["neon"]["enabled"] and GEOMETRY.roll(_seed, identity, "neon") < float(_spec["facades"]["neon"]["probability"])
	var normal_basis := transform.basis.inverse().transposed()
	var roof_height := bounds.end.y
	var roof_candidates: Array[Dictionary] = []
	var wall_candidates: Array[Dictionary] = []
	var roof_edges := {}
	var excluded: Array[int] = [int(mesh.get_meta("floor_surface_index", -1)), int(mesh.get_meta("foundation_surface_index", -1))]
	if _technology_enabled():
		technology["wall_regions"] = await _wall_regions(mesh, transform, normal_basis, bounds.position, excluded)
		technology["source_size"] = bounds.size / _scale
		if _is_cancelled():
			return
	var triangles := 0
	for surface: int in mesh.mesh.get_surface_count():
		if surface in excluded:
			continue
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var count := vertices.size() if indices.is_empty() else indices.size()
		if count % 3 != 0 or normals.size() != vertices.size():
			_error = "Нужны треугольники с нормалями: " + identity
			return
		for offset: int in range(0, count, 3):
			if offset > 0 and offset % 6144 == 0:
				await _host.get_tree().process_frame
				if _is_cancelled():
					return
			var triangle := PackedVector3Array()
			var normal_values := PackedVector3Array()
			for corner: int in 3:
				var index := offset + corner if indices.is_empty() else indices[offset + corner]
				triangle.append(transform * vertices[index])
				normal_values.append((normal_basis * normals[index]).normalized())
			var normal := normal_values[0]
			var wall := absf(normal.y) < 0.05
			var roof := normal.y > 0.95 and absf(triangle[0].y - roof_height) < 0.01 * _scale and absf(triangle[1].y - roof_height) < 0.01 * _scale and absf(triangle[2].y - roof_height) < 0.01 * _scale
			if not wall and not roof:
				continue
			technology["roof"] = roof
			_add_skin(chunk, material_key, triangle, normal_values, technology)
			if not _error.is_empty():
				return
			record["skin_triangles"] += 1
			triangles += 1
			if wall:
				var orientation := ("pos_x" if normal.x >= 0.0 else "neg_x") if absf(normal.x) >= absf(normal.z) else ("pos_z" if normal.z >= 0.0 else "neg_z")
				_report["wall_triangles_styled"] += 1
				_report["wall_orientation_triangles"][orientation] += 1
				if _technology_enabled():
					record["wall_triangles_styled"] += 1
					record["wall_orientation_triangles"][orientation] += 1
				# Candidate rectangles remain strictly inside a single solid source
				# triangle. No invented panel can bridge a real window/courtyard hole.
				if wall_candidates.size() < 64:
					wall_candidates.append({"triangle": triangle, "normal": normal, "index": offset / 3})
				for edge: int in 3:
					var a := triangle[edge]
					var b := triangle[(edge + 1) % 3]
					if absf(a.y - roof_height) < 0.01 * _scale and absf(b.y - roof_height) < 0.01 * _scale and a.distance_to(b) > _scale:
						var key := str(a.snapped(Vector3.ONE * 0.01)) + str(b.snapped(Vector3.ONE * 0.01))
						roof_edges[key] = [a, b, normal]
			elif roof:
				_report["roof_triangles_styled"] += 1
				if roof_candidates.size() < 32:
					roof_candidates.append({"triangle": triangle, "normal": normal})
	if int(_report["skin_triangles"]) > int(_spec["performance"].get("max_skin_triangles", 500000)):
		_error = "Превышен бюджет треугольников облицовки; StyleLayer не изменён."
		return
	if neon:
		var edge_keys: Array = roof_edges.keys()
		edge_keys.sort()
		for edge_index: int in mini(edge_keys.size(), 12):
			var edge: Array = roof_edges[edge_keys[edge_index]]
			var a: Vector3 = edge[0]
			var b: Vector3 = edge[1]
			var normal: Vector3 = edge[2]
			var tangent := (b - a).normalized()
			_add_box(chunk, accent, GEOMETRY.box_transform((a + b) * 0.5 + normal * 0.065 * _scale + Vector3.UP * 0.10 * _scale, tangent, normal, Vector3(a.distance_to(b) * 0.94, 0.10 * _scale, 0.10 * _scale)), identity, "roof_neon", record)
	var windows: Dictionary = _spec["facades"]["windows"]
	var patch_count := 0
	for candidate_index: int in wall_candidates.size():
		var candidate: Dictionary = wall_candidates[candidate_index]
		var triangle: PackedVector3Array = candidate["triangle"]
		var normal: Vector3 = candidate["normal"]
		var tangent := Vector3(normal.z, 0, -normal.x).normalized()
		var patch_center := (triangle[0] + triangle[1] + triangle[2]) / 3.0
		var width := 1.4 * _scale
		var height := 0.55 * _scale
		if patch_center.y < bounds.position.y + 1.5 * _scale or not GEOMETRY.rectangle_supported(patch_center, tangent, Vector3.UP, width * 1.4, height * 1.4, triangle):
			continue
		if windows["enabled"] and patch_count < 10 and GEOMETRY.roll(_seed, identity, "panel_" + str(candidate_index)) < float(windows["lit_probability"]):
			_add_box(chunk, accent, GEOMETRY.box_transform(patch_center + normal * 0.06 * _scale, tangent, normal, Vector3(width, height, 0.04 * _scale)), identity, "solid_wall_panel", record)
			patch_count += 1
		if _spec["signage"]["enabled"] and GEOMETRY.roll(_seed, identity, "sign") < float(_spec["signage"]["large_sign_probability"]):
			if GEOMETRY.rectangle_supported(patch_center, tangent, Vector3.UP, 4.4 * _scale, 2.1 * _scale, triangle):
				_add_sign(chunk, identity, patch_center, tangent, normal, accent, record)
				break
	if GEOMETRY.roll(_seed, identity, "roof_props") < float(_spec["rooftops"]["prop_probability"]):
		for candidate: Dictionary in roof_candidates:
			var triangle: PackedVector3Array = candidate["triangle"]
			var point := (triangle[0] + triangle[1] + triangle[2]) / 3.0
			if not GEOMETRY.rectangle_supported(point, Vector3.RIGHT, Vector3.FORWARD, 1.4 * _scale, 1.4 * _scale, triangle):
				continue
			if _spec["rooftops"]["vents"]:
				_add_box(chunk, "hardware", Transform3D(Basis.IDENTITY.scaled(Vector3(1.2, 0.8, 1.2) * _scale), point + Vector3.UP * 0.45 * _scale), identity, "roof_vent", record)
				for fin: int in 4:
					_add_box(chunk, "hardware_edge", Transform3D(Basis.IDENTITY.scaled(Vector3(1.3, 0.05, 1.3) * _scale), point + Vector3.UP * (0.3 + fin * 0.15) * _scale), identity, "vent_louvre", record)
			if _spec["rooftops"]["antennas"]:
				_add_box(chunk, "hardware_edge", Transform3D(Basis.IDENTITY.scaled(Vector3(0.10, 3.2, 0.10) * _scale), point + Vector3.UP * 2.45 * _scale), identity, "roof_antenna", record)
				_add_box(chunk, accent, Transform3D(Basis.IDENTITY.scaled(Vector3(0.20, 0.20, 0.20) * _scale), point + Vector3.UP * 4.05 * _scale), identity, "antenna_marker", record)
			break
	if triangles == 0:
		_report["skipped"] += 1
	_manifest["features"].append(record)

func _add_skin(chunk: Dictionary, material_key: String, triangle: PackedVector3Array, normals: PackedVector3Array, technology: Dictionary = {}) -> void:
	if int(_report["skin_triangles"]) >= int(_spec["performance"].get("max_skin_triangles", 500000)):
		_error = "Превышен бюджет треугольников облицовки; StyleLayer не изменён."
		return
	var skins: Dictionary = chunk["skins"]
	if not skins.has(material_key):
		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		tool.set_material(_material(material_key))
		if material_key == "alien_tech":
			tool.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
			tool.set_custom_format(1, SurfaceTool.CUSTOM_RGBA_FLOAT)
		skins[material_key] = {"tool": tool, "triangles": 0}
	var group: Dictionary = skins[material_key]
	var tool: SurfaceTool = group["tool"]
	for corner: int in 3:
		tool.set_normal(normals[corner])
		if material_key == "alien_tech":
			var relative: Vector3 = (triangle[corner] - technology["origin"]) / _scale
			var normal := normals[0]
			var facing := Vector3(normal.z, 0, -normal.x).normalized()
			var roof: bool = technology["roof"]
			tool.set_uv(Vector2(relative.x, relative.z) if roof else Vector2(relative.dot(facing), relative.y))
			var uv2 := Vector2.ZERO
			if roof:
				var size: Vector3 = technology["source_size"]
				uv2 = Vector2(relative.x / maxf(size.x, 0.00001), relative.z / maxf(size.z, 0.00001))
			else:
				var triangle_center := (triangle[0] + triangle[1] + triangle[2]) / 3.0
				var source_center: Vector3 = (triangle_center - technology["origin"]) / _scale
				var region := _find_wall_region(technology["wall_regions"], normal, source_center, facing)
				uv2 = Vector2((relative.dot(facing) - region[0]) / maxf(region[1] - region[0], 0.00001), (relative.y - region[2]) / maxf(region[3] - region[2], 0.00001))
			tool.set_uv2(uv2.clamp(Vector2.ZERO, Vector2.ONE))
			tool.set_custom(0, Color(float(technology["seed"]), float(technology["variant"]), float(technology["source_height"]), 1.0 if roof else 0.0))
			var color: Color = technology["accent"]
			var orientation := 4.0 if roof else fposmod(floorf((atan2(normal.z, normal.x) + PI + 0.00001) / (PI * 0.5)), 4.0)
			tool.set_custom(1, Color(color.r, color.g, color.b, orientation))
		tool.add_vertex(triangle[corner] + normals[corner] * 0.025 * _scale - chunk["origin"])
	group["triangles"] += 1
	_report["skin_triangles"] += 1

func _wall_regions(mesh: MeshInstance3D, transform: Transform3D, normal_basis: Basis, origin: Vector3, excluded: Array[int]) -> Dictionary:
	# Normalize the actual connected wall span, not an entire building AABB.
	# Collinear but disconnected wings must each receive readable technology.
	var groups := {}
	for surface: int in mesh.mesh.get_surface_count():
		if surface in excluded:
			continue
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var count := vertices.size() if indices.is_empty() else indices.size()
		if count % 3 != 0 or normals.size() != vertices.size():
			continue # Main generation reports malformed source arrays.
		for offset: int in range(0, count, 3):
			if offset > 0 and offset % 6144 == 0:
				await _host.get_tree().process_frame
				if _is_cancelled():
					return groups
			var first := offset if indices.is_empty() else indices[offset]
			var normal := (normal_basis * normals[first]).normalized()
			if absf(normal.y) >= 0.05:
				continue
			var tangent := Vector3(normal.z, 0, -normal.x).normalized()
			var key := str(normal.snapped(Vector3.ONE * 0.0001))
			var source_first := (transform * vertices[first] - origin) / _scale
			var distance := normal.dot(source_first)
			if not groups.has(key):
				groups[key] = []
			var plane: Dictionary = {}
			for candidate: Dictionary in groups[key]:
				if absf(float(candidate["distance"]) - distance) <= 0.03:
					plane = candidate
					break
			if plane.is_empty():
				plane = {"distance": distance, "intervals": [], "regions": []}
				groups[key].append(plane)
			var span := Vector4(INF, -INF, INF, -INF)
			for corner: int in 3:
				var index := offset + corner if indices.is_empty() else indices[offset + corner]
				var point := (transform * vertices[index] - origin) / _scale
				var u := point.dot(tangent)
				span.x = minf(span.x, u)
				span.y = maxf(span.y, u)
				span.z = minf(span.z, point.y)
				span.w = maxf(span.w, point.y)
			plane["intervals"].append(span)
	for key: String in groups:
		for plane: Dictionary in groups[key]:
			var intervals: Array = plane["intervals"]
			intervals.sort_custom(func(a: Vector4, b: Vector4): return a.x < b.x)
			var regions: Array[Vector4] = []
			for span: Vector4 in intervals:
				if regions.is_empty() or span.x > regions[-1].y + 0.03:
					regions.append(span)
				else:
					var previous: Vector4 = regions[-1]
					regions[-1] = Vector4(previous.x, maxf(previous.y, span.y), minf(previous.z, span.z), maxf(previous.w, span.w))
			plane["regions"] = regions
			plane.erase("intervals")
	return groups

func _find_wall_region(groups: Dictionary, normal: Vector3, source_center: Vector3, tangent: Vector3) -> Vector4:
	var key := str(normal.snapped(Vector3.ONE * 0.0001))
	var distance := normal.dot(source_center)
	var u := source_center.dot(tangent)
	for plane: Dictionary in groups.get(key, []):
		if absf(float(plane["distance"]) - distance) > 0.03:
			continue
		for region: Vector4 in plane["regions"]:
			if u >= region.x - 0.03 and u <= region.y + 0.03:
				return region
	# Degenerate/sliver geometry still receives finite stable attributes. Normal
	# native walls always resolve to their exact plane/connected interval above.
	return Vector4(u - 0.5, u + 0.5, source_center.y - 0.5, source_center.y + 0.5)

func _add_box(chunk: Dictionary, material_key: String, transform: Transform3D, source_id: String, kind: String, record: Dictionary) -> void:
	if int(_report["decor_instances"]) >= int(_spec["performance"].get("max_decor_instances", 100000)):
		_error = "Превышен бюджет декоративных экземпляров; StyleLayer не изменён."
		return
	if not chunk["boxes"].has(material_key):
		chunk["boxes"][material_key] = []
	transform.origin -= chunk["origin"]
	chunk["boxes"][material_key].append({"transform": transform, "source_id": source_id, "kind": kind})
	_report["decor_instances"] += 1
	record["decor_instances"] += 1

func _add_sign(chunk: Dictionary, identity: String, center: Vector3, tangent: Vector3, normal: Vector3, accent: String, record: Dictionary) -> void:
	_add_box(chunk, "hardware", GEOMETRY.box_transform(center + normal * 0.07 * _scale, tangent, normal, Vector3(4.2, 1.9, 0.08) * _scale), identity, "sign_backplate", record)
	var code := (str(_seed) + "|" + identity).sha256_text().substr(0, 3)
	var pixel := 0.17 * _scale
	for character: int in 3:
		var rows: Array = GLYPHS[code[character]]
		for row: int in 7:
			for column: int in 5:
				if int(rows[row]) & (1 << (4 - column)) == 0:
					continue
				var offset := tangent * (float(character * 6 + column) - 8.0) * pixel + Vector3.UP * (3.0 - row) * pixel
				_add_box(chunk, accent, GEOMETRY.box_transform(center + offset + normal * 0.13 * _scale, tangent, normal, Vector3(pixel * 0.75, pixel * 0.75, 0.02 * _scale)), identity, "sign_glyph_" + code, record)

func _build_chunk(branch: Node3D, chunk_id: String) -> void:
	var chunk: Dictionary = _chunks[chunk_id]
	var node := Node3D.new()
	node.name = chunk_id
	node.position = chunk["origin"]
	branch.add_child(node)
	var keys: Array = chunk["skins"].keys()
	keys.sort()
	for key: String in keys:
		var tool: SurfaceTool = chunk["skins"][key]["tool"]
		tool.index()
		var mesh := MeshInstance3D.new()
		mesh.name = "Cladding_" + key
		mesh.mesh = tool.commit()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = float(_spec["performance"].get("visibility_range_m", 0.0))
		node.add_child(mesh)
		_report["mesh_instances"] += 1
		_manifest["batches"].append({"node": "StyleLayer/GeneratedStyle/" + chunk_id + "/" + str(mesh.name), "type": "cladding", "material": key, "triangles": chunk["skins"][key]["triangles"]})
	keys = chunk["boxes"].keys()
	keys.sort()
	for key: String in keys:
		var records: Array = chunk["boxes"][key]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = _unit_box
		multimesh.instance_count = records.size()
		var provenance: Array = []
		# Author the public buffer on the CPU. Per-instance RenderingServer
		# setters silently lose their data under the headless dummy renderer.
		var instance_buffer := PackedFloat32Array()
		instance_buffer.resize(records.size() * 12)
		for index: int in records.size():
			var pose: Transform3D = records[index]["transform"]
			var offset := index * 12
			instance_buffer[offset] = pose.basis.x.x
			instance_buffer[offset + 1] = pose.basis.y.x
			instance_buffer[offset + 2] = pose.basis.z.x
			instance_buffer[offset + 3] = pose.origin.x
			instance_buffer[offset + 4] = pose.basis.x.y
			instance_buffer[offset + 5] = pose.basis.y.y
			instance_buffer[offset + 6] = pose.basis.z.y
			instance_buffer[offset + 7] = pose.origin.y
			instance_buffer[offset + 8] = pose.basis.x.z
			instance_buffer[offset + 9] = pose.basis.y.z
			instance_buffer[offset + 10] = pose.basis.z.z
			instance_buffer[offset + 11] = pose.origin.z
			provenance.append({"instance": index, "source_id": records[index]["source_id"], "kind": records[index]["kind"]})
		multimesh.buffer = instance_buffer
		var instance := MultiMeshInstance3D.new()
		instance.name = "Decor_" + key
		instance.multimesh = multimesh
		instance.material_override = _material(key)
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.visibility_range_end = float(_spec["performance"].get("visibility_range_m", 0.0))
		node.add_child(instance)
		_report["multimesh_instances"] += 1
		_manifest["batches"].append({"node": "StyleLayer/GeneratedStyle/" + chunk_id + "/" + str(instance.name), "type": "MultiMeshInstance3D", "material": key, "instances": provenance})

func _material(key: String) -> Material:
	if _materials.has(key):
		return _materials[key]
	if key == "alien_tech":
		var material := ShaderMaterial.new()
		material.resource_name = "WorldStyle_AlienTech"
		material.shader = load(TECH_SHADER) as Shader
		# Explicit values for every uniform prevent editor default materialization
		# from changing an otherwise untouched generated ownership fingerprint.
		material.set_shader_parameter("panel_scale_m", float(_spec["facades"]["technology"]["panel_scale_m"]))
		material.set_shader_parameter("emission_strength", float(_spec["facades"]["technology"]["emission_strength"]))
		material.render_priority = -75
		_materials[key] = material
		return material
	var material := StandardMaterial3D.new()
	material.resource_name = "WorldStyle_" + key
	material.roughness = 0.85
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if key.begins_with("neon_"):
		var index := key.trim_prefix("neon_").to_int()
		var color := Color(str(_spec["facades"]["neon"]["colors"][index]))
		material.albedo_color = color
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 2.0
	else:
		material.albedo_color = PALETTE.get(key, Color("34414e") if key == "hardware" else Color("687786"))
		material.metallic = 0.25 if key in ["oxidized_metal", "hardware", "hardware_edge"] else 0.05
		if PALETTE.has(key):
			# Cladding shares the source silhouette; a tiny offset alone cannot
			# resolve far-depth quantization. Keep source opaque occlusion, then
			# draw its full-alpha skin after map layers and before floors/bases.
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			material.render_priority = -75
			# The authoritative mesh still casts shadows. Its offset visual skin
			# must not receive the same near-coincident caster's shadow acne.
			material.disable_receive_shadows = true
	_materials[key] = material
	return material

func _technology_enabled() -> bool:
	return bool(_spec.get("facades", {}).get("technology", {}).get("enabled", false))

func _is_cancelled() -> bool:
	return _cancelled.is_valid() and bool(_cancelled.call())

func _metadata(node: Node) -> Dictionary:
	var result := {}
	for key: StringName in node.get_meta_list():
		result[str(key)] = node.get_meta(key)
	return result

func _set_owner(node: Node, owner_node: Node) -> void:
	node.owner = owner_node
	for child: Node in node.get_children():
		_set_owner(child, owner_node)

func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}

func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value)) and absf(float(value)) <= 2147483647.0
