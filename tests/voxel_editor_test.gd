extends SceneTree

## Drives the voxel editor scene through its camera-ray hover and stroke
## logic (no real mouse): placing, stacking, erasing, painting, picking,
## box/fill tools, mirror, undo, file round-trip.
## Run: godot --headless --path godot -s tests/voxel_editor_test.gd

var _fails: int = 0
var _ed: VoxelModelEditor


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


func _run() -> void:
	await process_frame
	await process_frame
	_ed.doc.reset()
	_ed.frame_model()
	_ed._update_camera()
	await process_frame
	_test_place_stack_erase()
	_test_paint_pick_fill()
	_test_box_and_mirror()
	_test_height_lock()
	_test_render_horizon()
	_test_panel_layout()
	_test_fit_bounds()
	await _test_lights_editor()
	await _test_mesh_and_file()
	_test_standalone()
	print("voxel_editor_test: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	quit(1 if _fails > 0 else 0)


## Screen-space ray through the center of a voxel-space point.
func _hover_at(world: Vector3) -> Dictionary:
	var screen: Vector2 = _ed.camera.unproject_position(world)
	var o: Vector3 = _ed.camera.project_ray_origin(screen)
	var d: Vector3 = _ed.camera.project_ray_normal(screen)
	return _ed._compute_hover(o, d)


func _click(world: Vector3) -> void:
	var h: Dictionary = _hover_at(world)
	if not h["valid"]:
		return
	_ed._begin_stroke(h)
	if _ed._stroking:
		_ed._finish_stroke()


func _test_place_stack_erase() -> void:
	print("place / stack / erase via camera rays")
	_ed._set_color(Color.RED)
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)
	_click(Vector3(10.5, 0.0, 10.5))
	_check(_ed.doc.grid.has(Vector3i(10, 0, 10)), "click on floor places at that cell")
	_click(Vector3(10.5, 1.0, 10.5))
	_check(_ed.doc.grid.has(Vector3i(10, 1, 10)), "click on top face stacks upward")
	_ed._set_tool(VoxelModelEditor.Tool.ERASE)
	_click(Vector3(10.5, 2.0, 10.5))
	_check(not _ed.doc.grid.has(Vector3i(10, 1, 10)) and _ed.doc.grid.has(Vector3i(10, 0, 10)), "erase removes the voxel under cursor only")
	_ed._do_undo()
	_check(_ed.doc.grid.has(Vector3i(10, 1, 10)), "undo erase")
	_check(not _hover_at(Vector3(-50, 0, -50))["valid"], "hover off the bounds is invalid")


func _test_paint_pick_fill() -> void:
	print("paint / pick / fill")
	_ed._set_tool(VoxelModelEditor.Tool.PAINT)
	_ed._set_color(Color.BLUE)
	_click(Vector3(10.5, 2.0, 10.5))
	_check(_ed.doc.grid[Vector3i(10, 1, 10)] == Color.BLUE, "paint recolors hit voxel")
	_check(_ed.doc.grid[Vector3i(10, 0, 10)] == Color.RED, "paint leaves neighbours")
	_ed._set_tool(VoxelModelEditor.Tool.PICK)
	_click(Vector3(10.5, 2.0, 10.5))
	_check(_ed.color == Color.BLUE, "pick sets the active color from the voxel under cursor")
	_ed._set_color(Color.GREEN)
	_ed._set_tool(VoxelModelEditor.Tool.FILL)
	_click(Vector3(10.5, 2.0, 10.5))
	_check(_ed.doc.grid[Vector3i(10, 1, 10)] == Color.GREEN, "fill recolors connected region")


