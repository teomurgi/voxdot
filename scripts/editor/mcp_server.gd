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


const TOOL_NAMES_LIST: Array[String] = ["place", "erase", "paint", "pick", "box", "box_erase", "fill", "light", "edit_light", "prefab", "material"]


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


func _material_id(value: Variant, fallback: int) -> Variant:
	if value == null or str(value) == "":
		return fallback
	var found: int = VoxelMaterial.try_kind_from_id(str(value))
	if found < 0:
		return null
	return found


func _override_value(value: Variant) -> Variant:
	if value == null:
		return null
	return VoxelMaterial.Override.ON if bool(value) else VoxelMaterial.Override.OFF


func _material_bits(args: Dictionary, fallback: int = 0) -> int:
	var solid: Variant = _override_value(args.get("solid"))
	var walkable: Variant = _override_value(args.get("walkable"))
	if solid == null and walkable == null:
		return fallback
	return VoxelMaterial.make_overrides(
		int(solid) if solid != null else VoxelMaterial.solid_override(fallback),
		int(walkable) if walkable != null else VoxelMaterial.walkable_override(fallback))


func _material_payload(kind: int, bits: int) -> Dictionary:
	var tag_list: Array = []
	for t: String in VoxelMaterial.tags(kind):
		tag_list.append(t)
	return {
		"id": VoxelMaterial.id(kind),
		"name": VoxelMaterial.display_name(kind),
		"color": "#" + VoxelMaterial.color(kind).to_html(false),
		"solid": VoxelMaterial.is_solid(kind, bits),
		"walkable": VoxelMaterial.is_walkable(kind, bits),
		"solid_override": VoxelMaterial.solid_override(bits),
		"walkable_override": VoxelMaterial.walkable_override(bits),
		"tags": tag_list,
	}


func _tool_list_materials(_args: Dictionary) -> Variant:
	var out: Array = []
	for i in VoxelMaterial.count():
		out.append(_material_payload(i, 0))
	return {"materials": out}


func _tool_set_material(args: Dictionary) -> Variant:
	if not args.has("material"):
		return _tool_error("material is required")
	if not VoxelMaterial.is_known_id(str(args.get("material"))):
		return _tool_error("unknown material: " + str(args.get("material")))
	var kind: int = VoxelMaterial.kind_from_id(str(args.get("material")))
	var bits: int = _material_bits(args, 0)
	editor._set_material(kind)
	editor._set_material_overrides(VoxelMaterial.solid_override(bits),
		VoxelMaterial.walkable_override(bits))
	return _material_payload(editor.current_material, editor.current_material_overrides)


func _tool_get_material(_args: Dictionary) -> Variant:
	return _material_payload(editor.current_material, editor.current_material_overrides)


