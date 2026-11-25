extends Node3D
## One-shot impact audio and visuals. The particles have no collision bodies.

const SOUND_PATH := "res://addons/spatial_toolkit/assets/audio/rocket_impact.mp3"
const FLASH_SECONDS := 0.15

var sound_override: AudioStream
var volume_db := -6.0
var _flash_age := 0.0
var _parts_remaining := 2
@onready var _flash := $Flash as MeshInstance3D
@onready var _flash_material := _flash.material_override as StandardMaterial3D

func _ready() -> void:
	var smoke := $Smoke as CPUParticles3D
	var sound := $ImpactSound as AudioStreamPlayer3D
	smoke.finished.connect(_finish_part, CONNECT_ONE_SHOT)
	sound.finished.connect(_finish_part, CONNECT_ONE_SHOT)
	($Sparks as CPUParticles3D).restart()
	smoke.restart()
	sound.stream = sound_override
	if sound.stream == null and ResourceLoader.exists(SOUND_PATH, "AudioStream"):
		sound.stream = load(SOUND_PATH) as AudioStream
	sound.volume_db = volume_db
	if sound.stream != null:
		sound.play()
	else:
		_finish_part()

func _finish_part() -> void:
	_parts_remaining -= 1
	if _parts_remaining == 0:
		queue_free()

func _process(delta: float) -> void:
	_flash_age += delta
	var progress := clampf(_flash_age / FLASH_SECONDS, 0.0, 1.0)
	_flash.scale = Vector3.ONE * lerpf(0.55, 3.1, ease(progress, 0.45))
	_flash_material.albedo_color = Color(1.0, 0.45, 0.12, pow(1.0 - progress, 1.6))
	if progress >= 1.0:
		_flash.hide()
		set_process(false)
