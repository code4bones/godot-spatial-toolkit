extends AnimatableBody3D
## A ground robot follows the road edges assigned by its parent.

const PROJECTILE_LAYER := 1 << 20

@export_range(1.0, 60.0, 0.5) var speed_mps := 16.0
@export_storage var from_vertex := -1
@export_storage var to_vertex := -1
@export_storage var start_fraction := 0.0
@export_storage var route_seed := 0

var _progress := 0.0
var _random := RandomNumberGenerator.new()

func _ready() -> void:
	_progress = start_fraction
	_random.seed = route_seed

func destroy() -> void:
	collision_layer = 0
	hide()
	queue_free()

func _physics_process(delta: float) -> void:
	var graph := get_parent()
	if not graph.has_method("next_vertex") or not graph.get("active") or from_vertex < 0 or to_vertex < 0:
		return
	var points: PackedVector3Array = graph.get("points")
	var budget := speed_mps * delta
	for step in 32:
		var start := points[from_vertex]
		var finish := points[to_vertex]
		var length := start.distance_to(finish)
		var distance_left := length * (1.0 - _progress)
		if budget < distance_left:
			_progress += budget / length
			position = start.lerp(finish, _progress)
			var direction := finish - start
			rotation.y = rotate_toward(rotation.y, atan2(-direction.x, -direction.z), delta * 5.0)
			return
		budget -= distance_left
		position = finish
		var next: int = graph.call("next_vertex", to_vertex, from_vertex, _random)
		from_vertex = to_vertex
		to_vertex = next
		_progress = 0.0