func _tool_get_voxel(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	var kind: int = VoxelMaterial.Kind.DEFAULT
	var bits: int = 0
	var col: Variant = null
	if editor.doc.grid.has(cell):
		kind = editor.doc.material_at(cell)
		bits = editor.doc.material_override_at(cell)
		col = editor.doc.grid[cell]
	elif editor.doc.prefab_composition.has_cell(cell):
		kind = editor.doc.prefab_composition.material_at(cell)
		bits = editor.doc.prefab_composition.override_at(cell)
		col = editor.doc.prefab_composition.color_at(cell)
	else:
		return _tool_error("no voxel at cell")
	# Composed truth either way: covering linked or local cells and non-solid
	# cells above all change the walkable-surface answer.
	var composed: Dictionary = editor.doc.to_model().build_composed_data()
	var walkable: bool = VoxelModel.new().is_walkable_cell(cell, composed)
	var payload: Dictionary = _material_payload(kind, bits)
	payload["cell"] = [cell.x, cell.y, cell.z]
	payload["color"] = "#" + (col as Color).to_html(false)
	payload["walkable_surface"] = walkable
	return payload


func _tool_paint_material(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	if not editor.doc.grid.has(cell):
		return _tool_error("no voxel at cell")
	if not args.has("material"):
		return _tool_error("material is required")
	if not VoxelMaterial.is_known_id(str(args.get("material"))):
		return _tool_error("unknown material: " + str(args.get("material")))
	var kind: int = VoxelMaterial.kind_from_id(str(args.get("material")))
	var bits: int = _material_bits(args, 0)
	editor._set_material(kind)
	editor._set_material_overrides(VoxelMaterial.solid_override(bits),
		VoxelMaterial.walkable_override(bits))
	editor.doc.paint_material([cell], kind, bits)
	return _material_payload(kind, bits)


func _tool_place(args: Dictionary) -> Variant:
	var cell: Variant = _arg_vec3i(args, "cell")
	if cell == null:
		return _tool_error("cell must be [x, y, z]")
	if not editor.doc.in_bounds(cell):
		return _tool_error("cell out of bounds")
	var kind: int = editor.current_material
	var bits: int = editor.current_material_overrides
	if args.has("material") or args.has("solid") or args.has("walkable"):
		if args.has("material") and not VoxelMaterial.is_known_id(str(args.get("material"))):
			return _tool_error("unknown material: " + str(args.get("material")))
		kind = _material_id(args.get("material"), kind)
		bits = _material_bits(args, 0)
	editor.doc.place_cells([cell], editor.color, kind, bits)
	return {"placed": [cell.x, cell.y, cell.z], "count": editor.doc.voxel_count(),
		"material": VoxelMaterial.id(kind)}


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
	var kind: Variant = null
	var bits: Variant = null
	if args.has("material") or args.has("solid") or args.has("walkable"):
		if args.has("material") and not VoxelMaterial.is_known_id(str(args.get("material"))):
			return _tool_error("unknown material: " + str(args.get("material")))
		kind = _material_id(args.get("material"), editor.current_material)
		bits = _material_bits(args, 0)
	var written: int = editor.doc.write_cells(cells, kind, bits)
	return {"placed": written, "count": editor.doc.voxel_count()}


func _tool_place_box(args: Dictionary) -> Variant:
	var from: Variant = _arg_vec3i(args, "from")
	var to: Variant = _arg_vec3i(args, "to")
	if from == null or to == null:
		return _tool_error("from and to must be [x, y, z]")
	var erase: bool = bool(args.get("erase", false))
	var cells: Array[Vector3i] = VoxelDocument.box_cells(from, to)
	if not erase and args.has("material") and not VoxelMaterial.is_known_id(str(args.get("material"))):
		return _tool_error("unknown material: " + str(args.get("material")))
	var c: Variant = _parse_color(args.get("color"))
	if erase:
		editor.doc.erase_cells(cells)
	else:
		if c != null:
			editor._set_color(c)
		var kind: int = editor.current_material
		var bits: int = editor.current_material_overrides
		if args.has("material") or args.has("solid") or args.has("walkable"):
			kind = _material_id(args.get("material"), kind)
			bits = _material_bits(args, 0)
		editor.doc.place_cells(cells, editor.color, kind, bits)
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
	if editor.doc.grid.has(cell):
		editor._set_material(editor.doc.material_at(cell))
		var local_bits: int = editor.doc.material_override_at(cell)
		editor._set_material_overrides(VoxelMaterial.solid_override(local_bits),
			VoxelMaterial.walkable_override(local_bits))
		editor._set_color(editor.doc.grid[cell])
	elif editor.doc.prefab_composition.has_cell(cell):
		editor._set_material(editor.doc.prefab_composition.material_at(cell))
		var linked_bits: int = editor.doc.prefab_composition.override_at(cell)
		editor._set_material_overrides(VoxelMaterial.solid_override(linked_bits),
			VoxelMaterial.walkable_override(linked_bits))
		editor._set_color(editor.doc.prefab_composition.color_at(cell))
	else:
		return _tool_error("no voxel at cell")
	var payload: Dictionary = _material_payload(editor.current_material, editor.current_material_overrides)
	payload["color"] = "#" + editor.color.to_html(false)
	return payload


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


# --- Prefabs ---
#
# Every call goes through the same VoxelDocument methods as the UI, so undo,
# dirty state and validation are identical. Catalogue scans are lazy: the
# first query scans when nothing is cached; prefab_refresh_assets is explicit.

func _ensure_catalog() -> void:
	var dir: String = editor.doc.path.get_base_dir()
	# Rescan when nothing is cached or the open model moved to another folder:
	# the project library is derived from the model's directory, so a stale
	# scan would hide assets from the newly opened project.
	if editor.catalog.asset_count() == 0 or editor.catalog.project_dir != dir:
		editor.catalog.scan(dir)


func _tool_prefab_list_assets(args: Dictionary) -> Variant:
	_ensure_catalog()
	var library: String = str(args.get("library", "all"))
	if library not in ["all", "user", "project"]:
		return _tool_error("library must be all, user or project")
	var search: String = str(args.get("search", "")).to_lower()
	var include_invalid: bool = bool(args.get("include_invalid", false))
	var out: Array = []
	for a: Dictionary in editor.catalog.assets():
		if library != "all" and str(a.get("library", "")) != library:
			continue
		if not include_invalid and not bool(a.get("valid", false)):
			continue
		if search != "" and not (str(a.get("name", "")).to_lower().contains(search)
				or str(a.get("path", "")).to_lower().contains(search)):
			continue
		out.append(_asset_payload(a))
	return {"assets": out, "count": out.size(), "libraries": editor.catalog.libraries(editor.doc.path.get_base_dir())}


func _tool_prefab_refresh_assets(_args: Dictionary) -> Variant:
	var summary: Dictionary = editor.catalog.scan(editor.doc.path.get_base_dir())
	return summary


func _tool_prefab_get_asset(args: Dictionary) -> Variant:
	_ensure_catalog()
	var a: Dictionary = _find_asset(args)
	if a.is_empty():
		return _tool_error("unknown asset: give asset_id or path")
	var payload: Dictionary = _asset_payload(a)
	payload["thumbnail"] = _cached_thumbnail(a)
	payload["pivot_error"] = str(a.get("pivot_error", ""))
	return payload


func _tool_prefab_set_pivot(args: Dictionary) -> Variant:
	_ensure_catalog()
	var a: Dictionary = _find_asset(args)
	if a.is_empty():
		return _tool_error("unknown asset: give asset_id or path")
	var pivot: Variant = _arg_vec3(args, "pivot")
	if pivot == null:
		return _tool_error("pivot must be [x, y, z]")
	var updated: Dictionary = editor.catalog.set_pivot(str(a["asset_id"]), pivot)
	if updated.is_empty():
		return _tool_error("unknown asset")
	if updated.has("pivot_error"):
		return _tool_error(str(updated["pivot_error"]))
	return _asset_payload(updated)


func _tool_prefab_reset_pivot(args: Dictionary) -> Variant:
	_ensure_catalog()
	var a: Dictionary = _find_asset(args)
	if a.is_empty():
		return _tool_error("unknown asset: give asset_id or path")
	var updated: Dictionary = editor.catalog.reset_pivot(str(a["asset_id"]))
	if updated.is_empty():
		return _tool_error("asset source is missing")
	return _asset_payload(updated)


## Resolves an asset by `asset_id`, then by `path`. Returns {} when neither
## matches. Assets from the catalogue carry their pivot and stable ID.
func _find_asset(args: Dictionary) -> Dictionary:
	var asset_id: String = str(args.get("asset_id", ""))
	if asset_id != "":
		return editor.catalog.asset(asset_id)
	var p: String = str(args.get("path", ""))
	if p != "":
		return editor.catalog.asset_at(p)
	return {}


func _asset_payload(a: Dictionary) -> Dictionary:
	var b: Vector3i = a.get("bounds", Vector3i.ZERO)
	var pivot: Vector3 = a.get("pivot", Vector3.ZERO)
	return {
		"asset_id": str(a.get("asset_id", "")),
		"name": str(a.get("name", "")),
		"path": str(a.get("path", "")),
		"relative_path": str(a.get("relative_path", "")),
		"folder": str(a.get("folder", "")),
		"library": str(a.get("library", "")),
		"bounds": [b.x, b.y, b.z],
		"cells": int(a.get("cells", 0)),
		"lights": int(a.get("lights", 0)),
		"pivot": [pivot.x, pivot.y, pivot.z],
		"valid": bool(a.get("valid", false)),
		"reason": str(a.get("reason", "")),
		"has_prefabs": bool(a.get("has_prefabs", false)),
	}


func _cached_thumbnail(a: Dictionary) -> String:
	var p: String = editor.catalog.thumbnail_path(a)
	return p if p != "" and FileAccess.file_exists(p) else ""


func _tool_prefab_place(args: Dictionary) -> Variant:
	_ensure_catalog()
	var anchor: Variant = _arg_vec3i(args, "anchor")
	if anchor == null:
		return _tool_error("anchor must be [x, y, z]")
	var asset_id: String = str(args.get("asset_id", ""))
	var source_path: String = ""
	var source: VoxelModel = null
	var pivot := Vector3.ZERO
	var a: Dictionary = {}
	if asset_id != "":
		a = editor.catalog.asset(asset_id)
		if a.is_empty():
			return _tool_error("unknown asset_id: " + asset_id)
		source = editor.catalog.load_asset(asset_id)
		source_path = str(a.get("path", ""))
		pivot = a.get("pivot", Vector3.ZERO)
	elif args.has("path"):
		source_path = str(args["path"])
		var res: Resource = ResourceLoader.load(source_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		if not (res is VoxelModel):
			return _tool_error("not a VoxelModel: " + source_path)
		source = res as VoxelModel
		a = editor.catalog.asset_at(source_path)
		asset_id = str(a.get("asset_id", ""))
		pivot = a.get("pivot", VoxelPrefabCatalog.default_pivot(source))
	else:
		return _tool_error("asset_id or path is required")
	if source == null:
		return _tool_error("source is missing: " + source_path)
	if args.has("pivot"):
		var p: Variant = _arg_vec3(args, "pivot")
		if p == null:
			return _tool_error("pivot must be [x, y, z]")
		pivot = p
	var yaw: int = int(args.get("yaw", 0))
	var allow: bool = bool(args.get("allow_over_budget", false))
	var result: Dictionary = editor.doc.place_prefab(source, source_path, asset_id,
		pivot, anchor, yaw, allow)
	if not result.get("ok", false):
		return _prefab_error(result)
	editor.selected_prefab_id = int(result["instance_id"])
	editor._sync_prefab_rig()
	return _prefab_instance_payload(int(result["instance_id"]), true)


func _tool_prefab_list_instances(_args: Dictionary) -> Variant:
	var out: Array = []
	for inst: VoxelPrefabInstance in editor.doc.prefab_instances:
		if inst != null:
			out.append(_prefab_instance_payload(inst.instance_id))
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return int(x["id"]) < int(y["id"]))
	return {"instances": out, "count": out.size(),
		"counts": editor.doc.prefab_status_counts(),
		"selected": editor.selected_prefab_id}


func _tool_prefab_get_instance(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	var payload: Dictionary = _prefab_instance_payload(id, true)
	if payload.is_empty():
		return _tool_error("unknown instance id: %d" % id)
	return payload


func _tool_prefab_move(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	var anchor: Variant = _arg_vec3i(args, "anchor")
	if anchor == null:
		return _tool_error("anchor must be [x, y, z]")
	var result: Dictionary = editor.doc.move_prefab(id, anchor)
	if not result.get("ok", false):
		return _prefab_error(result)
	return _prefab_instance_payload(id)


func _tool_prefab_rotate(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	var delta: int = int(args.get("delta", 1))
	var result: Dictionary = editor.doc.rotate_prefab(id, delta)
	if not result.get("ok", false):
		return _prefab_error(result)
	return _prefab_instance_payload(id)


func _tool_prefab_duplicate(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	var anchor: Variant = _arg_vec3i(args, "anchor")
	if anchor == null:
		return _tool_error("anchor is required ([x, y, z])")
	var allow: bool = bool(args.get("allow_over_budget", false))
	var result: Dictionary = editor.doc.duplicate_prefab(id, anchor, allow)
	if not result.get("ok", false):
		return _prefab_error(result)
	var new_id: int = int(result["instance_id"])
	editor.selected_prefab_id = new_id
	editor._sync_prefab_rig()
	return _prefab_instance_payload(new_id, true)


func _tool_prefab_delete(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	var result: Dictionary = editor.doc.delete_prefab(id)
	if not result.get("ok", false):
		return _prefab_error(result)
	if editor.selected_prefab_id == id:
		editor.selected_prefab_id = -1
		editor._sync_prefab_rig()
	return {"deleted": id, "count": editor.doc.prefab_instances.size()}


func _tool_prefab_unpack(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	var result: Dictionary = editor.doc.unpack_prefab(id)
	if not result.get("ok", false):
		return _prefab_error(result)
	if editor.selected_prefab_id == id:
		editor.selected_prefab_id = -1
		editor._sync_prefab_rig()
	return result


func _tool_prefab_relink(args: Dictionary) -> Variant:
	var id: int = int(args.get("id", -1))
	var p: String = str(args.get("path", ""))
	if p == "":
		return _tool_error("path is required")
	var res: VoxelModel = VoxelDocument.load_model_tolerant(p)
	if res == null:
		return _tool_error("not a VoxelModel: " + p)
	var asset_id: String = str(args.get("asset_id", ""))
	if asset_id == "":
		asset_id = str(editor.catalog.asset_at(p).get("asset_id", ""))
	var result: Dictionary = editor.doc.relink_prefab(id, res, p, asset_id)
	if not result.get("ok", false):
		return _prefab_error(result)
	return _prefab_instance_payload(id, true)


func _tool_prefab_reload(_args: Dictionary) -> Variant:
	var result: Dictionary = editor.doc.refresh_prefabs()
	editor.catalog.scan(editor.doc.path.get_base_dir())
	if editor.catalog_dialog != null and editor.catalog_dialog.visible:
		editor.catalog_dialog.refresh()
	return result


func _tool_prefab_get_state(_args: Dictionary) -> Variant:
	var counts: Dictionary = editor.doc.prefab_status_counts()
	var problems: Array = []
	for inst: VoxelPrefabInstance in editor.doc.prefab_instances:
		if inst == null:
			continue
		var st: Dictionary = editor.doc.prefab_status(inst.instance_id)
		if str(st.get("state", "ok")) != "ok":
			problems.append({"id": inst.instance_id, "state": st.get("state", ""),
				"reason": st.get("reason", ""), "source_path": inst.source_path})
	return {
		"instances": editor.doc.prefab_instances.size(),
		"cells": editor.doc.prefab_cell_count(),
		"lights": editor.doc.prefab_light_count(),
		"light_budget": editor.doc.prefab_light_budget,
		"over_budget": editor.doc.prefab_light_budget_exceeded(),
		"counts": counts,
		"problems": problems,
		"selected": editor.selected_prefab_id,
		"armed_asset_id": editor.armed_asset_id,
		"dirty": editor.doc.dirty,
	}


const CHARACTER_SLOTS: Array[String] = ["helmet", "chest", "main_hand", "off_hand"]


func _character_state_payload() -> Dictionary:
	var rig: VoxelCharacterRig = editor.character_rig
	var models: Dictionary = {}
	for k: Variant in editor.doc.character_slots:
		models[str(k)] = str(editor.doc.character_slots[k])
	return {
		"preset": rig.current_preset,
		"preset_name": str(VoxelCharacterRig.PRESETS[rig.current_preset][&"name"]) if rig.current_preset >= 0 else "",
		"slots": {
			"helmet": int(rig.current.get(&"helmet", 0)),
			"chest": int(rig.current.get(&"chest", 0)),
			"main_hand": int(rig.current.get(&"main_hand", 0)),
			"off_hand": int(rig.current.get(&"off_hand", 0)),
		},
		"slot_models": models,
		"anim_state": ["idle", "walk", "run"][clampi(int(rig.state), 0, 2)],
		"attacking": rig.is_attacking(),
		"dirty": editor.doc.dirty,
	}


func _tool_character_get_state(_args: Dictionary) -> Variant:
	return _character_state_payload()


func _tool_character_set_preset(args: Dictionary) -> Variant:
	var rig: VoxelCharacterRig = editor.character_rig
	var idx: int = int(args.get("preset", args.get("preset_index", 0)))
	if idx < 0 or idx >= VoxelCharacterRig.PRESETS.size():
		return _tool_error("preset must be 0..%d" % (VoxelCharacterRig.PRESETS.size() - 1))
	rig.apply_preset(idx)
	editor._refresh_character_ui()
	return _character_state_payload()


func _tool_character_set_slot(args: Dictionary) -> Variant:
	var slot: String = str(args.get("slot", ""))
	if not CHARACTER_SLOTS.has(slot):
		return _tool_error("slot must be one of " + ", ".join(CHARACTER_SLOTS))
	if args.has("index"):
		var rig: VoxelCharacterRig = editor.character_rig
		var count: int = int(VoxelCharacterRig.SWAP_COUNTS.get(StringName(slot), 1))
		var idx: int = clampi(int(args["index"]), 0, count - 1)
		if slot == "chest":
			rig.set_armor_style(idx)
		else:
			rig.set_equipment(StringName(slot), idx)
		editor._refresh_character_ui()
		return _character_state_payload()
	if not args.has("path"):
		return _tool_error("path or index is required")
	var p: String = str(args["path"])
	if p.strip_edges().is_empty():
		editor.character_rig.set_slot_model(StringName(slot), "")
		editor.doc.set_character_slot(slot, "")
		editor._refresh_character_ui()
		return _character_state_payload()
	var err: String = editor.character_rig.set_slot_model(StringName(slot), p)
	if err != "":
		return _tool_error(err)
	editor.doc.set_character_slot(slot, p)
	editor._refresh_character_ui()
	return _character_state_payload()


func _tool_character_set_anim_state(args: Dictionary) -> Variant:
	var name: String = str(args.get("state", "idle")).to_lower()
	var ids: Dictionary = {"idle": 0, "walk": 1, "run": 2}
	if not ids.has(name):
		return _tool_error("state must be one of idle, walk, run")
	editor._set_character_anim_state(int(ids[name]))
	return _character_state_payload()


func _tool_character_play_attack(_args: Dictionary) -> Variant:
	editor._play_character_attack()
	return _character_state_payload()


func _tool_get_composed_voxels(args: Dictionary) -> Variant:
	var include: bool = bool(args.get("include_prefabs", true))
	var cells := {}
	for p: Vector3i in editor.doc.grid:
		cells[p] = {"cell": [p.x, p.y, p.z],
			"color": "#" + (editor.doc.grid[p] as Color).to_html(false), "prefab_id": 0}
	if include:
		for inst: VoxelPrefabInstance in editor.doc.prefab_instances:
			if inst == null:
				continue
			for p: Vector3i in editor.doc.prefab_world_cells(inst.instance_id):
				if cells.has(p):
					continue
				cells[p] = {"cell": [p.x, p.y, p.z],
					"color": "#" + editor.doc.prefab_composition.color_at(p).to_html(false),
					"prefab_id": inst.instance_id}
	var out: Array = cells.values()
	return {"voxels": out, "count": out.size(), "include_prefabs": include}


func _prefab_instance_payload(id: int, verbose: bool = false) -> Dictionary:
	var inst: VoxelPrefabInstance = editor.doc.prefab_instance(id)
	if inst == null:
		return {}
	var st: Dictionary = editor.doc.prefab_status(id)
	var b: AABB = editor.doc.prefab_bounds(id)
	var payload: Dictionary = {
		"id": id,
		"asset_id": inst.asset_id,
		"source_path": inst.source_path,
		"source_resolved": inst.source != null,
		"anchor": [inst.anchor.x, inst.anchor.y, inst.anchor.z],
		"yaw": inst.yaw_quarters,
		"yaw_degrees": inst.yaw_quarters * 90,
		"pivot": [inst.pivot.x, inst.pivot.y, inst.pivot.z],
		"status": str(st.get("state", "ok")),
		"reason": str(st.get("reason", "")),
		"cells": editor.doc.prefab_world_cells(id).size(),
		"lights": editor.doc.prefab_world_lights(id).size(),
		"bounds": _aabb_payload(b),
	}
	if verbose:
		var sb: AABB = inst.source_bounds
		payload["source_uid"] = inst.source_uid
		payload["source_bounds"] = _aabb_payload(sb)
		payload["placeholder_bounds"] = _aabb_payload(inst.placeholder_bounds())
	return payload


static func _aabb_payload(b: AABB) -> Dictionary:
	return {"position": [b.position.x, b.position.y, b.position.z],
		"size": [b.size.x, b.size.y, b.size.z]}


## Document prefab failures carry a state and a human-readable reason. Keep the
## state machine-readable and prefix the message with the failed action.
static func _prefab_error(result: Dictionary) -> Dictionary:
	var state: String = str(result.get("state", "error"))
	return _tool_error("%s: %s" % [state, str(result.get("reason", "prefab operation refused"))])


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
		"material": VoxelMaterial.id(editor.current_material),
		"material_name": VoxelMaterial.display_name(editor.current_material),
		"material_solid": VoxelMaterial.is_solid(editor.current_material, editor.current_material_overrides),
		"material_walkable": VoxelMaterial.is_walkable(editor.current_material, editor.current_material_overrides),
		"material_overrides": editor.current_material_overrides,
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
		"prefab_instances": editor.doc.prefab_instances.size(),
		"prefab_cells": editor.doc.prefab_cell_count(),
		"prefab_lights": editor.doc.prefab_light_count(),
		"prefab_light_budget": editor.doc.prefab_light_budget,
		"prefab_over_budget": editor.doc.prefab_light_budget_exceeded(),
		"prefab_counts": editor.doc.prefab_status_counts(),
		"selected_prefab": editor.selected_prefab_id,
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
		{"name": "set_tool", "description": "Select a tool: place, erase, paint, pick, box, box_erase, fill, light, edit_light, prefab, material.", "inputSchema": {"type": "object", "properties": {"tool": {"type": "string", "enum": ["place", "erase", "paint", "pick", "box", "box_erase", "fill", "light", "edit_light", "prefab", "material"]}}, "required": ["tool"]}},
		{"name": "get_tool", "description": "Currently selected tool.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "set_color", "description": "Set the active color.", "inputSchema": {"type": "object", "properties": {"color": color}, "required": ["color"]}},
		{"name": "get_color", "description": "Active color as hex.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "list_materials", "description": "List the built-in voxel materials with stable id, display name, color, base solid/walkable flags and tags.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "set_material", "description": "Set the active material by id/name, with optional solid/walkable overrides (true/false for override, omit to inherit).", "inputSchema": {"type": "object", "properties": {"material": {"type": "string"}, "solid": {"type": ["boolean", "null"]}, "walkable": {"type": ["boolean", "null"]}}, "required": ["material"]}},
		{"name": "get_material", "description": "Active material, its effective solid/walkable flags, override bits and tags.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "get_voxel", "description": "Color and material metadata for one cell.", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
		{"name": "paint_material", "description": "Apply a material to the existing voxel at cell without changing its color. Optional solid/walkable overrides.", "inputSchema": {"type": "object", "properties": {"cell": cell, "material": {"type": "string"}, "solid": {"type": ["boolean", "null"]}, "walkable": {"type": ["boolean", "null"]}}, "required": ["cell", "material"]}},
		{"name": "place", "description": "Place one voxel at cell with the active color and material (mirror applies). Optional material and solid/walkable overrides.", "inputSchema": {"type": "object", "properties": {"cell": cell, "material": {"type": "string"}, "solid": {"type": ["boolean", "null"]}, "walkable": {"type": ["boolean", "null"]}}, "required": ["cell"]}},
		{"name": "erase", "description": "Erase the voxel at cell (mirror applies).", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
		{"name": "paint", "description": "Recolor the existing voxel at cell; material metadata is preserved.", "inputSchema": {"type": "object", "properties": {"cell": cell, "color": color}, "required": ["cell"]}},
		{"name": "fill", "description": "Flood-recolor all connected voxels sharing the color at cell; material metadata is preserved.", "inputSchema": {"type": "object", "properties": {"cell": cell, "color": color}, "required": ["cell"]}},
		{"name": "place_box", "description": "Fill (or erase with erase=true) the box between cells from and to. Optional material and solid/walkable overrides.", "inputSchema": {"type": "object", "properties": {"from": cell, "to": cell, "color": color, "material": {"type": "string"}, "solid": {"type": ["boolean", "null"]}, "walkable": {"type": ["boolean", "null"]}, "erase": {"type": "boolean"}}, "required": ["from", "to"]}},
		{"name": "place_voxels", "description": "Batch-write many voxels of different colors in one call (one undo step, one mesh rebuild). data = array of \"x,y,z;rrggbb\" strings. Optional material and solid/walkable overrides apply to the whole batch. Much faster than many place calls for large builds.", "inputSchema": {"type": "object", "properties": {"data": {"type": "array", "items": {"type": "string"}}, "material": {"type": "string"}, "solid": {"type": ["boolean", "null"]}, "walkable": {"type": ["boolean", "null"]}}, "required": ["data"]}},
		{"name": "pick", "description": "Sample the voxel at cell: sets the active color, material and overrides (linked prefab cells included).", "inputSchema": {"type": "object", "properties": {"cell": cell}, "required": ["cell"]}},
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
		{"name": "prefab_list_assets", "description": "List reusable prefab assets from the user and project libraries. Filter by library (all/user/project) and a case-insensitive search over name/path. Invalid sources are hidden unless include_invalid=true.", "inputSchema": {"type": "object", "properties": {"library": {"type": "string", "enum": ["all", "user", "project"]}, "search": {"type": "string"}, "include_invalid": {"type": "boolean"}}}},
		{"name": "prefab_refresh_assets", "description": "Rescan the prefab libraries and return the asset summary. Explicit: the catalogue does not watch the filesystem.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "prefab_get_asset", "description": "Details for one catalogue asset by asset_id or path: bounds, cells, lights, pivot, validity, and a cached thumbnail path when one exists.", "inputSchema": {"type": "object", "properties": {"asset_id": {"type": "string"}, "path": {"type": "string"}}}},
		{"name": "prefab_set_pivot", "description": "Set a catalogue asset's custom pivot in source cell space (snapped to multiples of 0.5). Saved in the library manifest.", "inputSchema": {"type": "object", "properties": {"asset_id": {"type": "string"}, "path": {"type": "string"}, "pivot": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}}, "required": ["pivot"]}},
		{"name": "prefab_reset_pivot", "description": "Reset a catalogue asset's pivot to its computed bottom-center default.", "inputSchema": {"type": "object", "properties": {"asset_id": {"type": "string"}, "path": {"type": "string"}}}},
		{"name": "prefab_place", "description": "Place a linked instance of a catalogue asset (asset_id) or any VoxelModel file (path) at anchor [x,y,z]. yaw is quarter turns 0-3. The pivot defaults to the catalogue pivot. Refused on overlap, out of bounds, incompatible sources, or the soft light budget; pass allow_over_budget=true to override the budget only.", "inputSchema": {"type": "object", "properties": {"asset_id": {"type": "string"}, "path": {"type": "string"}, "anchor": cell, "yaw": {"type": "integer"}, "pivot": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}, "allow_over_budget": {"type": "boolean"}}, "required": ["anchor"]}},
		{"name": "prefab_list_instances", "description": "Every linked instance with id, asset, source path, anchor, yaw, pivot, status, cell/light counts and bounds.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "prefab_get_instance", "description": "Full details for one linked instance, including source bounds and placeholder bounds.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
		{"name": "prefab_move", "description": "Move a linked instance to a new anchor cell (integer translation). All-or-nothing: refused if any cell or light would overlap or leave the bounds.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "anchor": cell}, "required": ["id", "anchor"]}},
		{"name": "prefab_rotate", "description": "Rotate a linked instance by delta quarter turns (default 1 = +90°). All-or-nothing like move.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "delta": {"type": "integer"}}}},
		{"name": "prefab_duplicate", "description": "Duplicate a linked instance at a required anchor cell, copying asset, pivot, yaw and source. Refused on overlap or the soft light budget; allow_over_budget overrides the budget only.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "anchor": cell, "allow_over_budget": {"type": "boolean"}}, "required": ["id", "anchor"]}},
		{"name": "prefab_delete", "description": "Delete a linked instance (one undo step).", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
		{"name": "prefab_unpack", "description": "Convert a linked instance into editable voxels and lights atomically (one undo step). Refused if the parent's 32-light limit would be exceeded.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
		{"name": "prefab_relink", "description": "Point a missing/conflicted instance at a new VoxelModel file. Revalidates the whole instance atomically.", "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "path": {"type": "string"}, "asset_id": {"type": "string"}}, "required": ["id", "path"]}},
		{"name": "prefab_reload", "description": "Reload every prefab source from disk and revalidate all instances, then rescan the catalogue. Not undoable and does not dirty the model.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "prefab_get_state", "description": "Prefab summary: instance/cell/light counts, soft light budget, over-budget flag, status counts, and a problem list with reasons.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "character_get_state", "description": "Character rig state: current preset, slot indices, saved-model slot paths, animation state, attack status.", "inputSchema": {"type": "object", "properties": {}}},
		{"name": "character_set_preset", "description": "Apply a class preset (0=Warrior, 1=Barbarian, 2=Cultist, 3=Brigand, 4=Villager) to the live rig. Rewrites the four slot indices; slot model paths are untouched.", "inputSchema": {"type": "object", "properties": {"preset": {"type": "integer", "minimum": 0, "maximum": 4}}}},
		{"name": "character_set_slot", "description": "Set one character part slot (helmet, chest, main_hand, off_hand): either a procedural index, or a saved-model path that overrides it. Empty path clears back to procedural. Saved-model sources containing prefab instances are refused.", "inputSchema": {"type": "object", "properties": {"slot": {"type": "string", "enum": ["helmet", "chest", "main_hand", "off_hand"]}, "index": {"type": "integer"}, "path": {"type": "string"}}, "required": ["slot"]}},
		{"name": "character_set_anim_state", "description": "Preview a locomotion state on the live rig: idle, walk, or run.", "inputSchema": {"type": "object", "properties": {"state": {"type": "string", "enum": ["idle", "walk", "run"]}}}},
		{"name": "character_play_attack", "description": "Play one attack swing on the live rig (upper/lower body split keeps the legs moving).", "inputSchema": {"type": "object", "properties": {}}},
	]
