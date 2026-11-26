@tool
extends RefCounted
## Optional saved flight overlay; source map meshes remain authoritative.

const GENERATOR := "spatial_toolkit.map_flight.v1"
const Layers := preload("res://addons/spatial_toolkit/core/spatial_layers.gd")
const Localization := preload("res://addons/spatial_toolkit/ui/editor_localization.gd")
const Drone := preload("res://addons/spatial_toolkit/runtime/spatial_drone.gd")
const DroneCamera := preload("res://addons/spatial_toolkit/runtime/drone_camera.gd")
const PLAYER_NAME := "FlyPlayer"
const AUDIO_DEFAULTS_SETTING := "spatial_toolkit/flight/audio_defaults"
const DEFAULT_CONTROLLER := Drone.DEFAULT_CONTROLLER
const CONTROLLERS := Drone.CONTROLLERS
const CONTROLLER_LABELS := {
	"signed_wheel_drone": "Классический",
	"viewport_bank": "Крен и слежение у края · эксперимент",
}
const CRAFT := preload("res://addons/spatial_toolkit/runtime/micro_ship.tscn")
const EYE_HEIGHT := 0.7
const DEFAULT_BODY_HEIGHT := 34.3
const CAPSULE_RADIUS := 0.35
const CAPSULE_HEIGHT := 1.8

static func apply_to_scene(map: Node3D, controller := DEFAULT_CONTROLLER,
		model_scene: PackedScene = null) -> Dictionary:
	if not CONTROLLERS.has(controller):
		return {"success": false, "error": Localization.translate("Unknown drone controller: %s") % controller}
	if not map.is_inside_tree():
		return {"success": false, "error": Localization.translate("Attach the map root to the scene tree before adding flight.")}
	var overview := map.get_node_or_null("OverviewCamera") as Camera3D
	var generated := map.get_node_or_null("Generated") as Node3D
	if overview == null or generated == null:
		return {"success": false, "error": Localization.translate("Flight requires Generated geometry and OverviewCamera.")}
	var previous := map.get_node_or_null(PLAYER_NAME)
	if previous != null:
		if previous is CharacterBody3D and previous.get_meta("generated_by", "") == GENERATOR:
			if previous.get_node_or_null("CameraPivot/CameraBoom/FlyCamera") is Camera3D:
				return _report(previous as CharacterBody3D, 0, 1)
			return {"success": false, "error": Localization.translate("The existing flight overlay has no camera. The overlay was preserved.")}
		return {"success": false, "error": Localization.translate("An authored node already uses the name FlyPlayer. The node was preserved.")}

	var craft := CRAFT.instantiate() as Node3D
	var model: Node3D
	var mount: Marker3D
	if model_scene != null:
		var instance := model_scene.instantiate() if model_scene.get_state().get_node_count() > 0 else null
		model = instance as Node3D
		if model == null or model is CollisionObject3D \
				or not model.find_children("*", "CollisionObject3D", true, false).is_empty():
			if instance != null:
				instance.free()
			craft.free()
			return {"success": false, "error": Localization.translate("The drone model must be a Node3D scene without physics bodies or areas.")}
		mount = craft.get_node("RocketMount") as Marker3D
		craft.remove_child(mount)
		craft.free()
		craft = Node3D.new()
		craft.add_child(mount)
		model.name = "Model"
		craft.add_child(model)

	var district := _district_bounds(map, generated)
	var center := Vector3(district.get_center().x, 0, district.get_center().z)
	var start := _spawn_position(map, generated, center)
	var player := Drone.new()
	player.name = PLAYER_NAME
	player.flight_controller = Drone.CONTROLLER_IDS.find(controller)
	player.invert_ws = bool(ProjectSettings.get_setting(DroneCamera.INVERT_WS_SETTING, false))
	player.position = start
	player.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	player.collision_layer = 2
	player.collision_mask = 1
	player.floor_snap_length = 0.0
	player.safe_margin = 0.01
	player.set_meta("generated_by", GENERATOR)
	player.set_meta("units", "meters")
	player.set_meta("source", generated.get_meta("source", {}))
	player.set_meta("spawn_assumption", "Near district center/nearest road bounds; flat ground assumed, elevated above overlapping building bounds")
	var capsule := CapsuleShape3D.new()
	capsule.radius = CAPSULE_RADIUS
	capsule.height = CAPSULE_HEIGHT
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = capsule
	player.add_child(collision)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	pivot.position.y = EYE_HEIGHT
	pivot.rotation_degrees.x = -12.0
	var toward_center := center - Vector3(start.x, 0, start.z)
	if toward_center.length_squared() > 1.0:
		pivot.rotation.y = atan2(-toward_center.x, -toward_center.z)
	player.add_child(pivot)
	var boom := SpringArm3D.new()
	boom.name = "CameraBoom"
	var camera_sweep := SphereShape3D.new()
	camera_sweep.radius = 0.15
	boom.shape = camera_sweep
	boom.collision_mask = 1
	boom.margin = 0.12
	boom.spring_length = 3.0
	boom.add_excluded_object(player.get_rid())
	pivot.add_child(boom)
	var camera := Camera3D.new()
	camera.name = "FlyCamera"
	camera.position.z = 3.0
	camera.far = maxf(20000.0, district.size.length() * 2.0 + start.y)
	camera.current = true
	boom.add_child(camera)
	craft.name = "FlightCraft"
	craft.position.y = EYE_HEIGHT
	craft.rotation = Vector3(pivot.rotation.x, pivot.rotation.y, 0)
	craft.visible = true
	player.add_child(craft)

	# Add the complete native rig before assigning its runtime script. In native
	# import tests Engine.is_editor_hint() is false: running _ready during this
	# build would detach the chase pivot and serialize its runtime global offset.
	map.add_child(player)
	for node: Node in [player, collision, pivot, boom, camera, craft]:
		node.owner = map
	if model != null:
		model.owner = map
		mount.owner = map
		if model.scene_file_path.is_empty():
			for child: Node in model.find_children("*", "", true, false):
				if child.owner == model:
					child.owner = map
	camera.set_script(CONTROLLERS[controller])
	_apply_audio_defaults(camera)
	camera.set("overview_camera_path", NodePath("../../../../OverviewCamera"))
	camera.set("map_legend_path", NodePath("../../../../PreviewLegend/Legend"))
	camera.set("third_person", true)
	# Set after script/view configuration: the uninitialized runtime controller
	# can use its close-plane fallback until the SpringArm's first physics step.
	# Saved rigs start in third person; runtime then adapts to actual clearance.
	camera.near = 0.5
	overview.current = false
	camera.current = true
	return _report(player, 1, 0)