func _test_box_and_mirror() -> void:
	print("box / mirror")
	_ed.doc.reset()
	_ed._set_color(Color.ORANGE)
	_ed._set_tool(VoxelModelEditor.Tool.BOX)
	_ed.box_depth = 2
	var h: Dictionary = _hover_at(Vector3(4.5, 0.0, 4.5))
	_ed._begin_stroke(h)
	_check(_ed._stroking, "box stroke begins")
	_ed._box_end = Vector3i(6, 0, 6)
	_ed._finish_stroke()
	_check(_ed.doc.voxel_count() == 3 * 3 * 2, "3x3 box extruded 2 layers up (18 voxels)")
	_check(_ed.doc.grid.has(Vector3i(6, 1, 6)) and not _ed.doc.grid.has(Vector3i(6, 2, 6)), "extrusion goes away from the floor")
	_ed._set_tool(VoxelModelEditor.Tool.BOX_ERASE)
	_ed.box_depth = 1
	h = _hover_at(Vector3(5.5, 2.0, 5.5))
	_ed._begin_stroke(h)
	_ed._box_end = Vector3i(6, 1, 6)
	_ed._finish_stroke()
	_check(_ed.doc.voxel_count() == 18 - 4, "box erase removes a 2x2 patch of the top layer (14 left)")
	_ed.doc.reset()
	_ed._set_mirror(true, false)
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)
	_click(Vector3(3.5, 0.0, 5.5))
	_check(_ed.doc.grid.has(Vector3i(3, 0, 5)) and _ed.doc.grid.has(Vector3i(28, 0, 5)), "mirror X places the twin voxel")
	_ed._set_mirror(false, false)


func _test_height_lock() -> void:
	print("height lock")
	_ed.doc.reset()
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)
	_ed._set_color(Color.RED)
	_check(not _hover_at(Vector3(10.5, 5.0, 10.5))["valid"] or _hover_at(Vector3(10.5, 5.0, 10.5))["cell"].y == 0, "without lock, empty space resolves to the floor")
	_ed._step_layer(5)
	_check(_ed.height_lock and _ed.work_layer == 5, "changing layer enables the lock at that height")
	_click(Vector3(10.5, 5.0, 10.5))
	_check(_ed.doc.grid.has(Vector3i(10, 5, 10)) and _ed.doc.voxel_count() == 1, "place lands at layer 5 in mid-air")
	_ed.doc.place_cells([Vector3i(12, 0, 12), Vector3i(12, 9, 12)] as Array[Vector3i], Color.BLUE)
	_click(Vector3(12.5, 5.0, 12.5))
	_check(_ed.doc.grid.has(Vector3i(12, 5, 12)), "lock ignores voxels above/below the plane")
	_ed._set_tool(VoxelModelEditor.Tool.BOX)
	_ed._begin_stroke(_hover_at(Vector3(2.5, 5.0, 2.5)))
	_ed._box_end = Vector3i(3, 5, 3)
	_ed._finish_stroke()
	_check(_ed.doc.grid.has(Vector3i(2, 5, 2)) and _ed.doc.grid.has(Vector3i(3, 5, 3)) and not _ed.doc.grid.has(Vector3i(3, 4, 3)), "box also builds on the locked layer")
	_ed._step_layer(-99)
	_check(_ed.work_layer == 0, "layer clamps at 0")
	_ed._step_layer(999)
	_check(_ed.work_layer == _ed.doc.bounds.y - 1, "layer clamps at top of bounds")
	_ed._set_height_lock(false)
	_ed._set_layer(0)
	_ed._set_height_lock(false)


