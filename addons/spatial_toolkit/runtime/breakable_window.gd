extends StaticBody3D
## A generated glass pane occupying an existing facade aperture.

func shatter() -> void:
	if not is_queued_for_deletion():
		hide()
		queue_free()
