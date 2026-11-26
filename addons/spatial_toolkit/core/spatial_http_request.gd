@tool
extends Node

signal request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray)

const WORKER := "res://addons/spatial_toolkit/python/overpass_proxy.py"
const Settings := preload("res://addons/spatial_toolkit/core/spatial_project_settings.gd")
const MAX_REQUEST_BYTES := 256 * 1024
const MAX_RESPONSE_HEADER_BYTES := 128 * 1024
const DEFAULT_PROXY_BODY_LIMIT := 64 * 1024 * 1024
const DEFAULT_PROXY_TIMEOUT := 30.0
const PROXY_ERRORS := {
	"invalid": HTTPRequest.RESULT_REQUEST_FAILED,
	"timeout": HTTPRequest.RESULT_TIMEOUT,
	"tls": HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR,
	"too_large": HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED,
	"body_mismatch": HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH,
	"redirect_limit": HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED,
}

var timeout := 0.0
var body_size_limit := -1
var use_threads := false

var _direct: HTTPRequest
var _proxy_job: Dictionary = {}
var _proxy_thread: Thread
var _deadline := 0
var _proxy_body_limit := 0

func _ready() -> void:
	set_process(false)

func request(url: String, headers := PackedStringArray(), method := HTTPClient.METHOD_GET,
		body := "", proxy: Variant = null) -> Error:
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	if _direct != null or not _proxy_job.is_empty():
		return ERR_BUSY
	if method != HTTPClient.METHOD_GET and method != HTTPClient.METHOD_POST:
		return ERR_INVALID_PARAMETER
	if proxy == null:
		return _start_direct(url, headers, method, body)
	if not proxy is String:
		return ERR_INVALID_PARAMETER
	var address: String = proxy.strip_edges()
	if address.is_empty():
		return ERR_UNCONFIGURED
	return _start_proxy(url, headers, method, body, address)

func _start_direct(url: String, headers: PackedStringArray, method: HTTPClient.Method,
		body: String) -> Error:
	var http := HTTPRequest.new()
	http.timeout = timeout
	http.body_size_limit = body_size_limit
	http.use_threads = use_threads
	http.request_completed.connect(_direct_completed.bind(http))
	add_child(http)
	_direct = http
	var error := http.request(url, headers, method, body)
	if error != OK:
		cancel_request()
	return error

func _direct_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray,
		http: HTTPRequest) -> void:
	if http != _direct:
		return
	_direct = null
	http.queue_free()
	request_completed.emit(result, code, headers, body)

func _start_proxy(url: String, headers: PackedStringArray, method: HTTPClient.Method,
		body: String, proxy: String) -> Error:
	var effective_timeout := timeout if timeout > 0.0 and is_finite(timeout) else DEFAULT_PROXY_TIMEOUT
	_proxy_body_limit = body_size_limit if body_size_limit >= 0 else DEFAULT_PROXY_BODY_LIMIT
	var input := (JSON.stringify({
		"url": url,
		"headers": Array(headers),
		"method": "GET" if method == HTTPClient.METHOD_GET else "POST",
		"body": body,
		"proxy": proxy,
		"timeout": effective_timeout,
		"body_size_limit": _proxy_body_limit,
	}) + "\n").to_utf8_buffer()
	if input.size() > MAX_REQUEST_BYTES:
		return ERR_PARAMETER_RANGE_ERROR
	# Keep the proxy URL out of the process command line. The thread handles
	# pipe I/O so a request larger than the pipe buffer never blocks the editor.
	_proxy_job = OS.execute_with_pipe(Settings.python_executable(),
		PackedStringArray(["-I", "-B", ProjectSettings.globalize_path(WORKER)]), true)
	if _proxy_job.is_empty():
		return ERR_CANT_FORK
	_proxy_thread = Thread.new()
	var error := _proxy_thread.start(_exchange.bind(_proxy_job["stdio"], input,
		_proxy_body_limit + MAX_RESPONSE_HEADER_BYTES + 1))
	if error != OK:
		_close_proxy(true)
		return error
	_deadline = Time.get_ticks_msec() + ceili(effective_timeout * 1000.0)
	set_process(true)
	return OK

static func _exchange(pipe: FileAccess, input: PackedByteArray, limit: int) -> PackedByteArray:
	var output := PackedByteArray()
	if not pipe.store_buffer(input):
		return output
	while output.size() <= limit:
		var chunk := pipe.get_buffer(32768)
		if chunk.is_empty():
			break
		output.append_array(chunk)
	return output

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() >= _deadline:
		_close_proxy(true)
		request_completed.emit(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
		return
	if _proxy_thread.is_alive():
		return
	var output: PackedByteArray = _proxy_thread.wait_to_finish()
	_proxy_thread = null
	var oversized := output.size() > _proxy_body_limit + MAX_RESPONSE_HEADER_BYTES + 1
	_close_proxy(oversized)
	if oversized:
		request_completed.emit(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 0,
			PackedStringArray(), PackedByteArray())
	else:
		_proxy_completed(output)

func _proxy_completed(output: PackedByteArray) -> void:
	var line_end := output.find(10)
	var metadata: Variant
	if line_end >= 0 and line_end <= MAX_RESPONSE_HEADER_BYTES:
		metadata = JSON.parse_string(output.slice(0, line_end).get_string_from_utf8())
	if metadata is Dictionary:
		var status: Variant = metadata.get("status")
		var headers: Variant = metadata.get("headers", [])
		if (status is int or status is float) and headers is Array:
			var body := output.slice(line_end + 1)
			if body.size() > _proxy_body_limit:
				request_completed.emit(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 0,
					PackedStringArray(), PackedByteArray())
			else:
				request_completed.emit(HTTPRequest.RESULT_SUCCESS, int(status),
					PackedStringArray(headers), body)
			return
		if status is String:
			request_completed.emit(PROXY_ERRORS.get(status, HTTPRequest.RESULT_CANT_CONNECT), 0,
				PackedStringArray(), PackedByteArray())
			return
	request_completed.emit(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())

func cancel_request() -> void:
	if _direct != null:
		var http := _direct
		_direct = null
		http.cancel_request()
		http.queue_free()
	if not _proxy_job.is_empty():
		_close_proxy(true)

func _close_proxy(terminate: bool) -> void:
	set_process(false)
	var pid := int(_proxy_job["pid"])
	if OS.is_process_running(pid) and terminate:
		OS.kill(pid)
	if _proxy_thread != null and _proxy_thread.is_started():
		_proxy_thread.wait_to_finish()
	_proxy_thread = null
	for key in ["stdio", "stderr"]:
		var pipe: FileAccess = _proxy_job[key]
		pipe.close()
	_proxy_job.clear()

func _exit_tree() -> void:
	cancel_request()