func _test_render_horizon() -> void:
	print("render horizon")
	_ed.doc.reset()
	_ed.doc.resize_bounds(Vector3i(128, 32, 128))
	# Voxels in all four chunk quadrants (CHUNK_SIZE = 64); their centers are
	# (32,32), (96,32), (32,96) and (96,96) in the xz plane.
	_ed.doc.place_cells([Vector3i(1, 0, 1), Vector3i(100, 0, 1), Vector3i(1, 0, 100), Vector3i(100, 0, 100)] as Array[Vector3i], Color.RED)
	_check(_ed.doc.voxel_count() == 4, "fixture places all four voxels")
	_ed.set_render_horizon(0)
	_check(_ed.render_horizon == VoxelModelEditor.UNLIMITED_HORIZON, "horizon 0 means unlimited")
	_check(_ed._chunks.size() == 4, "unlimited horizon meshes all four chunk quadrants (got %d)" % _ed._chunks.size())
	# Camera above the origin corner: a 64 radius keeps only the chunk whose
	# center is ~45 away; the two adjacent ones are ~101 away.
	_ed.camera.global_position = Vector3(0, 40, 0)
	_ed.set_render_horizon(64)
	_check(_ed._chunks.size() == 1 and _ed._chunks.has(Vector2i(0, 0)), "radius 64 around the camera keeps only the nearest chunk")
	# Raising the horizon reveals strictly farther chunks (no near popping).
	_ed.set_render_horizon(128)
	_check(_ed._chunks.size() == 3, "radius 128 adds the two adjacent chunks (got %d)" % _ed._chunks.size())
	# Moving the camera toward the far corner keeps only what is near it.
	_ed.camera.global_position = Vector3(128, 40, 128)
	_ed.set_render_horizon(64)
	_check(_ed._chunks.size() == 1 and _ed._chunks.has(Vector2i(1, 1)), "the horizon follows the camera")
	_ed.set_render_horizon(0)
	_check(_ed._chunks.size() == 4, "back to unlimited keeps all chunks")
	# Restore the camera the following tests expect.
	_ed._focus = Vector3(64, 0, 64)
	_ed._update_camera()
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)


func _test_panel_layout() -> void:
	print("panel layout")
	var headers: Array[Button] = _section_headers(_ed.get_node("UI"))
	var names: Array[String] = []
	for h: Button in headers:
		names.append(h.text.substr(3))
	_check(names == ["File", "Model", "Tool", "Color", "Sun (directional)", "Lighting — point lights", "Prefabs", "View"],
			"sections are ordered File → View (got %s)" % [names])
	_check(not headers.is_empty() and headers[0].text.begins_with("▼"), "File is first and expanded")
	var model_header: Button = headers[1]
	var model_body: Control = model_header.get_parent().get_child(model_header.get_index() + 1)
	_check(not model_body.visible and model_header.text.begins_with("▶"), "Model starts collapsed")
	model_header.pressed.emit()
	_check(model_body.visible and model_header.text.begins_with("▼"), "clicking a section header expands it")
	var fit_button: Button = null
	for child: Node in model_body.find_children("*", "Button", true, false):
		if (child as Button).text == "Fit bounds to content":
			fit_button = child as Button
			break
	_check(fit_button != null, "Model has a fit-bounds button")
	model_header.pressed.emit()
	_check(not model_body.visible, "clicking again collapses it")


func _test_fit_bounds() -> void:
	print("fit bounds")
	_ed.doc.reset()
	_ed.doc.place_cells([Vector3i(10, 0, 10), Vector3i(10, 1, 10)] as Array[Vector3i], Color.RED)
	_ed.doc.resize_bounds(Vector3i(64, 64, 64))
	_ed._fit_bounds_to_content()
	_check(_ed.doc.bounds == Vector3i(11, 4, 11), "fit button resizes to content: " + str(_ed.doc.bounds))
	_check(int(_ed._bound_spins[0].value) == 11, "bounds spin boxes follow a fit")


