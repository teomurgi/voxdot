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
	# Keep catalogue scans out of the real ~/Documents/Voxdot/Prefabs.
	_ed.catalog.user_library_override = "/tmp/opencode/mcp_prefab/UserPrefabs"
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
		var parsed: Variant = JSON.parse_string(text) if text.begins_with("{") or text.begins_with("[") else text
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

	print("materials over MCP")
	_ed.doc.reset()
	var mats: Dictionary = (await _call("list_materials"))["_payload"]
	_check((mats["materials"] as Array).size() == VoxelMaterial.count(), "list_materials")
	var setm: Dictionary = (await _call("set_material", {"material": "stone"}))["_payload"]
	_check(setm["id"] == "stone" and setm["solid"] and setm["walkable"], "set_material stone")
	_check((await _call("place", {"cell": [3, 0, 3], "material": "water"}))["_ok"], "place with material")
	var voxel: Dictionary = (await _call("get_voxel", {"cell": [3, 0, 3]}))["_payload"]
	_check(voxel["id"] == "water" and not voxel["solid"], "get_voxel reports water")
	var painted: Dictionary = (await _call("paint_material",
		{"cell": [3, 0, 3], "material": "water", "solid": true, "walkable": true}))["_payload"]
	_check(painted["solid"] and painted["walkable"], "paint_material overrides")
	_check(not (await _call("set_material", {"material": "ston"}))["_ok"], "unknown material rejected")
	_check(not (await _call("place", {"cell": [4, 0, 4], "material": "ston"}))["_ok"], "place rejects unknown material")
	_check((await _call("place", {"cell": [4, 0, 4], "material": "water"}))["_ok"], "place water after rejection")
	# place_box validates before touching editor state: color, active
	# material and the grid must be unchanged when the material is unknown.
	_ed.doc.reset()
	_check((await _call("set_color", {"color": "112233"}))["_ok"], "seed color for place_box check")
	_check((await _call("set_material", {"material": "stone"}))["_ok"], "seed material for place_box check")
	var voxels_before: int = _ed.doc.voxel_count()
	_check(not (await _call("place_box", {"from": [0, 0, 0], "to": [1, 0, 0],
		"color": "ff0000", "material": "ston"}))["_ok"], "place_box rejects unknown material")
	_check(_ed.color == Color("112233"), "place_box error leaves active color unchanged")
	_check(_ed.current_material == VoxelMaterial.Kind.STONE, "place_box error leaves active material unchanged")
	_check(_ed.doc.voxel_count() == voxels_before, "place_box error writes no voxels")
	# A prefab cell covering a local void reports composed walkability; a
	# stacked local stone on top hides the surface below.
	_ed.doc.reset()
	var cover_src := VoxelModel.new()
	cover_src.set_cells({Vector3i(0, 0, 0): Color.RED}, {Vector3i(0, 0, 0): VoxelMaterial.Kind.STONE}, {})
	var cover_placed: Dictionary = _ed.doc.place_prefab(cover_src, "cover.tres", "cover-asset",
		Vector3(0.5, 0, 0.5), Vector3i(8, 0, 8), 0)
	_check(bool(cover_placed.get("ok", false)), "prefab cover placed for get_voxel")
	var covered: Dictionary = (await _call("get_voxel", {"cell": [8, 0, 8]}))["_payload"]
	_check(covered["id"] == "stone" and bool(covered["walkable_surface"]), "get_voxel reports covered prefab surface")
	_ed.doc.place_cells([Vector3i(8, 1, 8)] as Array[Vector3i], Color.BLUE, VoxelMaterial.Kind.STONE)
	var capped: Dictionary = (await _call("get_voxel", {"cell": [8, 0, 8]}))["_payload"]
	_check(not bool(capped["walkable_surface"]), "covering local stone hides the prefab surface")

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

	print("prefabs over MCP")
	_ed.doc.reset()
	var lib_root: String = "/tmp/opencode/mcp_prefab"
	_rmrf(lib_root)
	DirAccess.make_dir_recursive_absolute(lib_root.path_join("Prefabs"))
	var src_grid: Dictionary = {}
	for x in 3:
		for z in 3:
			src_grid[Vector3i(x, 0, z)] = Color.RED
	src_grid[Vector3i(1, 1, 1)] = Color.BLUE
	var src := VoxelModel.from_grid(src_grid)
	src.bounds = Vector3i(16, 16, 16)
	src.lights = PackedFloat32Array([1, 1.0, 2.0, 1.0, 1.0, 0.8, 0.2, 1.5, 6.0, 1.0])
	var src_path: String = lib_root.path_join("Prefabs/mcp_tree.tres")
	_check(ResourceSaver.save(src, src_path) == OK, "prefab source saved")
	var parent_path: String = lib_root.path_join("parent.tres")
	_check((await _call("save", {"path": parent_path}))["_ok"], "parent saved so the project library is known")
	_check((await _call("prefab_refresh_assets"))["_ok"], "prefab_refresh_assets")
	var asset_list: Dictionary = (await _call("prefab_list_assets", {"library": "project", "search": "mcp_tree"}))["_payload"]
	_check(asset_list["count"] == 1, "prefab_list_assets finds the source: " + str(asset_list))
	var asset: Dictionary = asset_list["assets"][0]
	var asset_id: String = str(asset["asset_id"])
	_check(asset["valid"] and asset["cells"] == 10 and asset["lights"] == 1, "asset metadata")
	var got: Dictionary = (await _call("prefab_get_asset", {"asset_id": asset_id}))["_payload"]
	_check(got["name"] == "mcp_tree" and got["path"] == src_path, "prefab_get_asset by id")
	_check((await _call("prefab_get_asset", {"path": src_path}))["_payload"]["asset_id"] == asset_id, "prefab_get_asset by path")
	var pivoted: Dictionary = (await _call("prefab_set_pivot", {"asset_id": asset_id, "pivot": [2.0, 0.0, 2.0]}))["_payload"]
	_check(pivoted["pivot"] == [2.0, 0.0, 2.0], "prefab_set_pivot persists")
	_check((await _call("prefab_set_pivot", {"asset_id": asset_id, "pivot": [1.25, 0.0, 1.0]}))["_ok"] == false, "quarter-cell pivot refused")
	_check((await _call("prefab_reset_pivot", {"asset_id": asset_id}))["_payload"]["pivot"] == [1.5, 0.0, 1.5], "prefab_reset_pivot")

	var placed: Dictionary = (await _call("prefab_place", {"asset_id": asset_id, "anchor": [10, 0, 10]}))["_payload"]
	_check(placed["status"] == "ok" and placed["cells"] == 10, "prefab_place returns a valid instance: " + str(placed))
	var inst_id: int = int(placed["id"])
	_check(placed["lights"] == 1 and _ints(placed["anchor"]) == [10, 0, 10], "placement carries light + anchor")
	_check(((await _call("get_state"))["_payload"] as Dictionary)["prefab_instances"] == 1, "get_state reports the instance")
	_check(((await _call("prefab_get_state"))["_payload"] as Dictionary)["lights"] == 1, "prefab_get_state counts instance lights")
	var composed: Dictionary = (await _call("get_composed_voxels"))["_payload"]
	_check(composed["count"] == 10, "get_composed_voxels includes prefab cells")
	_check((composed["voxels"] as Array).all(func(v: Dictionary) -> bool: return int(v["prefab_id"]) == inst_id), "composed cells carry the owner id")
	_check(((await _call("get_voxels"))["_payload"] as Dictionary)["count"] == 0, "get_voxels stays local-only")
	_check((await _call("prefab_place", {"asset_id": asset_id, "anchor": [10, 0, 10]}))["_ok"] == false, "overlapping placement refused")
	_check((await _call("prefab_place", {"asset_id": asset_id, "anchor": [31, 0, 31]}))["_ok"] == false, "out-of-bounds placement refused")

	var inst_list: Dictionary = (await _call("prefab_list_instances"))["_payload"]
	_check(inst_list["count"] == 1 and inst_list["instances"][0]["id"] == inst_id, "prefab_list_instances")
	_check((await _call("prefab_get_instance", {"id": inst_id}))["_payload"]["source_resolved"], "prefab_get_instance resolves the source")
	_check(_ints((await _call("prefab_move", {"id": inst_id, "anchor": [20, 0, 20]}))["_payload"]["anchor"]) == [20, 0, 20], "prefab_move")
	_check((await _call("prefab_move", {"id": inst_id, "anchor": [31, 0, 31]}))["_ok"] == false, "move out of bounds refused")
	_check((await _call("prefab_rotate", {"id": inst_id, "delta": 1}))["_payload"]["yaw"] == 1, "prefab_rotate")
	var dup: Dictionary = (await _call("prefab_duplicate", {"id": inst_id, "anchor": [2, 0, 20]}))["_payload"]
	_check(dup["status"] == "ok" and int(dup["id"]) != inst_id, "prefab_duplicate")
	_check(dup["yaw"] == 1 and dup["cells"] == 10, "duplicate copies yaw + cells")
	_check((await _call("prefab_duplicate", {"id": inst_id}))["_ok"] == false, "duplicate requires an anchor")
	_check((await _call("prefab_delete", {"id": int(dup["id"])}))["_payload"]["count"] == 1, "prefab_delete")
	_check((await _call("undo"))["_ok"], "undo after prefab delete")
	_check(((await _call("prefab_list_instances"))["_payload"] as Dictionary)["count"] == 2, "undo restores the deleted instance")
	_ed.doc.delete_prefab(int(dup["id"]))

	_check((await _call("prefab_unpack", {"id": inst_id}))["_payload"]["cells"] == 10, "prefab_unpack")
	_check(_ed.doc.prefab_instance(inst_id) == null and _ed.doc.voxel_count() == 10, "unpack wrote editable voxels")
	_check(_ed.doc.lights.size() == 1, "unpack wrote the instance light")
	_check((await _call("undo"))["_ok"] and _ed.doc.prefab_instance(inst_id) != null, "unpack is one undo step")

	print("prefab missing source + relink")
	var hidden: String = src_path + ".hidden"
	DirAccess.rename_absolute(src_path, hidden)
	var reloaded: Dictionary = (await _call("prefab_reload"))["_payload"]
	_check(reloaded["missing"] == 1, "prefab_reload reports the missing source: " + str(reloaded))
	var problems: Array = (await _call("prefab_get_state"))["_payload"]["problems"]
	_check(problems.size() == 1 and problems[0]["state"] == "missing", "prefab_get_state lists the problem")
	_check((await _call("prefab_unpack", {"id": inst_id}))["_ok"] == false, "missing instance cannot be unpacked")
	DirAccess.rename_absolute(hidden, src_path)
	var relinked: Dictionary = (await _call("prefab_relink", {"id": inst_id, "path": src_path}))["_payload"]
	_check(relinked["status"] == "ok", "prefab_relink resolves the source")
	_check((await _call("set_tool", {"tool": "prefab"}))["_ok"], "set_tool prefab")
	_check((await _call("get_tool"))["_payload"]["tool"] == "prefab", "get_tool reports prefab")
	_check(((await _call("prefab_get_instance", {"id": 999}))["_ok"]) == false, "unknown instance errors")

	print("prefab catalogue follows the open model")
	var lib2: String = "/tmp/opencode/mcp_prefab2"
	_rmrf(lib2)
	DirAccess.make_dir_recursive_absolute(lib2.path_join("Prefabs"))
	var other_grid: Dictionary = {Vector3i(0, 0, 0): Color.BLUE, Vector3i(1, 0, 0): Color.BLUE}
	_check(ResourceSaver.save(VoxelModel.from_grid(other_grid),
		lib2.path_join("Prefabs/other.tres")) == OK, "second project source saved")
	_check((await _call("save", {"path": lib2.path_join("parent2.tres")}))["_ok"], "save into the second project")
	var other_list: Dictionary = (await _call("prefab_list_assets",
		{"library": "project", "search": "other"}))["_payload"]
	_check(other_list["count"] == 1,
		"prefab_list_assets rescans after the model moves: " + str(other_list))

	print("character rig over MCP")
	var tools2: Dictionary = await _rpc("tools/list")
	var tool_names: Array = ((tools2.get("result", {}) as Dictionary).get("tools", []) as Array).map(func(t: Dictionary) -> String: return str(t["name"]))
	for expect: String in ["character_get_state", "character_set_preset", "character_set_slot", "character_set_anim_state", "character_play_attack"]:
		_check(tool_names.has(expect), "advertises %s" % expect)
	var cstate: Dictionary = (await _call("character_get_state"))["_payload"]
	_check(cstate["preset"] == 0 and cstate["preset_name"] == "Warrior", "rig defaults to Warrior: " + str(cstate))
	_check((await _call("character_set_preset", {"preset": 1}))["_payload"]["preset_name"] == "Barbarian", "character_set_preset barbarian")
	var cslot: Dictionary = await _call("character_set_slot", {"slot": "main_hand", "path": src_path})
	_check(cslot["_ok"] and str(_ed.doc.character_slots.get("main_hand", "")) == src_path, "character_set_slot assigns saved model")
	var cafter: Dictionary = (await _call("character_get_state"))["_payload"]
	_check(str((cafter["slot_models"] as Dictionary).get("main_hand", "")) == src_path, "character_get_state echoes slot path")
	_check((await _call("character_set_anim_state", {"state": "walk"}))["_payload"]["anim_state"] == "walk", "character_set_anim_state walk")
	_check((await _call("character_play_attack"))["_ok"], "character_play_attack")
	_check((await _call("character_set_slot", {"slot": "bogus", "index": 1}))["_ok"] == false, "bad character slot rejected")
	_check((await _call("character_set_preset", {"preset": 9}))["_ok"] == false, "bad character preset rejected")
	_check((await _call("character_set_slot", {"slot": "main_hand", "path": ""}))["_ok"], "character slot cleared")
	_check(not _ed.doc.character_slots.has("main_hand"), "cleared slot leaves the document")

	print("flipbook over MCP")
	for expect: String in ["anim_get_state", "anim_add_frame", "anim_delete_frame", "anim_set_frame", "anim_set_frame_time", "anim_set_mode", "anim_play", "anim_stop"]:
		_check(tool_names.has(expect), "advertises %s" % expect)
	_check((await _call("anim_get_state"))["_payload"]["frames"] == 1, "static model has 1 frame")
	_check((await _call("anim_add_frame"))["_payload"]["frames"] == 2, "anim_add_frame duplicates")
	_check((await _call("anim_set_frame", {"frame": 1}))["_payload"]["current_frame"] == 1, "anim_set_frame switches")
	_check((await _call("place", {"cell": [7, 0, 7], "color": "ff00ff"}))["_ok"], "paint on frame 1")
	_check((await _call("anim_set_frame", {"frame": 0}))["_ok"], "back to frame 0")
	_check(not _ed.doc.grid.has(Vector3i(7, 0, 7)), "frame 0 unaffected")
	_check((await _call("anim_set_frame_time", {"frame": 1, "secs": 0.2}))["_payload"]["frame_times"][1] == 0.2, "anim_set_frame_time")
	_check((await _call("anim_set_mode", {"mode": "ping-pong"}))["_payload"]["anim_mode"] == "ping-pong", "anim_set_mode")
	_check((await _call("anim_play"))["_payload"]["playing"] == true, "anim_play")
	_check((await _call("anim_set_frame", {"frame": 0}))["_ok"] == false, "frame switch refused while playing")
	_check((await _call("anim_stop"))["_payload"]["playing"] == false, "anim_stop")
	_check((await _call("anim_set_mode", {"mode": "sideways"}))["_ok"] == false, "bad mode rejected")
	_check((await _call("anim_delete_frame", {"frame": 1}))["_payload"]["frames"] == 1, "anim_delete_frame")
	_check((await _call("anim_delete_frame", {"frame": 0}))["_ok"] == false, "last frame protected")

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


func _rmrf(p: String) -> void:
	var d := DirAccess.open(p)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	for sub in d.get_directories():
		_rmrf(p.path_join(sub))
	DirAccess.remove_absolute(p)


## JSON numbers come back as floats; compare cell arrays as integers.
static func _ints(values: Array) -> Array:
	return values.map(func(v: Variant) -> int: return int(v))
