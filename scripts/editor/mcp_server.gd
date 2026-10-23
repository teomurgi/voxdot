class_name MCPServer
extends Node

## MCP (Model Context Protocol) server embedded in the editor. Lets an agent
## drive every user-visible action over HTTP: tools, color, strokes, camera,
## file IO. Calls go through the same VoxelModelEditor paths as mouse/keyboard,
## so the window shows exactly what the agent is doing.
##
## Protocol: JSON-RPC 2.0 POSTed to http://127.0.0.1:<port>/ — methods
## "initialize", "notifications/initialized", "tools/list", "tools/call".
## Off unless enabled with --mcp or VOXDOT_MCP_PORT (default port 7850).

const PROTOCOL_VERSION: String = "2025-06-18"
const DEFAULT_PORT: int = 7850

var editor: VoxelModelEditor

var _server := TCPServer.new()
var _peers: Array[StreamPeerTCP] = []
var _bufs: Dictionary = {} # peer -> PackedByteArray (partial HTTP request)
var _tool_defs: Array[Dictionary] = []


func _ready() -> void:
	_tool_defs = _define_tools()


## True when the server should start: --mcp flag or VOXDOT_MCP_PORT set.
static func enabled_from_env() -> bool:
	if OS.has_environment("VOXDOT_MCP_PORT"):
		return true
	return OS.get_cmdline_user_args().has("--mcp") or OS.get_cmdline_args().has("--mcp")


static func port_from_env() -> int:
	var raw: String = OS.get_environment("VOXDOT_MCP_PORT")
	return int(raw) if raw != "" else DEFAULT_PORT


func start() -> void:
	var port: int = port_from_env()
	var err: Error = _server.listen(port, "127.0.0.1")
	if err != OK:
		push_warning("MCP: could not listen on 127.0.0.1:%d (%s)" % [port, error_string(err)])
		return
	editor._say("MCP server on 127.0.0.1:%d" % port)


func stop() -> void:
	for p: StreamPeerTCP in _peers:
		p.disconnect_from_host()
	_peers.clear()
	_bufs.clear()
	_server.stop()


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var p: StreamPeerTCP = _server.take_connection()
		_peers.append(p)
		_bufs[p] = PackedByteArray()
	for p: StreamPeerTCP in _peers.duplicate():
		p.poll()
		if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop(p)
			continue
		var n: int = p.get_available_bytes()
		if n > 0:
			var data: PackedByteArray = p.get_data(n)[1]
			var buf: PackedByteArray = _bufs[p]
			buf.append_array(data)
			_bufs[p] = buf
			_try_respond(p)


func _drop(p: StreamPeerTCP) -> void:
	_peers.erase(p)
	_bufs.erase(p)
	p.disconnect_from_host()


func _try_respond(p: StreamPeerTCP) -> void:
	var buf: PackedByteArray = _bufs[p]
	var head_end: int = _find_header_end(buf)
	if head_end < 0:
		return
	var head: String = buf.slice(0, head_end).get_string_from_utf8()
	var body_and_rest: PackedByteArray = buf.slice(head_end + 4)
	var length: int = 0
	for line in head.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			length = line.get_slice(":", 1).strip_edges().to_int()
	if body_and_rest.size() < length:
		return # wait for the rest of the body
	var request_text: String = body_and_rest.slice(0, length).get_string_from_utf8()
	_bufs[p] = body_and_rest.slice(length) # leftover bytes = start of a pipelined next request
	await _handle_http(p, head, request_text)


