@tool
extends Node

signal completed(result: int, code: int, body: PackedByteArray)

const WORKER := "res://addons/spatial_toolkit/python/overpass_proxy.py"
const OUTPUT_LIMIT := 16 * 1024 * 1024 + 128

var _job: Dictionary = {}
var _output := PackedByteArray()
var _deadline := 0

func _ready() -> void:
	set_process(false)

func start(proxy: String, endpoint: String, body: String, timeout: int) -> Error:
	var executable := "python" if OS.get_name() == "Windows" else "python3"
	if Engine.is_editor_hint():
		executable = str(EditorInterface.get_editor_settings().get_project_metadata(
			"spatial_toolkit", "python", executable)).strip_edges()
	_job = OS.execute_with_pipe(executable,
		PackedStringArray(["-I", "-B", ProjectSettings.globalize_path(WORKER)]), false)
	if _job.is_empty():
		return ERR_CANT_FORK
	var pipe: FileAccess = _job["stdio"]
	var input := JSON.stringify({"proxy": proxy, "endpoint": endpoint, "body": body}) + "\n"
	pipe.store_buffer(input.to_utf8_buffer())
	if pipe.get_error() != OK:
		cancel()
		return ERR_FILE_CANT_WRITE
	_output.clear()
	_deadline = Time.get_ticks_msec() + timeout * 1000
	set_process(true)
	return OK

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() >= _deadline:
		cancel()
		completed.emit(HTTPRequest.RESULT_TIMEOUT, 0, PackedByteArray())
		return
	var pipe: FileAccess = _job["stdio"]
	for _index in 16:
		var chunk := pipe.get_buffer(16384)
		if chunk.is_empty():
			if not OS.is_process_running(int(_job["pid"])):
				_finish()
			return
		_output.append_array(chunk)
		if _output.size() > OUTPUT_LIMIT:
			cancel()
			completed.emit(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 0, PackedByteArray())
			return

func _finish() -> void:
	var line_end := _output.find(10)
	var status := _output.slice(0, line_end).get_string_from_ascii() if line_end >= 0 else ""
	var body := _output.slice(line_end + 1) if status.is_valid_int() else PackedByteArray()
	cancel()
	match status:
		"timeout":
			completed.emit(HTTPRequest.RESULT_TIMEOUT, 0, body)
		"tls":
			completed.emit(HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR, 0, body)
		"too_large":
			completed.emit(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 0, body)
		"invalid":
			completed.emit(HTTPRequest.RESULT_REQUEST_FAILED, 0, body)
		_:
			var result := HTTPRequest.RESULT_SUCCESS if status.is_valid_int() else HTTPRequest.RESULT_CANT_CONNECT
			completed.emit(result, status.to_int(), body)

func cancel() -> void:
	set_process(false)
	if not _job.is_empty():
		var pid := int(_job["pid"])
		if OS.is_process_running(pid):
			OS.kill(pid)
		for key in ["stdio", "stderr"]:
			var pipe: FileAccess = _job[key]
			pipe.close()
		_job.clear()
	_output.clear()

func _exit_tree() -> void:
	cancel()
