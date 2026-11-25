extends Node
## Optional visual models mounted on the map's existing flight and patrol rigs.

const BUSTER_CLIP := &"Start_Liftoff"
const MECH_CLIP := &"Take 001"
# These poses nearly match on either side of the authored hover loop.
const HOVER_START := 20.3
const HOVER_END := 22.833333
const ACTIVE_LOOP := &"area_13/hover"
const CRAFT_VISUALS := [&"Hull", &"Cockpit", &"PortWing", &"StarboardWing", &"PortTip", &"StarboardTip",
	&"PortEngine", &"StarboardEngine", &"PortExhaust", &"StarboardExhaust", &"NoseStripe", &"TailFin"]
const PATROL_MESHES := [&"Hull", &"LeftTrack", &"RightTrack", &"Head", &"Visor"]
const CRAFT_TRAILS := [^"PortTrail", ^"StarboardTrail"]

@export var buster_model: PackedScene
@export var mech_model: PackedScene

var _models: Array[WeakRef] = []
var _fallback_visuals: Array[WeakRef] = []
var _active_trails: Array[WeakRef] = []

func _ready() -> void:
	_install.call_deferred()

func _install() -> void:
	if is_queued_for_deletion():
		return
	var map := get_parent().get_parent()
	var craft := map.get_node_or_null("FlyPlayer/FlightCraft") as Node3D
	if craft != null and buster_model != null:
		_install_buster(craft)
	if mech_model == null:
		return
	var patrols := map.get_node_or_null("RoadPatrols")
	if patrols == null:
		map.child_entered_tree.connect(_on_map_child)
	else:
		_install_patrols(patrols)

func _on_map_child(child: Node) -> void:
	if child.name == &"RoadPatrols":
		# The runtime graph creates its robots just after entering the tree.
		_install_patrols.call_deferred(child)

func _install_buster(craft: Node3D) -> void:
	var model := buster_model.instantiate() as Node3D
	var showroom := model.find_child("Env", true, false) as Node3D
	if showroom != null:
		showroom.hide()
	model.name = "BusterDrone"
	model.position = Vector3(0.0, 0.025, -0.025)
	model.rotation.y = PI
	model.scale = Vector3.ONE * 0.23
	var player := _prepare_loop(model, BUSTER_CLIP)
	if player == null:
		model.free()
		return
	_mount(craft, model, CRAFT_VISUALS)
	for path: NodePath in CRAFT_TRAILS:
		var trail := craft.get_node_or_null(path) as CPUParticles3D
		if trail != null:
			_hide_fallback(trail)
			if trail.emitting:
				_active_trails.append(weakref(trail))
				trail.emitting = false
	player.play_section(ACTIVE_LOOP, HOVER_START, HOVER_END)
	player.advance(0.0)

func _install_patrols(patrols: Node) -> void:
	if not is_instance_valid(patrols) or is_queued_for_deletion():
		return
	for robot in patrols.get_children():
		if robot is Node3D and robot.is_in_group(&"spatial_road_patrol") and not robot.has_node("MechDrone"):
			_install_mech(robot)

func _install_mech(robot: Node3D) -> void:
	var model := mech_model.instantiate() as Node3D
	model.name = "MechDrone"
	# Keep the animated body within the patrol's existing 1.19 m hitbox.
	model.scale = Vector3.ONE * 2.5
	var player := _prepare_loop(model, MECH_CLIP)
	if player == null:
		model.free()
		return
	_mount(robot, model, PATROL_MESHES)
	player.play(ACTIVE_LOOP)
	var duration := player.get_animation(ACTIVE_LOOP).length
	player.seek(fposmod(float(robot.get("route_seed")) * 0.73, duration), true)

func _prepare_loop(model: Node3D, source: StringName) -> AnimationPlayer:
	var player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null or not player.has_animation(source):
		push_warning("Spatial Toolkit: missing drone animation " + source)
		return null
	var motion := player.get_animation(source).duplicate() as Animation
	motion.loop_mode = Animation.LOOP_LINEAR
	if source == MECH_CLIP:
		# The patrolling body sets its heading from the current road edge.
		for track in motion.get_track_count():
			if motion.track_get_type(track) == Animation.TYPE_ROTATION_3D \
					and motion.track_get_path(track).get_concatenated_subnames() == &"Body_00":
				motion.track_set_enabled(track, false)
	var library := AnimationLibrary.new()
	library.add_animation(&"hover", motion)
	player.add_animation_library(&"area_13", library)
	return player

func _mount(host: Node3D, model: Node3D, fallback_names: Array) -> void:
	for name: StringName in fallback_names:
		var mesh := host.get_node_or_null(NodePath(name)) as MeshInstance3D
		if mesh != null:
			_hide_fallback(mesh)
	host.add_child(model)
	_models.append(weakref(model))

func _hide_fallback(visual: Node3D) -> void:
	if visual.visible:
		_fallback_visuals.append(weakref(visual))
		visual.hide()

func _exit_tree() -> void:
	for reference in _models:
		var model := reference.get_ref() as Node3D
		if model != null:
			model.queue_free()
	for reference in _fallback_visuals:
		var visual := reference.get_ref() as Node3D
		if visual != null:
			visual.show()
	for reference in _active_trails:
		var trail := reference.get_ref() as CPUParticles3D
		if trail != null:
			trail.emitting = true
