extends SceneTree

## Headless coverage for the voxel editor's data layer: VoxelDocument edits,
## undo/redo, mirroring, flood fill, bounds, VoxelModel round-trip, and
## VoxelRaycast. Run: godot --headless --path godot -s tests/voxel_document_test.gd

var _fails: int = 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok   ", label)
	else:
		print("  FAIL ", label)
		_fails += 1


func _initialize() -> void:
	_test_edit_undo()
	_test_mirror()
	_test_flood_box_bounds()
	_test_model_roundtrip()
	_test_raycast()
	print("voxel_document_test: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	quit(1 if _fails > 0 else 0)


func _test_edit_undo() -> void:
	print("edit / undo")
	var d := VoxelDocument.new()
	var red := Color.RED
	var blue := Color.BLUE
	d.place_cells([Vector3i(1, 0, 1), Vector3i(2, 0, 1)] as Array[Vector3i], red)
	_check(d.voxel_count() == 2, "place two voxels")
	d.paint_cells([Vector3i(1, 0, 1), Vector3i(5, 5, 5)] as Array[Vector3i], blue)
	_check(d.grid[Vector3i(1, 0, 1)] == blue, "paint recolors existing")
	_check(not d.grid.has(Vector3i(5, 5, 5)), "paint does not create voxels")
	d.erase_cells([Vector3i(2, 0, 1)] as Array[Vector3i])
	_check(d.voxel_count() == 1, "erase removes")
	d.undo()
	_check(d.grid.get(Vector3i(2, 0, 1)) == red, "undo erase restores color")
	d.undo()
	_check(d.grid[Vector3i(1, 0, 1)] == red, "undo paint restores old color")
	d.undo()
	_check(d.voxel_count() == 0, "undo place empties")
	_check(not d.can_undo(), "history exhausted")
	d.redo()
	d.redo()
	_check(d.voxel_count() == 2 and d.grid[Vector3i(1, 0, 1)] == blue, "redo replays")
	d.place_cells([Vector3i(9, 9, 9)] as Array[Vector3i], red)
	_check(not d.can_redo(), "new edit clears redo")

	# A stroke is one undo step and net-zero strokes record nothing.
	var s := VoxelDocument.new()
	s.begin_stroke()
	s.place_cells([Vector3i(0, 0, 0)] as Array[Vector3i], red)
	s.place_cells([Vector3i(1, 0, 0)] as Array[Vector3i], red)
	s.end_stroke()
	s.undo()
	_check(s.voxel_count() == 0 and not s.can_undo(), "stroke undoes as one step")
	s.begin_stroke()
	s.place_cells([Vector3i(0, 0, 0)] as Array[Vector3i], red)
	s.erase_cells([Vector3i(0, 0, 0)] as Array[Vector3i])
	s.end_stroke()
	_check(not s.can_undo(), "net-zero stroke records no history")
	s.place_cells([Vector3i(-1, 0, 0), Vector3i(32, 0, 0)] as Array[Vector3i], red)
	_check(s.voxel_count() == 0, "out-of-bounds writes ignored")


func _test_mirror() -> void:
	print("mirror")
	var d := VoxelDocument.new()
	d.set_mirror(true, true)
	d.place_cells([Vector3i(2, 1, 3)] as Array[Vector3i], Color.GREEN)
	_check(d.voxel_count() == 4, "x+z mirror yields 4 voxels")
	_check(d.grid.has(Vector3i(29, 1, 3)) and d.grid.has(Vector3i(2, 1, 28)) and d.grid.has(Vector3i(29, 1, 28)), "mirror positions")
	d.undo()
	_check(d.voxel_count() == 0, "mirrored edit is one undo step")


func _test_flood_box_bounds() -> void:
	print("flood / box / bounds")
	var d := VoxelDocument.new()
	d.place_cells(VoxelDocument.box_cells(Vector3i(0, 0, 0), Vector3i(3, 3, 3)), Color.WHITE)
	_check(d.voxel_count() == 64, "box_cells 4x4x4")
	d.place_cells([Vector3i(10, 0, 0)] as Array[Vector3i], Color.WHITE)
	_check(d.flood_cells(Vector3i(0, 0, 0)).size() == 64, "flood stays connected")
	d.paint_cells(d.flood_cells(Vector3i(0, 0, 0)), Color.RED)
	_check(d.grid[Vector3i(10, 0, 0)] == Color.WHITE, "flood leaves disconnected voxel")
	_check(not d.resize_bounds(Vector3i(8, 8, 8)), "shrink below voxel refused")
	_check(d.bounds == Vector3i(32, 32, 32), "bounds unchanged after refusal")
	d.erase_cells([Vector3i(10, 0, 0)] as Array[Vector3i])
	_check(d.resize_bounds(Vector3i(8, 8, 8)) and d.bounds == Vector3i(8, 8, 8), "shrink allowed when empty")
	_check(d.resize_bounds(Vector3i(500, 2, 8)) and d.bounds == Vector3i(64, 4, 8), "bounds clamp to limits")


func _test_model_roundtrip() -> void:
	print("model round-trip")
	var d := VoxelDocument.new()
	d.set_voxel_size(0.125)
	d.add_swatch(Color("123456"))
	d.place_cells(VoxelDocument.box_cells(Vector3i(1, 0, 1), Vector3i(3, 2, 3)), Color.ORANGE)
	d.place_cells([Vector3i(2, 3, 2)] as Array[Vector3i], Color.CYAN)
	var path := "user://voxel_document_test.tres"
	_check(d.save_file(path) == OK, "save_file")
	_check(not d.dirty and d.path == path, "save clears dirty")
	var e := VoxelDocument.new()
	_check(e.load_file(path) == OK, "load_file")
	_check(e.grid == d.grid, "grid identical after reload")
	_check(is_equal_approx(e.voxel_size, 0.125) and e.bounds == d.bounds, "metadata preserved")
	_check(e.swatches.has(Color("123456")), "swatches preserved")
	_check(not e.can_undo() and not e.dirty, "load resets history")
	var m := d.to_model()
	_check(m.voxel_count() == d.voxel_count() and m.palette.size() == 2, "palette deduplicated")
	_check(m.build_mesh().get_surface_count() == 1, "model builds a mesh")
	_check(e.load_file("user://does_not_exist.tres") == ERR_FILE_NOT_FOUND, "missing file reported")
	# Out-of-range content from foreign models grows bounds, drops the rest.
	var far := VoxelModel.from_grid({Vector3i(40, 0, 0): Color.RED, Vector3i(-1, 0, 0): Color.RED})
	far.bounds = Vector3i(8, 8, 8)
	var dropped: int = e.load_model(far)
	_check(dropped == 1 and e.bounds.x == 41 and e.grid.has(Vector3i(40, 0, 0)), "load grows bounds, drops negatives")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Standalone app: models live outside the project, addressed by absolute path.
	var abs_dir: String = OS.get_user_data_dir().path_join("abs_test")
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var abs_path: String = abs_dir.path_join("outside.tres")
	_check(d.save_file(abs_path) == OK, "save to absolute path outside the project")
	var f := VoxelDocument.new()
	_check(f.load_file(abs_path) == OK and f.grid == d.grid, "load from absolute path outside the project")
	DirAccess.remove_absolute(abs_path)
	DirAccess.remove_absolute(abs_dir)


func _test_raycast() -> void:
	print("raycast")
	var b := Vector3i(8, 8, 8)
	var grid: Dictionary = {Vector3i(3, 0, 3): Color.RED, Vector3i(3, 1, 3): Color.RED}
	var r: Dictionary = VoxelRaycast.cast(grid, b, Vector3(3.5, 10.0, 3.5), Vector3.DOWN)
	_check(r["hit"] and r["pos"] == Vector3i(3, 1, 3) and r["normal"] == Vector3i.UP, "straight down hits top face")
	r = VoxelRaycast.cast(grid, b, Vector3(-4.0, 0.5, 3.5), Vector3.RIGHT)
	_check(r["hit"] and r["pos"] == Vector3i(3, 0, 3) and r["normal"] == Vector3i(-1, 0, 0), "side hit reports -X face")
	r = VoxelRaycast.cast(grid, b, Vector3(5.5, 10.0, 5.5), Vector3.DOWN)
	_check(not r["hit"] and r["floor"] and r["pos"] == Vector3i(5, 0, 5), "empty column reaches floor cell")
	r = VoxelRaycast.cast(grid, b, Vector3(20.5, 10.0, 5.5), Vector3.DOWN)
	_check(not r["hit"] and not r["floor"], "ray outside bounds misses")
	r = VoxelRaycast.cast(grid, b, Vector3(-3.0, 5.0, -3.0), Vector3(1, -1, 1).normalized() * 1.0)
	_check(r["floor"] or r["hit"], "diagonal ray from outside reaches floor or voxel")
	r = VoxelRaycast.cast(grid, b, Vector3(3.5, 0.5, 3.5), Vector3.UP)
	_check(r["hit"] and r["pos"] == Vector3i(3, 0, 3), "origin inside a voxel hits it")