## Collects the collapsible section header buttons in tree order.
func _section_headers(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	_collect_section_headers(node, out)
	return out


func _collect_section_headers(node: Node, out: Array[Button]) -> void:
	for child in node.get_children():
		if child is Button and (child.text.begins_with("▼") or child.text.begins_with("▶")):
			out.append(child)
		_collect_section_headers(child, out)


func _test_lights_editor() -> void:
	print("lights editor")
	_ed.doc.reset()
	_ed._set_tool(VoxelModelEditor.Tool.LIGHT_PLACE)
	_ed._set_color(Color.RED)
	_click(Vector3(10.5, 0.0, 10.5))
	_check(_ed.doc.lights.size() == 1, "Light tool click adds a light, not a voxel")
	_check(_ed.doc.grid.is_empty(), "light placement leaves voxels untouched")
	var id: int = _ed.selected_light_id
	_check(id >= 0, "new light becomes selected")
	var handle: MeshInstance3D = _ed.light_rig.nodes[id]["handle"]
	var light: OmniLight3D = _ed.light_rig.nodes[id]["light"]
	_check(handle.visible and light.visible, "light renders with a visible handle")
	_check((light.position as Vector3).distance_to(Vector3(10.5, 0.5, 10.5)) < 0.01, "light sits at the clicked cell center")
	_check(_ed.doc.dirty, "light edits mark the document dirty")
	# Inspector edits flow back through the document into the rig.
	_ed._light_energy_spin.value = 2.5
	_check(_ed.doc.lights[id]["energy"] == 2.5 and absf(light.light_energy - 2.5) < 0.01, "inspector energy reaches the OmniLight")
	_ed._light_range_spin.value = 20.0
	_check(absf(_ed.doc.lights[id]["range"] - 20.0) < 0.01, "inspector radius stored")
	_ed.update_point_light(id, {"position": Vector3(12, 2, 12)})
	_check((light.position as Vector3).distance_to(Vector3(12, 2, 12)) < 0.01, "moving updates the scene node")
	# Handle picking + drag on the camera-facing plane.
	_ed._set_tool(VoxelModelEditor.Tool.LIGHT_EDIT)
	var picked: int = _ed.light_rig.pick(_ed.camera.project_ray_origin(_ed.camera.unproject_position(light.position)), _ed.camera.project_ray_normal(_ed.camera.unproject_position(light.position)))
	_check(picked == id, "ray at the handle picks its light")
	_ed._begin_light_drag(id)
	_check(_ed._stroking, "light drag counts as a stroke")
	var drag_plane := Plane(_ed.camera.global_basis.z, Vector3(12, 2, 12))
	var target_screen: Vector2 = _ed.camera.unproject_position(Vector3(14, 2, 12))
	_ed._drag_light_to_screen(target_screen)
	var landed: Vector3 = _ed.doc.lights[id]["position"]
	_check(absf(drag_plane.distance_to(landed)) < 0.01 and (landed - Vector3(12, 2, 12)).length() > 0.5,
			"drag keeps the light on its camera-facing plane while moving it (got %s)" % landed)
	_ed._finish_light_drag()
	_check(_ed.doc.undo() and (light.position as Vector3).distance_to(Vector3(12, 2, 12)) < 0.01, "undo restores the pre-drag position")
	_check(_ed.doc.lights.size() == 1, "undo keeps the light itself")
	# < > cycling through every light, wrapping at both ends.
	_ed.add_point_light(Vector3(20, 1, 20))
	_ed.add_point_light(Vector3(30, 1, 30))
	var ids: Array = _ed.doc.lights.keys()
	ids.sort()
	_check(_ed.cycle_light(1) == ids[0] and _ed.cycle_light(1) == ids[1], "cycling forward walks the lights in order")
	_check(_ed.cycle_light(1) == ids[2], "cycling reaches the last light")
	_check(_ed.cycle_light(1) == ids[0], "cycling wraps around at the end")
	_check(_ed.cycle_light(-1) == ids[ids.size() - 1], "cycling backward wraps to the last light")
	_check(_ed._light_selection_label.text == "Light %d / %d" % [ids[ids.size() - 1], ids.size()], "label shows the current light")
	_ed._select_light(-1)
	_check(_ed.cycle_light(1) == ids[0], "cycling with nothing selected starts at the first light")
	# Delete button removes the current light in one undo step.
	_ed.cycle_light(1)
	var victim: int = _ed.selected_light_id
	_ed._light_delete_button.pressed.emit()
	_check(not _ed.doc.lights.has(victim) and _ed.doc.lights.size() == ids.size() - 1, "Delete button removes the current light")
	_check(_ed.doc.undo() and _ed.doc.lights.has(victim), "button delete is one undo step")
	# Removing through the API removes node + data in one undo step.
	_ed.remove_point_light(id)
	_check(not _ed.doc.lights.has(id) and not _ed.light_rig.nodes.has(id), "delete removes light and handle")
	_check(_ed.doc.undo() and _ed.doc.lights.has(id) and _ed.light_rig.nodes.has(id), "delete is one undo step")
	_ed.doc.reset()
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)