static func _find_header_end(buf: PackedByteArray) -> int:
	for i in range(buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


func _handle_http(p: StreamPeerTCP, head: String, body: String) -> void:
	var first_line: String = head.split("\r\n")[0]
	var method: String = first_line.get_slice(" ", 0)
	var path: String = first_line.get_slice(" ", 1)
	if method == "GET" and (path == "/health" or path == "/"):
		_send_json(p, {"ok": true, "app": "voxdot", "protocol": PROTOCOL_VERSION})
		return
	if method != "POST":
		_send_raw(p, 405, "text/plain", "POST JSON-RPC to /\n")
		return
	var parsed: Variant = JSON.parse_string(body)
	if typeof(parsed) != TYPE_DICTIONARY:
		_send_json(p, _rpc_error(null, -32700, "Parse error"))
		return
	# Batch requests are allowed by the spec; answer each entry.
	if parsed.has("method"):
		await _handle_rpc(p, parsed)
	else:
		_send_json(p, _rpc_error(null, -32600, "Invalid Request"))


func _handle_rpc(p: StreamPeerTCP, req: Dictionary) -> void:
	var id: Variant = req.get("id")
	var method: String = req.get("method", "")
	match method:
		"initialize":
			_send_json(p, _rpc_result(id, {
				"protocolVersion": PROTOCOL_VERSION,
				"capabilities": {"tools": {}},
				"serverInfo": {"name": "voxdot", "version": "1.0.0"},
			}))
		"notifications/initialized", "initialized":
			_send_raw(p, 202, "application/json", "")
		"ping":
			_send_json(p, _rpc_result(id, {}))
		"tools/list":
			_send_json(p, _rpc_result(id, {"tools": _tool_defs}))
		"tools/call":
			var params: Dictionary = req.get("params", {})
			_send_json(p, _rpc_result(id, await _call_tool(params.get("name", ""), params.get("arguments", {}))))
		_:
			_send_json(p, _rpc_error(id, -32601, "Method not found: " + method))


# --- JSON-RPC / HTTP plumbing ---

static func _rpc_result(id: Variant, result: Variant) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


static func _rpc_error(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}


func _send_json(p: StreamPeerTCP, payload: Dictionary) -> void:
	_send_raw(p, 200, "application/json", JSON.stringify(payload))


func _send_raw(p: StreamPeerTCP, status: int, content_type: String, text: String) -> void:
	var reason: String = {200: "OK", 202: "Accepted", 400: "Bad Request", 405: "Method Not Allowed"}.get(status, "OK")
	var body: PackedByteArray = text.to_utf8_buffer()
	var head: String = "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n" % [status, reason, content_type, body.size()]
	p.put_data(head.to_utf8_buffer())
	p.put_data(body)


# --- Tool dispatch ---

func _call_tool(tool_name: String, args: Dictionary) -> Dictionary:
	var fn := Callable(self, "_tool_" + tool_name)
	if not fn.is_valid() or not has_method("_tool_" + tool_name):
		return _tool_error("unknown tool: " + tool_name)
	var result: Variant = await fn.call(args)
	if typeof(result) == TYPE_DICTIONARY and (result as Dictionary).has("is_error"):
		return result
	return _tool_ok(result)


static func _tool_ok(payload: Variant) -> Dictionary:
	var text: String = JSON.stringify(payload) if typeof(payload) != TYPE_STRING else payload
	return {"content": [{"type": "text", "text": text}]}


static func _tool_error(message: String) -> Dictionary:
	return {"is_error": true, "content": [{"type": "text", "text": message}]}


static func _req(args: Dictionary, key: String) -> Variant:
	if not args.has(key):
		return null
	return args[key]


static func _arg_vec3i(args: Dictionary, key: String) -> Variant:
	var v: Variant = args.get(key)
	if typeof(v) != TYPE_ARRAY or (v as Array).size() != 3:
		return null
	return Vector3i(int(v[0]), int(v[1]), int(v[2]))


static func _arg_vec3(args: Dictionary, key: String) -> Variant:
	var v: Variant = args.get(key)
	if typeof(v) != TYPE_ARRAY or (v as Array).size() != 3:
		return null
	for n: Variant in v:
		if typeof(n) != TYPE_INT and typeof(n) != TYPE_FLOAT:
			return null
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


# --- Tool implementations (all mirror UI actions) ---

func _tool_list_tools(_args: Dictionary) -> Variant:
	return TOOL_NAMES_LIST


const TOOL_NAMES_LIST: Array[String] = ["place", "erase", "paint", "pick", "box", "box_erase", "fill", "light", "edit_light"]


func _tool_set_tool(args: Dictionary) -> Variant:
	var t: Variant = args.get("tool")
	var idx: int = TOOL_NAMES_LIST.find(str(t))
	if idx < 0:
		return _tool_error("tool must be one of " + str(TOOL_NAMES_LIST))
	editor._set_tool(idx as VoxelModelEditor.Tool)
	return {"tool": t}


func _tool_get_tool(_args: Dictionary) -> Variant:
	return {"tool": TOOL_NAMES_LIST[int(editor.current_tool)]}


func _tool_set_color(args: Dictionary) -> Variant:
	var c: Variant = _parse_color(args.get("color"))
	if c == null:
		return _tool_error("color must be \"rrggbb\" or [r, g, b] 0-1")
	editor._set_color(c)
	return {"color": "#" + (editor.color as Color).to_html(false)}


func _tool_get_color(_args: Dictionary) -> Variant:
	return {"color": "#" + editor.color.to_html(false)}


func _tool_place(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	if not editor.doc.in_bounds(cell):
		return _tool_error("cell out of bounds")
	editor.doc.place_cells([cell], editor.color)
	return {"placed": [cell.x, cell.y, cell.z], "count": editor.doc.voxel_count()}


func _tool_erase(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	editor.doc.erase_cells([cell])
	return {"count": editor.doc.voxel_count()}


func _tool_paint(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	var c: Variant = _parse_color(args.get("color"))
	if c != null:
		editor._set_color(c)
	editor.doc.paint_cells([cell], editor.color)
	return {"count": editor.doc.voxel_count()}


func _tool_fill(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	if not editor.doc.grid.has(cell):
		return _tool_error("no voxel at cell to fill from")
	var c: Variant = _parse_color(args.get("color"))
	if c != null:
		editor._set_color(c)
	var cells: Array[Vector3i] = editor.doc.flood_cells(cell)
	editor.doc.paint_cells(cells, editor.color)
	return {"filled": cells.size()}


func _tool_place_voxels(args: Dictionary) -> Variant:
	# Batch write. `data` is a list of "x,y,z;rrggbb" strings (one per voxel).
	# Mirror applies like place_cells. One call = one undo step + one rebuild.
	var data: Variant = args.get("data")
	if typeof(data) != TYPE_ARRAY:
		return _tool_error("data must be an array of \"x,y,z;rrggbb\" strings")
	var cells := {}
	for entry: String in data:
		var halves: PackedStringArray = entry.split(";")
		if halves.size() != 2:
			return _tool_error("bad entry (want x,y,z;rrggbb): " + entry)
		var xyz: PackedStringArray = halves[0].split(",")
		if xyz.size() != 3:
			return _tool_error("bad cell in entry: " + entry)
		var c: Variant = _parse_color(halves[1])
		if c == null:
			return _tool_error("bad color in entry: " + entry)
		cells[Vector3i(int(xyz[0]), int(xyz[1]), int(xyz[2]))] = c
	if cells.is_empty():
		return {"count": editor.doc.voxel_count()}
	editor.doc.write_cells(cells)
	return {"placed": cells.size(), "count": editor.doc.voxel_count()}


func _tool_place_box(args: Dictionary) -> Variant:
	var from: Variant = _arg_vec3i(args, "from")
	var to: Variant = _arg_vec3i(args, "to")
	if from == null or to == null:
		return _tool_error("from and to must be [x, y, z]")
	var erase: bool = bool(args.get("erase", false))
	var cells: Array[Vector3i] = VoxelDocument.box_cells(from, to)
	var c: Variant = _parse_color(args.get("color"))
	if erase:
		editor.doc.erase_cells(cells)
	else:
		if c != null:
			editor._set_color(c)
		editor.doc.place_cells(cells, editor.color)
	return {"box_cells": cells.size(), "count": editor.doc.voxel_count()}


## Stroke trio: mirrors an LMB drag. begin locks the drag plane from the
## first cell's face, updates move along it, end commits one undo step.
func _tool_begin_stroke(args: Dictionary) -> Variant:
	if editor._stroking:
		return _tool_error("a stroke is already active")
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	var normal := Vector3i.UP
	var n: Variant = args.get("normal")
	if n != null:
		var nv: Variant = _arg_vec3i(args, "normal")
		if nv == null:
			return _tool_error("normal must be [x, y, z]")
		normal = nv
	if not editor.doc.in_bounds(cell):
		return _tool_error("cell out of bounds")
	var axis: int = VoxelModelEditor._axis_of(normal)
	var h := {
		"valid": true,
		"cell": cell,
		"normal": normal,
		"face_coord": float(cell[axis] + (1 if normal[axis] > 0 else 0)),
	}
	editor._begin_stroke(h)
	return {"stroking": editor._stroking}


func _tool_update_stroke(args: Dictionary) -> Variant:
	if not editor._stroking:
		return _tool_error("no active stroke")
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	cell = (cell as Vector3i).clamp(Vector3i.ZERO, editor.doc.bounds - Vector3i.ONE)
	if editor._is_box_tool(editor._stroke_tool):
		editor._box_end = cell
	elif cell != editor._last_cell:
		editor._last_cell = cell
		editor._apply_cell(cell)
	editor._update_ghost()
	return {"last": [editor._last_cell.x, editor._last_cell.y, editor._last_cell.z], "count": editor.doc.voxel_count()}


func _tool_end_stroke(_args: Dictionary) -> Variant:
	if not editor._stroking:
		return _tool_error("no active stroke")
	editor._finish_stroke()
	return {"count": editor.doc.voxel_count(), "can_undo": editor.doc.can_undo()}


func _tool_pick(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	if not editor.doc.grid.has(cell):
		return _tool_error("no voxel at cell")
	editor._set_color(editor.doc.grid[cell])
	return {"color": "#" + editor.color.to_html(false)}


func _tool_undo(_args: Dictionary) -> Variant:
	return {"undone": editor.doc.undo(), "count": editor.doc.voxel_count()}


func _tool_redo(_args: Dictionary) -> Variant:
	return {"redone": editor.doc.redo(), "count": editor.doc.voxel_count()}


func _tool_new_model(_args: Dictionary) -> Variant:
	editor._doc_replaced = true
	editor.doc.reset()
	editor.frame_model()
	return {"bounds": [editor.doc.bounds.x, editor.doc.bounds.y, editor.doc.bounds.z]}


func _tool_open(args: Dictionary) -> Variant:
	var p: String = str(_req(args, "path"))
	if p == "":
		return _tool_error("path is required")
	# Set before load_file so the changed signal routes to _on_doc_reset() and
	# rebuilds chunk records for the loaded grid.
	editor._doc_replaced = true
	var err: Error = editor.doc.load_file(p)
	if err != OK:
		editor._doc_replaced = false
		return _tool_error("open failed: " + error_string(err))
	editor.frame_model()
	return {"path": editor.doc.path, "count": editor.doc.voxel_count()}


func _tool_save(args: Dictionary) -> Variant:
	var p: String = str(args.get("path", ""))
	if p == "":
		p = editor.doc.path
	if p == "":
		return _tool_error("no path given and model has no path; pass path")
	var err: Error = editor.doc.save_file(p)
	if err != OK:
		return _tool_error("save failed: " + error_string(err))
	return {"path": editor.doc.path}


func _tool_set_bounds(args: Dictionary) -> Variant:
	var b: Variant = _arg_vec3i(args, "bounds")
	if b == null:
		return _tool_error("bounds must be [x, y, z]")
	if not editor.doc.resize_bounds(b):
		return _tool_error("refused: voxels exist outside the new size")
	return {"bounds": [editor.doc.bounds.x, editor.doc.bounds.y, editor.doc.bounds.z]}


func _tool_set_voxel_size(args: Dictionary) -> Variant:
	editor.doc.set_voxel_size(float(args.get("size", 0.0625)))
	return {"voxel_size": editor.doc.voxel_size}


func _tool_set_mirror(args: Dictionary) -> Variant:
	editor._set_mirror(bool(args.get("x", editor.doc.mirror_x)), bool(args.get("z", editor.doc.mirror_z)))
	return {"mirror_x": editor.doc.mirror_x, "mirror_z": editor.doc.mirror_z}


func _tool_set_height_lock(args: Dictionary) -> Variant:
	if args.has("layer"):
		editor._set_layer(int(args["layer"]))
	editor._set_height_lock(bool(args.get("on", true)))
	return {"height_lock": editor.height_lock, "layer": editor.work_layer}


func _tool_set_layer(args: Dictionary) -> Variant:
	editor._set_layer(int(args.get("layer", 0)))
	return {"layer": editor.work_layer, "height_lock": editor.height_lock}


func _tool_set_box_depth(args: Dictionary) -> Variant:
	editor.box_depth = clampi(int(args.get("depth", 1)), 1, 64)
	editor._depth_spin.value = editor.box_depth
	return {"box_depth": editor.box_depth}


func _tool_set_grid_visible(args: Dictionary) -> Variant:
	editor.grid_visible = bool(args.get("visible", true))
	editor._grid_mi.visible = editor.grid_visible
	return {"grid_visible": editor.grid_visible}


func _tool_set_orthographic(args: Dictionary) -> Variant:
	editor._set_orthographic(bool(args.get("on", true)))
	return {"orthographic": editor.camera.projection == Camera3D.PROJECTION_ORTHOGONAL}


func _tool_set_camera(args: Dictionary) -> Variant:
	if args.has("yaw"):
		editor._yaw = deg_to_rad(float(args["yaw"]))
	if args.has("pitch"):
		editor._pitch = clampf(deg_to_rad(float(args["pitch"])), deg_to_rad(-89.0), deg_to_rad(20.0))
	if args.has("distance"):
		editor._distance = clampf(float(args["distance"]), 3.0, 400.0)
	editor._update_camera()
	return _camera_state()


func _tool_orbit(args: Dictionary) -> Variant:
	editor._orbit(Vector2(float(args.get("dx", 0.0)), float(args.get("dy", 0.0))))
	editor._update_camera()
	return _camera_state()


func _tool_pan(args: Dictionary) -> Variant:
	editor._pan(Vector2(float(args.get("dx", 0.0)), float(args.get("dy", 0.0))))
	editor._update_camera()
	return _camera_state()


func _tool_zoom(args: Dictionary) -> Variant:
	var steps: int = int(args.get("steps", 0))
	for i in absi(steps):
		if steps > 0:
			editor._distance = clampf(editor._distance * 0.9, 3.0, 400.0)
		else:
			editor._distance = clampf(editor._distance / 0.9, 3.0, 400.0)
	editor._update_camera()
	return _camera_state()


func _tool_frame(_args: Dictionary) -> Variant:
	editor.frame_model()
	editor._update_camera()
	return _camera_state()


func _camera_state() -> Dictionary:
	return {
		"yaw": rad_to_deg(editor._yaw),
		"pitch": rad_to_deg(editor._pitch),
		"distance": editor._distance,
		"focus": [editor._focus.x, editor._focus.y, editor._focus.z],
	}


func _tool_hover(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	var world := Vector3(cell) + Vector3.ONE * 0.5
	var screen: Vector2 = editor.camera.unproject_position(world)
	var o: Vector3 = editor.camera.project_ray_origin(screen)
	var d: Vector3 = editor.camera.project_ray_normal(screen)
	return editor._compute_hover(o, d)


func _tool_set_render_horizon(args: Dictionary) -> Variant:
	editor.set_render_horizon(int(args.get("horizon", 0)))
	return {"render_horizon": 0 if editor.render_horizon >= editor.UNLIMITED_HORIZON else editor.render_horizon,
		"rendered_chunks": editor._chunks.size(),
		"total_voxels": editor.doc.voxel_count()}


func _tool_get_state(_args: Dictionary) -> Variant:
	return _full_state()


func _tool_get_voxels(_args: Dictionary) -> Variant:
	var out: Array = []
	for p: Vector3i in editor.doc.grid:
		out.append({"cell": [p.x, p.y, p.z], "color": "#" + (editor.doc.grid[p] as Color).to_html(false)})
	return {"voxels": out, "count": out.size()}


# --- Point lights ---

func _tool_add_light(args: Dictionary) -> Variant:
	var position: Variant = _arg_vec3(args, "position")
	if position == null:
		return _tool_error("position must be [x, y, z]")
	var c: Variant = _parse_color(args.get("color", "ffd9a0"))
	if c == null:
		return _tool_error("color must be \"rrggbb\" or [r, g, b] 0-1")
	var id: int = editor.add_point_light(position, c, float(args.get("energy", VoxelDocument.LIGHT_DEFAULT_ENERGY)),
		float(args.get("range", VoxelDocument.LIGHT_DEFAULT_RANGE)), bool(args.get("shadows", true)))
	if id < 0:
		return _tool_error("could not add light: outside bounds or %d-light limit reached" % VoxelDocument.MAX_LIGHTS)
	return {"id": id, "light": _light_payload(id), "count": editor.doc.lights.size()}


func _tool_update_light(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", editor.selected_light_id))
	if not editor.doc.lights.has(id):
		return _tool_error("unknown light id")
	var properties: Dictionary = {}
	if args.has("position"):
		var p: Variant = _arg_vec3(args, "position")
		if p == null:
			return _tool_error("position must be [x, y, z]")
		properties["position"] = p
	if args.has("color"):
		var c: Variant = _parse_color(args["color"])
		if c == null:
			return _tool_error("color must be \"rrggbb\" or [r, g, b] 0-1")
		properties["color"] = c
	for key: String in ["energy", "range", "shadows"]:
		if args.has(key):
			properties[key] = args[key]
	if not editor.update_point_light(id, properties):
		return _tool_error("no change or position outside model bounds")
	return {"id": id, "light": _light_payload(id)}


func _tool_remove_light(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", editor.selected_light_id))
	if not editor.remove_point_light(id):
		return _tool_error("unknown light id")
	return {"removed": id, "count": editor.doc.lights.size()}


func _tool_get_lights(_args: Dictionary) -> Variant:
	var out: Array = []
	var ids: Array = editor.doc.lights.keys()
	ids.sort()
	for id: int in ids:
		out.append(_light_payload(id))
	return {"lights": out, "count": out.size(), "selected": editor.selected_light_id}


func _tool_select_light(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	if not editor._select_light(id):
		return _tool_error("unknown light id")
	return {"selected": id}


func _tool_set_light_handles(args: Dictionary) -> Variant:
	editor.light_rig.handles_visible = bool(args.get("visible", true))
	editor._light_handles_check.set_pressed_no_signal(editor.light_rig.handles_visible)
	return {"visible": editor.light_rig.handles_visible}


func _tool_set_sun(args: Dictionary) -> Variant:
	var properties: Dictionary = {}
	if args.has("energy"):
		properties["energy"] = clampf(float(args["energy"]), 0.0, VoxelDocument.MAX_SUN_ENERGY)
	if args.has("yaw"):
		properties["yaw"] = float(args["yaw"])
	if args.has("pitch"):
		properties["pitch"] = float(args["pitch"])
	if args.has("color"):
		var c: Variant = _parse_color(args["color"])
		if typeof(c) != TYPE_COLOR:
			return _tool_error("color must be a hex string like \"ffcc88\"")
		properties["color"] = c
	if args.has("shadows"):
		properties["shadows"] = bool(args["shadows"])
	if properties.is_empty():
		return _tool_error("give at least one of energy, yaw, pitch, color, shadows")
	editor.set_sun_properties(properties)
	return _sun_payload()


func _sun_payload() -> Dictionary:
	return {"energy": editor.doc.sun_energy, "yaw": editor.doc.sun_yaw,
		"pitch": editor.doc.sun_pitch, "color": "#" + editor.doc.sun_color.to_html(false),
		"shadows": editor.doc.sun_shadows}


func _light_payload(id: int) -> Dictionary:
	var l: Dictionary = editor.doc.lights[id]
	var p: Vector3 = l["position"]
	return {"id": id, "position": [p.x, p.y, p.z], "color": "#" + (l["color"] as Color).to_html(false),
		"energy": l["energy"], "range": l["range"], "shadows": l["shadows"]}


func _tool_add_swatch(args: Dictionary) -> Variant:
	var c: Variant = _parse_color(args.get("color"))
	if c == null:
		return _tool_error("color must be \"rrggbb\" or [r, g, b] 0-1")
	editor.doc.add_swatch(c)
	return {"swatches": editor.doc.swatches.size()}


func _tool_screenshot(_args: Dictionary) -> Variant:
	var path: String = await editor.save_screenshot(OS.get_user_data_dir().path_join("mcp_screenshot.png"))
	if path == "":
		return _tool_error("no viewport image (headless?)")
	var tex: ViewportTexture = editor.get_viewport().get_texture()
	var size: Vector2i = tex.get_size()
	return {"path": path, "width": size.x, "height": size.y}


# --- State snapshot ---

func _full_state() -> Dictionary:
	return {
		"tool": TOOL_NAMES_LIST[int(editor.current_tool)],
		"color": "#" + editor.color.to_html(false),
		"bounds": [editor.doc.bounds.x, editor.doc.bounds.y, editor.doc.bounds.z],
		"voxel_size": editor.doc.voxel_size,
		"voxel_count": editor.doc.voxel_count(),
		"mirror_x": editor.doc.mirror_x,
		"mirror_z": editor.doc.mirror_z,
		"height_lock": editor.height_lock,
		"work_layer": editor.work_layer,
		"box_depth": editor.box_depth,
		"grid_visible": editor.grid_visible,
		"orthographic": editor.camera.projection == Camera3D.PROJECTION_ORTHOGONAL,
		"camera": _camera_state(),
		"path": editor.doc.path,
		"dirty": editor.doc.dirty,
		"lights": editor.doc.lights.size(),
		"can_undo": editor.doc.can_undo(),
		"can_redo": editor.doc.can_redo(),
		"stroking": editor._stroking,
		"swatches": editor.doc.swatches.size(),
		# 0 means unlimited (all chunks meshed), matching set_render_horizon.
		"render_horizon": 0 if editor.render_horizon >= editor.UNLIMITED_HORIZON else editor.render_horizon,
	}


static func _parse_color(v: Variant) -> Variant:
	if typeof(v) == TYPE_STRING:
		return Color(v)
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return null


# --- Tool schema (tools/list) ---

func _define_tools() -> Array[Dictionary]:
	var cell := {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3}
	var color := {"description": "\"rrggbb\" hex string or [r,g,b] floats 0-1"}
	return [
		{"name": "get_state", "description": "Full editor snapshot: tool, color, bounds, counts, camera, file, undo state.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "get_voxels", "description": "Every voxel: cell [x,y,z] and hex color.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "screenshot", "description": "Save the current window to a PNG; returns its path. Use to see what the user sees.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "list_tools", "description": "Names of the editing tools.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "set_tool", "description": "Select a tool: place, erase, paint, pick, box, box_erase, fill.", "inputSchema": {"type": "object", "properties": {"tool": {"type": "string", "enum": ["place", "erase", "paint", "pick", "box", "box_erase", "fill"]}}, "required": ["tool"]}},
		{"name": "get_tool", "description": "Currently selected tool.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "set_color", "description": "Set the active color.", "inputSchema": {"type": "object", "properties": {"color": color}, "required": ["color"]}},
		{"name": "get_color", "description": "Active color as hex.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "place", "description": "Place one voxel at cell with the active color (mirror applies).", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
		{"name": "erase", "description": "Erase the voxel at cell (mirror applies).", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
		{"name": "paint", "description": "Recolor the existing voxel at cell.", "inputSchema": {"type": "object", "properties": {"cell": cell, "color": color}, "required": ["cell"]}},
		{"name": "fill", "description": "Flood-recolor all connected voxels sharing the color at cell.", "inputSchema": {"type": "object", "properties": {"cell": cell, "color": color}, "required": ["cell"]}},
		{"name": "place_box", "description": "Fill (or erase with erase=true) the box between cells from and to.", "inputSchema": {"type": "object", "properties": {"from": cell, "to": cell, "color": color, "erase": {"type": "boolean"}}, "required": ["from", "to"]}},
		{"name": "place_voxels", "description": "Batch-write many voxels of different colors in one call (one undo step, one mesh rebuild). data = array of \"x,y,z;rrggbb\" strings. Much faster than many place calls for large builds.", "inputSchema": {"type": "object", "properties": {"data": {"type": "array", "items": {"type": "string"}}}, "required": ["data"]}},
		{"name": "pick", "description": "Set the active color from the voxel at cell.", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
		{"name": "begin_stroke", "description": "Start an LMB-style drag at cell (normal = face normal, default up). Locks the drag plane like a mouse press.", "inputSchema": {"type": "object", "properties": {"cell": cell, "normal": cell}, "required": ["cell"]}},
		{"name": "update_stroke", "description": "Move an active stroke to cell; paints/erases along the way, or drags a box tool's far corner.", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
		{"name": "end_stroke", "description": "Commit the active stroke as one undo step (like releasing LMB).", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "undo", "description": "Undo one stroke.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "redo", "description": "Redo one stroke.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "new_model", "description": "Reset to an empty 32x32x32 model.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "open", "description": "Open a .tres/.res voxel model from an absolute path.", "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}},
		{"name": "save", "description": "Save to path, or to the model's current path if omitted.", "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
		{"name": "set_bounds", "description": "Resize the editable volume; refused if voxels would fall outside.", "inputSchema": {"type": "object", "properties": {"bounds": cell}, "required": ["bounds"]}},
		{"name": "set_voxel_size", "description": "Real-world voxel size in meters.", "inputSchema": {"type": "object", "properties": {"size": {"type": "number"}}, "required": ["size"]}},
		{"name": "set_mirror", "description": "Toggle mirror symmetry across X and/or Z.", "inputSchema": {"type": "object", "properties": {"x": {"type": "boolean"}, "z": {"type": "boolean"}}}},
		{"name": "set_height_lock", "description": "Toggle height lock (Place/Box target the work layer plane); optionally set layer.", "inputSchema": {"type": "object", "properties": {"on": {"type": "boolean"}, "layer": {"type": "integer"}}}},
		{"name": "set_layer", "description": "Move the work layer (enables height lock).", "inputSchema": {"type": "object", "properties": {"layer": {"type": "integer"}}, "required": ["layer"]}},
		{"name": "set_box_depth", "description": "Extrusion depth for box / box erase.", "inputSchema": {"type": "object", "properties": {"depth": {"type": "integer"}}, "required": ["depth"]}},
		{"name": "set_grid_visible", "description": "Show or hide the ground grid.", "inputSchema": {"type": "object", "properties": {"visible": {"type": "boolean"}}, "required": ["visible"]}},
		{"name": "set_orthographic", "description": "Toggle orthographic camera.", "inputSchema": {"type": "object", "properties": {"on": {"type": "boolean"}}, "required": ["on"]}},
		{"name": "set_camera", "description": "Set camera yaw/pitch (degrees) and/or distance.", "inputSchema": {"type": "object", "properties": {"yaw": {"type": "number"}, "pitch": {"type": "number"}, "distance": {"type": "number"}}}},
		{"name": "orbit", "description": "Orbit the camera by pixel deltas, like MMB drag.", "inputSchema": {"type": "object", "properties": {"dx": {"type": "number"}, "dy": {"type": "number"}}}},
		{"name": "pan", "description": "Pan the camera by pixel deltas, like Shift+MMB drag.", "inputSchema": {"type": "object", "properties": {"dx": {"type": "number"}, "dy": {"type": "number"}}}},
		{"name": "zoom", "description": "Zoom in (positive steps) or out (negative), like the mouse wheel.", "inputSchema": {"type": "object", "properties": {"steps": {"type": "integer"}}, "required": ["steps"]}},
		{"name": "frame", "description": "Fit the camera to the model (F key).", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "set_render_horizon", "description": "Cap what gets meshed: only chunks within this horizontal distance of the camera are rendered (the full grid is still kept and saved), so raising it reveals farther parts. Omit or pass 0 to render everything.", "inputSchema": {"type": "object", "properties": {"horizon": {"type": "integer"}}}},
		{"name": "hover", "description": "Raycast through the given cell's screen position; reports the cell a mouse would hit.", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
		{"name": "add_light", "description": "Add a point light. Position and range use voxel units; color hex, energy 0-16, range 0.25-512, optional shadows. Max 32.", "inputSchema": {"type": "object", "properties": {"position": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, "color": color, "energy": {"type": "number"}, "range": {"type": "number"}, "shadows": {"type": "boolean"}}, "required": ["position"]}},
		{"name": "update_light", "description": "Edit a point light by id (or selected id): position, color, energy, range, shadows.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "position": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, "color": color, "energy": {"type": "number"}, "range": {"type": "number"}, "shadows": {"type": "boolean"}}}},
		{"name": "remove_light", "description": "Remove a point light by id (or selected id).", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}}},
		{"name": "get_lights", "description": "List stored point lights with ids, positions, colors, energy, ranges, and shadows.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "select_light", "description": "Select a light for the inspector and update/remove commands.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
		{"name": "set_light_handles", "description": "Show or hide light editing handles without changing illumination.", "inputSchema": {"type": "object", "properties": {"visible": {"type": "boolean"}}}},
		{"name": "set_sun", "description": "Configure the scene's directional sun (saved with the model): energy (0..16, 0 = off), yaw/pitch in degrees, hex color, shadows. Give any subset.", "inputSchema": {"type": "object", "properties": {"energy": {"type": "number"}, "yaw": {"type": "number"}, "pitch": {"type": "number"}, "color": {"type": "string"}, "shadows": {"type": "boolean"}}}},
		{"name": "add_swatch", "description": "Add a color to the palette.", "inputSchema": {"type": "object", "properties": {"color": color}, "required": ["color"]}},
	]
