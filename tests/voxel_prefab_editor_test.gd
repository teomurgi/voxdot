extends SceneTree

## End-to-end editor coverage for the prefab tool: catalogue placement, ghost,
## selection, drag, rotate, duplicate, delete/undo, linked-cell refusal,
## unpack, missing-source placeholders and the catalogue dialog.
## Run: godot --headless --path . -s tests/voxel_prefab_editor_test.gd

var _fails: int = 0
var _ed: VoxelModelEditor
var _last_pos: Vector2 = Vector2.ZERO
var _dir: String = "/tmp/opencode/voxdot_prefab_editor_test"


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


func _move(pos: Vector2, mask: int = 0) -> void:
	var e := InputEventMouseMotion.new()
	e.relative = pos - _last_pos
	_last_pos = pos
	e.position = pos
	e.global_position = pos
	e.button_mask = mask
	Input.parse_input_event(e)


func _button(pos: Vector2, index: MouseButton, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = pos
	e.global_position = pos
	e.button_index = index
	e.pressed = pressed
	e.button_mask = (1 << (index - 1)) if pressed else 0
	Input.parse_input_event(e)


func _key(code: Key, ctrl: bool = false, shift: bool = false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		e.shift_pressed = shift
		Input.parse_input_event(e)


func _frames(n: int = 3) -> void:
	for i in n:
		await process_frame


func _screen(world: Vector3) -> Vector2:
	return _ed.camera.unproject_position(world)


func _click(pos: Vector2) -> void:
	_move(pos)
	await _frames(2)
	_button(pos, MOUSE_BUTTON_LEFT, true)
	await _frames(2)
	_button(pos, MOUSE_BUTTON_LEFT, false)
	await _frames(3)


func _has_mesh() -> bool:
	for key: Vector2i in _ed._chunks:
		for cy: int in _ed._chunks[key]:
			var rec: Dictionary = _ed._chunks[key][cy]
			if rec["mi"] != null and (rec["mi"] as MeshInstance3D).mesh != null \
					and (rec["mi"] as MeshInstance3D).mesh.get_surface_count() > 0:
				return true
	return false


func _run() -> void:
	await _frames(2)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	await _frames(3)
	Input.use_accumulated_input = false

	_rmrf(_dir)
	DirAccess.make_dir_recursive_absolute(_dir.path_join("Prefabs"))
	var grid: Dictionary = {}
	for x in 3:
		for z in 3:
			grid[Vector3i(x, 0, z)] = Color.RED
	grid[Vector3i(1, 1, 1)] = Color.BLUE
	var source := VoxelModel.from_grid(grid)
	source.bounds = Vector3i(16, 16, 16)
	source.lights = PackedFloat32Array([1, 1.0, 2.0, 1.0, 1.0, 0.8, 0.2, 1.5, 6.0, 1.0])
	var src_path: String = _dir.path_join("Prefabs/tree.tres")
	_check(ResourceSaver.save(source, src_path) == OK, "source saved")

	_ed.doc.reset()
	_ed.catalog.user_library_override = _dir.path_join("UserPrefabs")
	var summary: Dictionary = _ed.catalog.scan(_dir)
	_check(int(summary.get("assets", 0)) >= 1, "catalogue scan: " + str(summary))
	var asset: Dictionary = _ed.catalog.asset_at(src_path)
	_check(not asset.is_empty() and bool(asset["valid"]), "asset valid: " + str(asset))
	_check(asset.get("pivot", Vector3.ZERO) == Vector3(1.5, 0, 1.5), "default pivot: " + str(asset.get("pivot")))

	_ed._on_catalogue_place(str(asset["asset_id"]))
	await _frames(2)
	_check(_ed.current_tool == VoxelModelEditor.Tool.PREFAB, "catalogue place switches to Prefab tool")
	_check(_ed.armed_source != null, "asset armed")

	print("ghost + placement")
	var p: Vector2 = _screen(Vector3(10.5, 0, 10.5))
	_check(p.x > 300, "target outside the side panel")
	_move(p)
	await _frames(3)
	_check(_ed._hover.get("valid", false), "hover valid: " + str(_ed._hover))
	_check(_ed.prefab_rig._ghost.visible or _ed.prefab_rig._ghost_box.visible, "ghost visible")
	await _click(p)
	_check(_ed.doc.prefab_instances.size() == 1, "one instance placed")
	_check(_ed.doc.prefab_cell_count() == 10, "10 linked cells")
	_check(_ed.doc.prefab_light_count() == 1, "one instance light")
	_check(_ed.prefab_rig.get_node("PrefabLights").get_child_count() == 1, "instance light rendered")
	var light_root: Node3D = _ed.prefab_rig.get_node("PrefabLights")
	var id: int = _ed.doc.prefab_instances[0].instance_id
	for i in 4:
		_ed._sync_prefab_rig()
	_check(light_root.get_child_count() == 1, "repeated sync keeps one light node")
	var light_node: OmniLight3D = light_root.get_child(0)
	_ed.doc.move_prefab(id, Vector3i(12, 0, 10))
	_ed._sync_prefab_rig()
	_check(light_root.get_child_count() == 1 and light_root.get_child(0) == light_node,
		"move retunes the cached light node")
	_check((light_root.get_child(0) as OmniLight3D).position
		== _ed.doc.prefab_world_lights(id)[0]["position"], "cached light follows the instance")
	_ed.doc.move_prefab(id, Vector3i(10, 0, 10))
	_ed._sync_prefab_rig()
	_check(_has_mesh(), "chunk mesh contains prefab cells")
	_check(_ed.selected_prefab_id == id, "new instance selected")
	_check(_ed.doc.prefab_instance(id).anchor == Vector3i(10, 0, 10), "anchor at hover cell: " + str(_ed.doc.prefab_instance(id).anchor))

	print("rotate + duplicate")
	_ed.disarm_prefab()
	_ed._set_tool(VoxelModelEditor.Tool.PREFAB)
	_key(KEY_R)
	await _frames(2)
	_check(_ed.doc.prefab_instance(id).yaw_quarters == 1, "R rotates the selection")
	var before_dup: int = _ed.doc.prefab_instances.size()
	_key(KEY_D, true)
	await _frames(2)
	_check(_ed.armed_source != null, "Ctrl+D arms a duplicate")
	_check(_ed.doc.prefab_instances.size() == before_dup, "original stays until placed")
	var q: Vector2 = _screen(Vector3(20.5, 0, 20.5))
	await _click(q)
	_check(_ed.doc.prefab_instances.size() == before_dup + 1, "duplicate placed")
	_check(_ed.doc.prefab_instance(id).yaw_quarters == 1, "duplicate copies yaw")
	_ed.disarm_prefab()

	print("delete + undo")
	var count: int = _ed.doc.prefab_instances.size()
	_ed.selected_prefab_id = _ed.doc.prefab_instances[1].instance_id
	_key(KEY_DELETE)
	await _frames(2)
	_check(_ed.doc.prefab_instances.size() == count - 1, "Delete removes the instance")
	_key(KEY_Z, true)
	await _frames(2)
	_check(_ed.doc.prefab_instances.size() == count, "undo restores the instance")

	print("linked cells refuse edit tools")
	_ed._set_tool(VoxelModelEditor.Tool.PAINT)
	var target: Vector2 = _screen(Vector3(9.5, 0.5, 9.5))
	_move(target)
	await _frames(3)
	_check(_ed._hover.get("valid", false), "paint hover valid")
	var color_before: Color = _ed.doc.prefab_composition.color_at(Vector3i(9, 0, 9))
	_ed._set_color(Color.GREEN)
	await _click(target)
	_check(_ed.doc.prefab_composition.color_at(Vector3i(9, 0, 9)) == color_before, "paint does not touch linked cells")
	_check(_ed._message_label.text.contains("unpack to edit"), "message says unpack to edit: " + _ed._message_label.text)

	print("box refuses a linked region")
	_ed._set_tool(VoxelModelEditor.Tool.BOX)
	_ed.box_depth = 1
	_ed._stroke_tool = VoxelModelEditor.Tool.BOX
	_ed._plane_axis = 1
	_ed._plane_layer = 0
	_ed._stroke_start = Vector3i(8, 0, 8)
	_ed._box_end = Vector3i(11, 0, 11)
	_ed._stroking = true
	_ed.doc.begin_stroke()
	var before_box: int = _ed.doc.voxel_count()
	_ed._finish_stroke()
	_check(_ed.doc.voxel_count() == before_box, "box place over linked cells writes nothing")
	_check(_ed._message_label.text.contains("unpack to edit"), "box refusal says unpack to edit")
	# Mirrored copies count too: a box at x=20..21 mirrors onto the instance.
	_ed._set_mirror(true, false)
	_ed._stroke_tool = VoxelModelEditor.Tool.BOX
	_ed._plane_axis = 1
	_ed._plane_layer = 0
	_ed._stroke_start = Vector3i(20, 0, 9)
	_ed._box_end = Vector3i(21, 0, 11)
	_ed._stroking = true
	_ed.doc.begin_stroke()
	before_box = _ed.doc.voxel_count()
	_ed._finish_stroke()
	_check(_ed.doc.voxel_count() == before_box, "mirrored box overlap is refused too")
	_ed._set_mirror(false, false)

	print("ghost cache + hint")
	_ed.arm_prefab(str(asset["asset_id"]), source, asset.get("pivot", Vector3.ZERO))
	_ed._set_tool(VoxelModelEditor.Tool.PREFAB)
	var cache_anchor := Vector3i(4, 0, 4)
	_ed._ghost_candidate(cache_anchor)
	_check(_ed._ghost_check_key != "", "candidate result cached")
	_ed.doc.place_cells([Vector3i(1, 0, 1)], Color.WHITE)
	_check(_ed._ghost_check_key == "", "document edit invalidates the ghost cache")
	_ed.doc.undo()
	_ed._hover = {"valid": false}
	_ed._update_prefab_ghost()
	_check(_ed._hint_label.text == VoxelModelEditor.TOOL_HINTS[int(VoxelModelEditor.Tool.PREFAB)],
		"hint resets when placement is invalid")

	print("selection by click + move drag")
	_ed._set_tool(VoxelModelEditor.Tool.PREFAB)
	_ed._select_prefab(-1)
	_ed.disarm_prefab()
	var anchor_before: Vector3i = _ed.doc.prefab_instance(id).anchor
	var body: Vector2 = _screen(Vector3(10.5, 0.5, 10.5))
	_move(body)
	await _frames(3)
	_button(body, MOUSE_BUTTON_LEFT, true)
	await _frames(2)
	_check(_ed.selected_prefab_id == id, "click selects the instance: " + str(_ed.selected_prefab_id))
	_check(_ed._prefab_drag_active, "press starts a move drag")
	var to: Vector2 = _screen(Vector3(14.5, 0.5, 10.5))
	_move(to, MOUSE_BUTTON_MASK_LEFT)
	await _frames(4)
	_button(to, MOUSE_BUTTON_LEFT, false)
	await _frames(3)
	_check(not _ed._prefab_drag_active, "drag released")
	_check(_ed.doc.prefab_instance(id).anchor != anchor_before, "instance moved: " + str(_ed.doc.prefab_instance(id).anchor))

	print("unpack")
	_ed.selected_prefab_id = id
	var cells_before: int = _ed.doc.prefab_cell_count()
	var local_before: int = _ed.doc.voxel_count()
	_ed._unpack_selected_prefab()
	await _frames(3)
	_check(_ed.doc.prefab_instance(id) == null, "unpack removes the instance")
	_check(_ed.doc.prefab_cell_count() == cells_before - 10, "linked cells gone")
	_check(_ed.doc.voxel_count() == local_before + 10, "voxels written")
	_check(_ed.doc.lights.size() == 1, "instance light unpacked")
	_key(KEY_Z, true)
	await _frames(2)
	_check(_ed.doc.prefab_instance(id) != null, "undo restores the instance")

	print("missing source placeholder")
	var hidden: String = src_path + ".hidden"
	DirAccess.rename_absolute(src_path, hidden)
	_ed.doc.refresh_prefabs()
	await _frames(3)
	var st: Dictionary = _ed.doc.prefab_status(id)
	_check(str(st.get("state", "")) == "missing", "instance missing after source removed: " + str(st))
	_check(_ed.prefab_rig._placeholders.size() == 2, "red placeholders drawn: " + str(_ed.prefab_rig._placeholders.size()))
	_ed._set_tool(VoxelModelEditor.Tool.PREFAB)
	var box: AABB = _ed.doc.prefab_instance(id).placeholder_bounds()
	var center: Vector2 = _screen(box.get_center())
	_move(center)
	await _frames(3)
	_check(int(_ed._hover.get("prefab_id", 0)) == id, "placeholder hover picks the instance: " + str(_ed._hover))
	await _click(center)
	_check(_ed.selected_prefab_id == id, "placeholder click selects")
	DirAccess.rename_absolute(hidden, src_path)
	_ed.doc.refresh_prefabs()
	await _frames(2)
	_check(str(_ed.doc.prefab_status(id).get("state", "")) == "ok", "relink by restoring the file + refresh")

	print("catalogue dialog")
	_ed.catalog_dialog.setup(_ed.catalog, _ed.doc, _dir)
	_ed.catalog_dialog.open_assets()
	await _frames(3)
	_check(_ed.catalog_dialog.visible, "catalogue opens")
	_check(_ed.catalog_dialog._grid.get_child_count() >= 1, "grid has asset buttons")
	var launch_args: PackedStringArray = VoxelPrefabCatalogDialog.new_instance_args("/tmp/kind.tres")
	_check(launch_args.size() == 4 and launch_args[0] == "--path" \
		and launch_args[2] == "--" and launch_args[3] == "/tmp/kind.tres",
		"editor launch args: " + str(launch_args))
	_ed.catalog_dialog._select_asset(str(asset["asset_id"]))
	await _frames(2)
	_check(_ed.catalog_dialog._place_button.disabled == false, "Place enabled for a valid asset")
	_ed.catalog_dialog._pivot_spins[0].value = 2.0
	await _frames(2)
	_check(_ed.catalog.asset(str(asset["asset_id"]))["pivot"] == Vector3(2, 0, 1.5), "pivot edit persists: " + str(_ed.catalog.asset(str(asset["asset_id"]))["pivot"]))
	_ed.catalog_dialog._reset_pivot()
	await _frames(2)
	_check(_ed.catalog.asset(str(asset["asset_id"]))["pivot"] == Vector3(1.5, 0, 1.5), "pivot reset")
	# Click-to-pick: project the top face of the near corner cell into the
	# preview camera, then feed the container-local position back.
	_ed.catalog_dialog._preview_container.size = Vector2(320, 230)
	var vp_click: Vector2 = _ed.catalog_dialog._preview_camera.unproject_position(Vector3(2.5, 1.0, 2.5))
	var container_click: Vector2 = vp_click / Vector2(_ed.catalog_dialog._preview_viewport.size) \
		* _ed.catalog_dialog._preview_container.size
	_ed.catalog_dialog._pick_pivot(container_click)
	await _frames(2)
	_check(_ed.catalog.asset(str(asset["asset_id"]))["pivot"] == Vector3(2.5, 1.0, 2.5),
		"click-to-pick pivot: " + str(_ed.catalog.asset(str(asset["asset_id"]))["pivot"]))
	_ed.catalog_dialog._reset_pivot()
	await _frames(2)
	# Double-click wiring: scan a real asset, then remove its file so the
	# handler reports a missing source instead of spawning another editor.
	var ghost := VoxelModel.from_grid({Vector3i(0, 0, 0): Color.RED})
	ghost.bounds = Vector3i(4, 4, 4)
	var ghost_path: String = _dir.path_join("Prefabs/ghost.tres")
	_check(ResourceSaver.save(ghost, ghost_path) == OK, "ghost asset saved")
	_ed.catalog.scan(_dir)
	_ed.catalog_dialog.setup(_ed.catalog, _ed.doc, _dir)
	_ed.catalog_dialog.open_assets()
	await _frames(3)
	DirAccess.remove_absolute(ghost_path)
	var ghost_button: Button = null
	for child: Node in _ed.catalog_dialog._grid.get_children():
		if child is Button and (child as Button).text == "ghost":
			ghost_button = child as Button
			break
	_check(ghost_button != null, "ghost asset has a catalogue button")
	if ghost_button != null:
		var double_click := InputEventMouseButton.new()
		double_click.button_index = MOUSE_BUTTON_LEFT
		double_click.pressed = true
		double_click.double_click = true
		ghost_button.gui_input.emit(double_click)
		await _frames(1)
		_check(_ed.catalog_dialog._status.text.contains("missing"),
			"double-click on a missing source reports an error")
	_ed.catalog_dialog.hide()
	await _frames(2)

	print("voxel_prefab_editor_test: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
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