func _test_mesh_and_file() -> void:
	print("mesh / file")
	_ed.doc.reset()
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)
	_click(Vector3(2.5, 0.0, 2.5))
	await process_frame
	await process_frame
	var has_mesh: bool = false
	for key: Vector2i in _ed._chunks:
		for cy: int in _ed._chunks[key]:
			var rec: Dictionary = _ed._chunks[key][cy]
			if rec["mi"] != null and (rec["mi"] as MeshInstance3D).mesh != null \
					and (rec["mi"] as MeshInstance3D).mesh.get_surface_count() > 0:
				has_mesh = true
	_check(has_mesh, "chunk mesh rebuilt after edit")
	_check(_ed.doc.dirty, "document dirty after edit")
	var path := "user://voxel_editor_test.tres"
	_ed._write_file(path)
	_check(not _ed.doc.dirty, "saving clears dirty")
	var inst := VoxelModelInstance.new()
	inst.model = load(path) as VoxelModel
	inst.with_collision = true
	root.add_child(inst)
	await process_frame
	_check(inst.get_node_or_null("Mesh") != null and inst.get_node_or_null("Collision") != null, "VoxelModelInstance builds mesh + collision")
	_ed.doc.reset()
	_ed.doc.place_cells([Vector3i(4, 0, 4)] as Array[Vector3i], Color.RED)
	_ed.doc.add_light({"position": Vector3(4.5, 2.0, 4.5), "color": Color("ffcc88"), "energy": 3.0, "range": 10.0})
	_ed.doc.set_sun({"energy": 0.5})
	_ed._write_file(path)
	# CACHE_MODE_IGNORE: a plain load() would return the resource cached by the
	# first load of this path, missing the lights we just saved.
	var lit := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as VoxelModel
	_check(lit.lights.size() == VoxelModel.LIGHT_STRIDE and absf(lit.sun_energy - 0.5) < 0.01, "saved model packs lights and mood")
	var lit_inst := VoxelModelInstance.new()
	lit_inst.model = lit
	root.add_child(lit_inst)
	await process_frame
	var lights_group: Node = lit_inst.get_node_or_null("Lights")
	_check(lights_group != null and lights_group.get_child_count() == 1, "VoxelModelInstance rebuilds stored lights")
	if lights_group != null and lights_group.get_child_count() > 0:
		var omni: OmniLight3D = lights_group.get_child(0)
		var expected: Vector3 = Vector3(4.5, 2.0, 4.5) * lit.voxel_size
		_check(omni.position.is_equal_approx(expected) and absf(omni.light_energy - 3.0) < 0.01, "rebuilt light matches position and energy")
	_ed.doc.reset()
	_ed._pending_open = true
	_ed._on_file_selected(ProjectSettings.globalize_path(path))
	await process_frame
	_check(_ed.doc.voxel_count() == 1, "open loads the saved model")
	var mesh_after_open: MeshInstance3D = null
	for key: Vector2i in _ed._chunks:
		for cy: int in _ed._chunks[key]:
			var rec: Dictionary = _ed._chunks[key][cy]
			if rec["mi"] != null:
				mesh_after_open = rec["mi"]
				break
		if mesh_after_open != null:
			break
	_check(mesh_after_open != null and mesh_after_open.mesh != null and mesh_after_open.mesh.get_surface_count() > 0,
			"open rebuilds the chunk mesh so voxels are visible")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	await _test_screenshot()


