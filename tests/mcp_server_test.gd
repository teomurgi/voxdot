extends SceneTree

## Drives the embedded MCP server over real HTTP: handshake, tool schema,
## and the state changes an agent can make. Run with a port so the server
## is live:
##   VOXDOT_MCP_PORT=7851 godot --headless --path . -s tests/mcp_server_test.gd

var _fails: int = 0
var _ed: VoxelModelEditor
var _http: HTTPClient
var _id: int = 0
const PORT: int = 7851


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok   ", label)
	else:
		print("  FAIL ", label)
		_fails += 1


func _initialize() -> void:
	_ed = (load("res://scenes/voxdot.tscn") as PackedScene).instantiate() as VoxelModelEditor
	root.add_child(_ed)
	_run.call_deferred()


func _rpc(method: String, params: Dictionary = {}) -> Dictionary:
	_id += 1
	var body: String = JSON.stringify({"jsonrpc": "2.0", "id": _id, "method": method, "params": params})
	var err: Error = _http.request(HTTPClient.METHOD_POST, "/", PackedStringArray(["Content-Type: application/json"]), body)
	if err != OK:
		return {"_error": err}
	var resp := PackedByteArray()
	for i in 3000:
		_http.poll()
		var status: int = _http.get_status()
		if status == HTTPClient.STATUS_REQUESTING:
			await process_frame
			continue
		if status == HTTPClient.STATUS_BODY:
			var chunk: PackedByteArray = _http.read_response_body_chunk()
			resp.append_array(chunk)
			if _http.get_response_body_length() > 0 and resp.size() >= _http.get_response_body_length():
				break
		elif status == HTTPClient.STATUS_CONNECTED or status == HTTPClient.STATUS_DISCONNECTED:
			break
		await process_frame
	var parsed: Variant = JSON.parse_string(resp.get_string_from_utf8())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {"_error": "bad json", "_raw": resp.get_string_from_utf8()}


func _call(tool_name: String, args: Dictionary = {}) -> Dictionary:
	var r: Dictionary = await _rpc("tools/call", {"name": tool_name, "arguments": args})
	if r.has("result") and (r["result"] as Dictionary).has("content"):
		var text: String = r["result"]["content"][0]["text"]
		var parsed: Variant = JSON.parse_string(text)
		return {"_ok": not (r["result"] as Dictionary).has("is_error"), "_payload": parsed if typeof(parsed) == TYPE_DICTIONARY else text}
	return {"_ok": false, "_payload": r}