static func _apply_audio_defaults(camera: Camera3D) -> void:
	var settings: Variant = ProjectSettings.get_setting(AUDIO_DEFAULTS_SETTING, {})
	if not settings is Dictionary or settings.is_empty():
		return
	for channel: String in ["engine", "throttle", "launch", "impact"]:
		var audio_key := channel + "_audio"
		var path: Variant = settings.get(audio_key)
		if path is String and not path.is_empty():
			var stream := load(path) as AudioStream if ResourceLoader.exists(path, "AudioStream") else null
			if stream != null:
				camera.set(audio_key, stream)
			else:
				push_warning("Spatial Toolkit: unavailable default audio " + path)
		var volume_key := channel + "_volume_db"
		var volume: Variant = settings.get(volume_key)
		if (volume is float or volume is int) and is_finite(float(volume)):
			camera.set(volume_key, clampf(float(volume), -80.0, 6.0))

static func _report(player: CharacterBody3D, created: int, existing: int) -> Dictionary:
	var controller: String = player.get_meta("flight_controller", DEFAULT_CONTROLLER)
	if player is Drone:
		controller = Drone.CONTROLLER_IDS[player.flight_controller]
	return {"success": true, "created": created, "existing": existing,
		"start_position_m": [player.position.x, player.position.y, player.position.z],
		"units": "meters", "collision_layer": 2, "collision_mask": 1,
		"controller": controller, "default_view": "third_person"}

static func _local_bounds(map: Node3D, mesh: MeshInstance3D) -> AABB:
	var local_from_mesh := map.global_transform.affine_inverse() * mesh.global_transform
	return local_from_mesh * mesh.get_aabb()

static func _district_bounds(map: Node3D, generated: Node3D) -> AABB:
	var result := AABB()
	var first := true
	for node in generated.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null:
			continue
		var bounds := _local_bounds(map, mesh)
		result = bounds if first else result.merge(bounds)
		first = false
	return result

static func _spawn_position(map: Node3D, generated: Node3D, center: Vector3) -> Vector3:
	var start := Vector3(center.x, DEFAULT_BODY_HEIGHT, center.z)
	var roads := generated.get_node_or_null("Roads")
	var nearest := INF
	for mesh in Layers.meshes(roads):
		if mesh.mesh == null:
			continue
		var road_center := _local_bounds(map, mesh).get_center()
		var distance := Vector2(road_center.x - center.x, road_center.z - center.z).length_squared()
		if distance < nearest:
			nearest = distance
			start.x = road_center.x
			start.z = road_center.z
	for mesh in Layers.buildings(map):
		if mesh.mesh == null:
			continue
		var bounds := _local_bounds(map, mesh)
		if start.x >= bounds.position.x - CAPSULE_RADIUS and start.x <= bounds.end.x + CAPSULE_RADIUS and start.z >= bounds.position.z - CAPSULE_RADIUS and start.z <= bounds.end.z + CAPSULE_RADIUS:
			start.y = maxf(start.y, bounds.end.y + CAPSULE_HEIGHT * 0.5 + 5.0)
	return start