func _test_screenshot() -> void:
	print("screenshot file")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	await process_frame
	_ed._ask_save_screenshot()
	_check(_ed._screenshot_dialog.visible, "Save Screenshot As opens the PNG picker")
	_check(_ed._screenshot_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE, "screenshot picker saves files")
	_check(_ed._screenshot_dialog.current_file == "voxel_editor_test.png", "screenshot name follows the model")
	_check(_ed._screenshot_dialog.current_dir == _ed._default_screenshot_dir(), "screenshot picker defaults to Pictures/Voxdot")
	_check(not _ed._file_dialog.visible, "screenshot does not open the model picker")
	_ed._screenshot_dialog.hide()
	_ed._set_height_lock(true)
	_ed._set_mirror(true, true)
	# Dummy displays ignore Input.warp_mouse; drive hover directly like the
	# screenshot generator and freeze _process so it cannot clear the fixture.
	_ed.set_process(false)
	_ed._hover = {"valid": true, "cell": Vector3i(2, 0, 2), "normal": Vector3i.UP, "face_coord": 0.0}
	_ed._update_ghost()
	_check(_ed._ghost.visible, "screenshot fixture has a placement ghost")
	var result: String = await _ed.save_screenshot("user://voxel_editor_test_shot")
	_check(result == "" or (result.ends_with(".png") and FileAccess.file_exists(result)),
			"screenshot saver appends .png or reports headless cleanly")
	_check(_ed._ui_layer.visible and _ed._grid_mi.visible == _ed.grid_visible
			and _ed._layer_mi.visible == _ed.height_lock and _ed._mirror_x_mi.visible == _ed.doc.mirror_x
			and _ed._mirror_z_mi.visible == _ed.doc.mirror_z and _ed._ghost.visible and not _ed._capturing_screenshot,
			"screenshot restores HUD and overlay visibility")
	_ed.set_process(true)
	if result != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(result))


func _test_standalone() -> void:
	print("standalone behaviour")
	_ed._set_mirror(false, false)
	_ed._set_height_lock(false)
	var dir: String = OS.get_user_data_dir().path_join("cli_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var model_path: String = dir.path_join("m.tres")
	_ed.doc.reset()
	_ed.doc.place_cells([Vector3i(1, 1, 1)] as Array[Vector3i], Color.RED)
	_check(_ed.doc.save_file(model_path) == OK, "fixture saved")
	var got: String = VoxelModelEditor.cli_model_path(PackedStringArray(["--path", ".", "notes.txt", model_path]))
	_check(got == model_path, "cli_model_path finds the .tres, skipping flags and other files")
	_check(VoxelModelEditor.cli_model_path(PackedStringArray(["--flag", "missing.tres", "x.gd"])) == "", "no existing model -> empty")
	_ed.doc.reset()
	_ed._on_files_dropped(PackedStringArray([model_path]))
	_check(_ed.doc.voxel_count() == 1 and _ed.doc.path == model_path, "dropping a file opens it")
	_ed.doc.place_cells([Vector3i(2, 2, 2)] as Array[Vector3i], Color.BLUE)
	_check(root.title.contains("m.tres*") and root.title.contains("Voxdot"), "window title shows file, dirty marker and app name (got '%s')" % root.title)
	_ed._on_files_dropped(PackedStringArray([model_path]))
	_check(_ed.doc.voxel_count() == 2, "dropping onto unsaved work asks first instead of discarding")
	_ed._confirm_dialog.confirmed.emit()
	_check(_ed.doc.voxel_count() == 1, "confirming the prompt then opens the dropped file")
	var dd: String = _ed._default_dir()
	_check(dd.ends_with("Voxdot") and DirAccess.dir_exists_absolute(dd), "default save dir is <Documents>/Voxdot and exists")
	DirAccess.remove_absolute(model_path)
	DirAccess.remove_absolute(dir)