func _run() -> void:
	await process_frame
	await process_frame
	_http = HTTPClient.new()
	var err: Error = _http.connect_to_host("127.0.0.1", PORT)
	_check(err == OK, "connect_to_host")
	while _http.get_status() == HTTPClient.STATUS_CONNECTING or _http.get_status() == HTTPClient.STATUS_RESOLVING:
		_http.poll()
		OS.delay_msec(2)
	_check(_http.get_status() == HTTPClient.STATUS_CONNECTED, "HTTP connected to MCP server")

	print("handshake")
	var init: Dictionary = await _rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}})
	_check((init.get("result", {}) as Dictionary).get("protocolVersion", "") != "", "initialize returns a protocol version")
	_check(((init.get("result", {}) as Dictionary).get("serverInfo", {}) as Dictionary).get("name", "") == "voxdot", "server name is voxdot")

	print("tools/list")
	var listed: Dictionary = await _rpc("tools/list")
	var tools: Array = (listed.get("result", {}) as Dictionary).get("tools", [])
	_check(tools.size() >= 30, "at least 30 tools advertised (got %d)" % tools.size())
	var names: Array = tools.map(func(t: Dictionary) -> String: return t["name"])
	for expect: String in ["set_tool", "place", "begin_stroke", "end_stroke", "set_camera", "screenshot", "save", "open", "set_mirror", "set_height_lock", "set_sun"]:
		_check(names.has(expect), "advertises %s" % expect)

	print("state + editing")
	var st: Dictionary = await _call("get_state")
	var b: Array = (st["_payload"] as Dictionary)["bounds"]
	_check(st["_ok"] and b.map(func(v: Variant) -> int: return int(v)) == [32, 32, 32], "get_state reports default bounds")
	_ed.doc.reset()
	_check((await _call("set_color", {"color": "ff0000"}))["_payload"]["color"] == "#ff0000", "set_color")
	_check((await _call("set_tool", {"tool": "place"}))["_ok"], "set_tool place")
	_check(((await _call("place", {"cell": [5, 0, 5]}))["_payload"] as Dictionary)["count"] == 1, "place adds a voxel")
	_check(_ed.doc.grid.has(Vector3i(5, 0, 5)), "voxel is in the document")
	_check(((await _call("get_voxels"))["_payload"] as Dictionary)["count"] == 1, "get_voxels sees it")
	_check((await _call("paint", {"cell": [5, 0, 5], "color": "0000ff"}))["_ok"], "paint existing voxel")
	_check(_ed.doc.grid[Vector3i(5, 0, 5)] == Color.BLUE, "paint changed the color")
	_check(((await _call("fill", {"cell": [5, 0, 5], "color": "00ff00"}))["_payload"] as Dictionary)["filled"] == 1, "fill recolors connected region")
	_check(((await _call("place_box", {"from": [0, 0, 0], "to": [2, 1, 2], "color": "ffffff"}))["_payload"] as Dictionary)["box_cells"] == 18, "place_box fills 3x2x3")
	var batch: Array = []
	for x in 3:
		batch.append("%d,0,0;%s" % [10 + x, "ff0000" if x == 0 else "00ff00"])
	var batched: Dictionary = await _call("place_voxels", {"data": batch})
	_check((batched["_payload"] as Dictionary)["placed"] == 3, "place_voxels batch writes 3")
	_check(_ed.doc.grid[Vector3i(10, 0, 0)] == Color.RED and _ed.doc.grid[Vector3i(12, 0, 0)] == Color.GREEN, "batch colors land per voxel")
	_ed.doc.erase_cells(([Vector3i(10, 0, 0), Vector3i(11, 0, 0), Vector3i(12, 0, 0)] as Array[Vector3i]))
	_check(((await _call("pick", {"cell": [5, 0, 5]}))["_payload"] as Dictionary)["color"] == "#00ff00", "pick sets active color")
	_check((await _call("erase", {"cell": [5, 0, 5]}))["_ok"], "erase removes")

	print("stroke trio (mirrors a mouse drag)")
	_ed.doc.reset()
	_check((await _call("set_tool", {"tool": "place"}))["_ok"], "tool=place")
	# A drag needs a face to lock onto: place a seed voxel, then drag on its top face.
	_ed.doc.place_cells([Vector3i(10, 0, 10)], Color.RED)
	_check(((await _call("begin_stroke", {"cell": [10, 1, 10]}))["_payload"] as Dictionary)["stroking"] == true, "begin_stroke")
	_check((await _call("update_stroke", {"cell": [11, 1, 10]}))["_ok"], "update_stroke 1")
	_check((await _call("update_stroke", {"cell": [12, 1, 10]}))["_ok"], "update_stroke 2")
	var ended: Dictionary = (await _call("end_stroke"))["_payload"]
	_check(ended["count"] == 4, "stroke placed 3 voxels + seed")
	_check(ended["can_undo"], "stroke is one undo step")
	_check(((await _call("undo"))["_payload"] as Dictionary)["count"] == 1, "undo removes the whole stroke (seed remains)")
	_check(((await _call("redo"))["_payload"] as Dictionary)["count"] == 4, "redo restores it")

	print("box drag via stroke")
	_check((await _call("set_tool", {"tool": "box"}))["_ok"], "tool=box")
	_check((await _call("begin_stroke", {"cell": [20, 1, 20]}))["_ok"], "begin box")
	_check((await _call("update_stroke", {"cell": [22, 1, 21]}))["_ok"], "drag box corner")
	_check(((await _call("end_stroke"))["_payload"] as Dictionary)["count"] == 4 + 3 * 2 * 1, "box drag adds 3x2 (depth 1)")

	print("view + toggles")
	_check((await _call("new_model"))["_ok"], "fresh model for view/bounds tests")
	_ed.doc.place_cells([Vector3i(2, 6, 2)], Color.RED)
	_check(((await _call("set_height_lock", {"on": true, "layer": 7}))["_payload"] as Dictionary)["height_lock"] == true, "height lock on")
	_check(_ed.work_layer == 7, "layer applied")
	_check(((await _call("set_mirror", {"x": true}))["_payload"] as Dictionary)["mirror_x"] == true, "mirror x on")
	_check(((await _call("set_render_horizon", {"horizon": 0}))["_payload"] as Dictionary)["render_horizon"] == 0, "horizon 0 = unlimited")
	_check(((await _call("get_state"))["_payload"] as Dictionary)["render_horizon"] == 0, "state reports 0 for unlimited horizon")
	_check(((await _call("set_render_horizon", {"horizon": 16}))["_payload"] as Dictionary)["render_horizon"] == 16, "horizon 16 caps meshing")
	_check((await _call("set_render_horizon", {"horizon": 0}))["_ok"], "horizon back to unlimited")
	_check(((await _call("set_grid_visible", {"visible": false}))["_payload"] as Dictionary)["grid_visible"] == false, "grid hidden")
	_check(((await _call("set_orthographic", {"on": true}))["_payload"] as Dictionary)["orthographic"] == true, "ortho on")
	var cam: Dictionary = ((await _call("set_camera", {"yaw": 90, "pitch": -45, "distance": 50}))["_payload"] as Dictionary)
	_check(is_equal_approx(cam["yaw"], 90.0), "camera yaw set")
	_check(((await _call("orbit", {"dx": 10, "dy": 0}))["_payload"] as Dictionary)["yaw"] < 90.0, "orbit moves yaw")
	_check(((await _call("zoom", {"steps": 2}))["_payload"] as Dictionary)["distance"] < 50.0, "zoom in shortens distance")
	_check((await _call("frame"))["_ok"], "frame model")
	_check(((await _call("set_bounds", {"bounds": [16, 16, 16]}))["_payload"] as Dictionary)["bounds"].map(func(v: Variant) -> int: return int(v)) == [16, 16, 16], "bounds shrink")
	# Voxel sits at (2,6,2): any shrink below y=7 must be refused.
	var refused: Dictionary = await _call("set_bounds", {"bounds": [16, 6, 16]})
	_check(refused["_ok"] == false, "shrink below voxels refused")
	_check(((await _call("set_box_depth", {"depth": 4}))["_payload"] as Dictionary)["box_depth"] == 4, "box depth")

	print("lights over MCP")
	_ed.doc.reset()
	var added: Dictionary = (await _call("add_light", {"position": [4, 2, 6], "color": "ffcc88", "energy": 2.0, "range": 14.0}))["_payload"]
	_check(added["id"] > 0 and added["count"] == 1, "add_light returns id")
	var light_id: int = added["id"]
	_check((await _call("get_lights"))["_payload"]["count"] == 1, "get_lights lists it")
	_check((await _call("select_light", {"id": light_id}))["_payload"]["selected"] == light_id, "select_light")
	_check(((await _call("update_light", {"id": light_id, "position": [5, 3, 6], "energy": 4.0}))["_payload"] as Dictionary)["light"]["energy"] == 4.0, "update_light edits")
	_check((await _call("add_light", {"position": [99, 0, 0]}))["_ok"] == false, "out-of-bounds light errors")
	_check(((await _call("get_state"))["_payload"] as Dictionary)["lights"] == 1, "get_state reports light count")
	_check((await _call("remove_light", {"id": light_id}))["_payload"]["count"] == 0, "remove_light deletes")
	_check((await _call("remove_light", {"id": light_id}))["_ok"] == false, "removing twice errors")
	var sun: Dictionary = ((await _call("set_sun", {"energy": 1.4, "yaw": 120, "pitch": -30, "color": "ffd9a0", "shadows": false}))["_payload"] as Dictionary)
	_check(is_equal_approx(sun["energy"], 1.4) and is_equal_approx(sun["yaw"], 120.0), "set_sun edits energy and yaw")
	_check(absf(_ed.sun.light_energy - 1.4) < 0.01 and is_equal_approx(_ed.sun.rotation_degrees.y, 120.0), "sun reaches the scene light")
	_check(not _ed.sun.shadow_enabled, "sun shadows toggle")
	_check((await _call("set_sun", {}))["_ok"] == false, "set_sun without properties errors")
	_check(_ed.doc.dirty, "sun change marks the document dirty")

	print("file IO")
	_ed.doc.reset()
	_ed.doc.place_cells([Vector3i(3, 0, 3)] as Array[Vector3i], Color.RED)
	_ed.doc.add_light({"position": Vector3(4, 2, 4)})
	_ed.set_sun_properties({"energy": 0.3, "yaw": -42.0, "color": Color("aabbcc")})
	var expected_voxels: int = _ed.doc.voxel_count()
	var path: String = OS.get_user_data_dir().path_join("mcp_test.tres")
	_check(((await _call("save", {"path": path}))["_payload"] as Dictionary)["path"] == path, "save to path")
	_check((await _call("new_model"))["_ok"], "new model")
	_check(is_equal_approx(_ed.sun.light_energy, VoxelDocument.DEFAULT_SUN_ENERGY), "new model restores the default sun")
	_check(((await _call("open", {"path": path}))["_payload"] as Dictionary)["count"] == expected_voxels, "open restores voxels")
	_check(((await _call("get_lights"))["_payload"] as Dictionary)["count"] == 1, "open restores lights too")
	_check(absf(_ed.sun.light_energy - 0.3) < 0.01 and is_equal_approx(_ed.sun.rotation_degrees.y, -42.0), "open restores the saved sun")
	DirAccess.remove_absolute(path)

	print("screenshot")
	var shot: Dictionary = await _call("screenshot")
	# Headless has no real viewport texture; on a live window this returns a PNG path.
	if shot["_ok"]:
		_check(FileAccess.file_exists(shot["_payload"]["path"]), "screenshot file written")
		DirAccess.remove_absolute(shot["_payload"]["path"])
	else:
		_check(str(shot["_payload"]).contains("headless") or str(shot["_payload"]).contains("texture"), "screenshot reports headless cleanly")

	print("errors")
	_check((await _call("bogus_tool"))["_ok"] == false, "unknown tool errors")
	_check((await _call("place", {"cell": [999, 0, 0]}))["_ok"] == false, "out-of-bounds place errors")
	_check((await _call("end_stroke"))["_ok"] == false, "end_stroke without stroke errors")

	print("mcp_server_test: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	quit(1 if _fails > 0 else 0)
