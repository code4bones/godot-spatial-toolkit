@tool
extends RefCounted
## Translations for editor controls owned by Spatial Toolkit.

const DOMAIN := &"addons/spatial_toolkit"
const CATALOGS := "res://addons/spatial_toolkit/locale"

static func install(locale: String) -> void:
	var domain := TranslationServer.get_or_add_domain(DOMAIN)
	domain.set_locale_override(locale)
	for file: String in DirAccess.get_files_at(CATALOGS):
		if file.get_extension() == "po":
			var translation := ResourceLoader.load(CATALOGS.path_join(file), "Translation") as Translation
			if translation != null:
				domain.add_translation(translation)

static func uninstall() -> void:
	if TranslationServer.has_domain(DOMAIN):
		TranslationServer.remove_domain(DOMAIN)

static func translate(message: StringName) -> String:
	if not TranslationServer.has_domain(DOMAIN):
		return str(message)
	return str(TranslationServer.get_or_add_domain(DOMAIN).translate(message))

static func localize_inspector_group(property: Dictionary) -> void:
	if Engine.is_editor_hint() and (int(property["usage"]) & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP)) != 0:
		var heading: StringName = property["name"]
		if not heading.is_empty():
			property["name"] = translate(heading)
