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


func _test_mesh_and_file() -> void:
	print("mesh / file")
	_ed.doc.reset()
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)
	_click(Vector3(2.5, 0.0, 2.5))
	await process_frame
	await process_frame
	var mesh := _ed._model_mi.mesh as ArrayMesh
	_check(mesh != null and mesh.get_surface_count() == 1, "mesh rebuilt after edit")
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
	_ed._pending_open = true
	_ed._on_file_selected(ProjectSettings.globalize_path(path))
	_check(_ed.doc.voxel_count() == 1, "open loads the saved model")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_standalone() -> void:
	print("standalone behaviour")
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
