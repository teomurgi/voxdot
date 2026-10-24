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
	_test_lights()
	_test_raycast()
	_test_prefabs()
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
	_check(d.resize_bounds(Vector3i(2000, 2, 8)) and d.bounds == Vector3i(1024, 4, 8), "bounds clamp to limits")
	_check(VoxelDocument.new().content_extent() == Vector3i.ZERO, "empty document has no content extent")
	d.place_cells([Vector3i(10, 0, 0)] as Array[Vector3i], Color.WHITE)
	var extent: Vector3i = d.content_extent()
	_check(extent == Vector3i(11, 4, 4), "content extent from voxels: " + str(extent))
	_check(d.resize_bounds(extent) and d.bounds == extent, "fit bounds to content")


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


func _test_lights() -> void:
	print("lights")
	var d := VoxelDocument.new()
	_check(d.lights.is_empty(), "new document has no lights")
	var id: int = d.add_light({"position": Vector3(4, 5, 6), "color": Color("ffcc88"), "energy": 2.0, "range": 12.0})
	_check(id > 0 and d.lights.size() == 1, "add_light returns a positive id")
	var l: Dictionary = d.lights[id]
	_check(l["position"] == Vector3(4, 5, 6) and (l["color"] as Color).is_equal_approx(Color("ffcc88")), "light stores position and color")
	_check(l["energy"] == 2.0 and l["range"] == 12.0 and l["shadows"] == true, "light stores energy, range, shadows")
	_check(d.dirty, "adding a light marks the document dirty")
	_check(d.add_light({"position": Vector3(-1, 0, 0)}) == -1, "out-of-bounds light refused")
	_check(d.update_light(id, {"position": Vector3(7, 8, 9), "energy": 3.0}), "update_light changes properties")
	_check((d.lights[id]["position"] as Vector3) == Vector3(7, 8, 9), "position moved")
	_check(not d.update_light(id, {"position": Vector3(500, 0, 0)}), "moving out of bounds refused")
	# One drag = one undo step even though update_light ran repeatedly.
	d.begin_stroke()
	d.update_light(id, {"position": Vector3(10, 1, 1)})
	d.update_light(id, {"position": Vector3(11, 1, 1)})
	d.end_stroke()
	_check(d.undo(), "light drag is undoable")
	_check((d.lights[id]["position"] as Vector3) == Vector3(7, 8, 9), "undo restores the pre-drag position")
	_check(d.redo() and (d.lights[id]["position"] as Vector3) == Vector3(11, 1, 1), "redo replays the drag")
	var id2: int = d.add_light({"position": Vector3(1, 1, 1)})
	_check(id2 > id, "ids increase")
	_check(d.remove_light(id2) and not d.lights.has(id2), "remove_light deletes")
	d.undo()
	_check(d.lights.has(id2), "undo restores a removed light")
	d.redo()
	# Save/open round-trip keeps every light property and the sun setup.
	var path := "user://voxel_document_lights.tres"
	d.set_sun({"energy": 1.6, "yaw": 120.0, "pitch": -35.0, "color": Color("ffd9a0"), "shadows": false})
	_check(d.dirty, "changing the sun marks the document dirty")
	_check(d.save_file(path) == OK, "save with lights")
	var e := VoxelDocument.new()
	_check(e.load_file(path) == OK and e.lights.size() == d.lights.size(), "open restores lights")
	_check((e.lights[id]["position"] as Vector3) == Vector3(11, 1, 1) and e.lights[id]["energy"] == 3.0, "light properties survive the round-trip")
	_check(is_equal_approx(e.sun_energy, 1.6) and is_equal_approx(e.sun_yaw, 120.0) and is_equal_approx(e.sun_pitch, -35.0),
			"sun energy and angles survive the round-trip")
	_check((e.sun_color as Color).is_equal_approx(Color("ffd9a0")) and e.sun_shadows == false, "sun color and shadows survive the round-trip")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# A model without light data still opens cleanly.
	var legacy := VoxelModel.from_grid({Vector3i(1, 0, 1): Color.RED})
	legacy.lights = PackedFloat32Array()
	_check(e.load_model(legacy) == 0 and e.lights.is_empty(), "legacy model without lights loads")
	_check(is_equal_approx(e.sun_energy, VoxelDocument.DEFAULT_SUN_ENERGY) and is_equal_approx(e.sun_pitch, VoxelDocument.DEFAULT_SUN_PITCH),
			"legacy model gets the default sun")
	_check(e.content_extent() == Vector3i(4, 4, 4), "content extent clamps to the minimum bounds")
	# Bounds shrink refuses when a light would fall outside.
	var id3: int = e.add_light({"position": Vector3(20, 1, 1)})
	_check(e.content_extent() == Vector3i(21, 4, 4), "content extent includes lights: " + str(e.content_extent()))
	_check(not e.resize_bounds(Vector3i(4, 4, 4)), "shrink below a light refused")
	e.remove_light(id3)
	_check(e.content_extent() == Vector3i(4, 4, 4), "content extent after light removal")
	_check(e.resize_bounds(Vector3i(8, 8, 8)), "shrink allowed once lights are gone")


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


## Prefab data layer: placement/transform/undo/IO, conflicts, missing sources,
## relink, unpack, refresh, soft lights and bounds/nesting refusal.
func _test_prefabs() -> void:
	print("prefabs: placement + transforms")
	var dir: String = "/tmp/opencode/voxdot_doc_prefabs"
	_rmrf(dir)
	DirAccess.make_dir_recursive_absolute(dir.path_join("Prefabs"))
	var src_path: String = dir.path_join("Prefabs/tree.tres")
	var source: VoxelModel = _prefab_source(src_path)

	var d := VoxelDocument.new()
	var placed: Dictionary = d.place_prefab(source, "Prefabs/tree.tres", "tree",
		Vector3(1.5, 0, 1.5), Vector3i(10, 0, 10), 0)
	_check(placed["ok"], "place at (10,0,10): " + str(placed))
	var id: int = int(placed["instance_id"])
	_check(d.prefab_cell_count() == 10 and d.prefab_light_count() == 1, "10 cells + 1 light")
	_check(d.prefab_at(Vector3i(10, 0, 10)) == id and d.prefab_at(Vector3i(11, 0, 11)) == id, "anchor + far cell owned")
	_check(d.prefab_world_lights(id)[0]["position"] == Vector3(9.5, 2, 9.5),
		"instance light transformed: " + str(d.prefab_world_lights(id)))

	var overlap: Dictionary = d.place_prefab(source, "Prefabs/tree.tres", "tree",
		Vector3(1.5, 0, 1.5), Vector3i(11, 0, 11), 0)
	_check(not overlap["ok"] and overlap["state"] == "conflict", "overlap refused: " + str(overlap))
	var bad_pivot: Dictionary = d.place_prefab(source, "Prefabs/tree.tres", "tree",
		Vector3(1.25, 0, 1.5), Vector3i(0, 0, 0), 0)
	_check(not bad_pivot["ok"] and bad_pivot["state"] == "invalid", "quarter-cell pivot refused")

	d.place_cells([Vector3i(0, 0, 0)] as Array[Vector3i], Color.GREEN)
	d.erase_cells([Vector3i(0, 0, 0)] as Array[Vector3i])
	_check(d.voxel_count() == 0 and d.prefab_at(Vector3i(10, 0, 10)) == id,
		"local edits leave prefab cells intact")

	var move: Dictionary = d.move_prefab(id, Vector3i(0, 0, 0))
	_check(not move["ok"] and d.prefab_instance(id).anchor == Vector3i(10, 0, 10),
		"move out of bounds refused, anchor unchanged")
	var rot: Dictionary = d.rotate_prefab(id, 1)
	_check(rot["ok"] and d.prefab_instance(id).yaw_quarters == 1, "rotate +90°")
	_check(d.prefab_at(Vector3i(10, 0, 9)) == id and d.prefab_at(Vector3i(9, 0, 11)) == id,
		"rotated cells land on the expected grid")
	_check(d.prefab_world_lights(id)[0]["position"] == Vector3(9.5, 2, 10.5),
		"rotated light: " + str(d.prefab_world_lights(id)))

	var dup: Dictionary = d.duplicate_prefab(id, Vector3i(20, 0, 20))
	_check(dup["ok"] and int(dup["instance_id"]) != id, "duplicate")
	_check(d.prefab_instances.size() == 2 and d.prefab_cell_count() == 20 and d.prefab_light_count() == 2,
		"duplicate doubles cells + lights")
	var dup_id: int = int(dup["instance_id"])
	_check(d.delete_prefab(dup_id)["ok"] and d.prefab_instances.size() == 1, "delete")
	d.undo()
	_check(d.prefab_instances.size() == 2, "undo delete restores the instance")
	d.redo()
	_check(d.prefab_instances.size() == 1, "redo deletes again")

	print("prefabs: save / load")
	var parent_path: String = dir.path_join("castle.tres")
	_check(d.save_file(parent_path) == OK, "save parent")
	var text: String = FileAccess.get_file_as_string(parent_path)
	_check(text.contains("source_path = \"Prefabs/tree.tres\""), "relative fallback saved")
	_check(text.contains("ExtResource"), "native external reference saved")
	var d2 := VoxelDocument.new()
	_check(d2.load_file(parent_path) == OK, "load parent")
	_check(d2.prefab_instances.size() == 1 and d2.prefab_instances[0].source != null, "source resolved")
	_check(d2.prefab_cell_count() == 10 and d2.prefab_at(Vector3i(10, 0, 9)) == d2.prefab_instances[0].instance_id,
		"rotated cells composed after load")
	_check(d2.prefab_light_count() == 1 and not d2.dirty, "light after load, document clean")

	print("prefabs: missing source + unresolved save")
	var hidden: String = src_path + ".hidden"
	DirAccess.rename_absolute(src_path, hidden)
	var d3 := VoxelDocument.new()
	_check(d3.load_file(parent_path) == OK, "load parent with missing source")
	var missing_id: int = d3.prefab_instances[0].instance_id
	_check(d3.prefab_instances[0].source == null and d3.prefab_status(missing_id)["state"] == "missing",
		"missing instance kept with missing status")
	_check(d3.prefab_cell_count() == 0 and d3.prefab_bounds(missing_id).size.x > 0.0,
		"no solid cells, placeholder bounds from the snapshot")
	_check(d3.to_model().has_unresolved_prefabs() and int(d3.to_model().prefab_summary()["unresolved"]) == 1,
		"runtime summary sees the unresolved instance")
	var saved_missing: String = dir.path_join("castle_missing.tres")
	_check(d3.save_file(saved_missing) == OK, "save with a missing source")
	var d4 := VoxelDocument.new()
	_check(d4.load_file(saved_missing) == OK and d4.prefab_instances.size() == 1
		and d4.prefab_instances[0].source == null, "unresolved instance survives save + reload")
	DirAccess.rename_absolute(hidden, src_path)

	print("prefabs: relink + unpack")
	var d5 := VoxelDocument.new()
	d5.load_file(parent_path)
	var mid: int = d5.prefab_instances[0].instance_id
	var rel: Dictionary = d5.relink_prefab(mid, ResourceLoader.load(src_path), src_path, "tree")
	_check(rel["ok"] and d5.prefab_cell_count() == 10, "relink: " + str(rel))

	var d6 := VoxelDocument.new()
	d6.load_file(parent_path)
	var uid: int = d6.prefab_instances[0].instance_id
	var unpack: Dictionary = d6.unpack_prefab(uid)
	_check(unpack["ok"], "unpack: " + str(unpack))
	_check(d6.prefab_instances.is_empty() and d6.prefab_cell_count() == 0, "instance removed")
	_check(d6.voxel_count() == 10 and d6.lights.size() == 1, "voxels + light written")
	_check(d6.prefab_at(Vector3i(10, 0, 9)) == 0, "ownership cleared")
	d6.undo()
	_check(d6.voxel_count() == 0 and d6.lights.is_empty()
		and d6.prefab_instances.size() == 1 and d6.prefab_cell_count() == 10,
		"undo restores the instance atomically")
	d6.redo()
	_check(d6.voxel_count() == 10 and d6.lights.size() == 1 and d6.prefab_instances.is_empty(),
		"redo unpacks again")

	# The parent's hard 32-light limit applies to unpack, not to linked lights.
	var dlimit := VoxelDocument.new()
	for i in 32:
		dlimit.add_light({"position": Vector3(0.5 + (i % 8), 0.5, 0.5 + (i / 8))})
	var lim_place: Dictionary = dlimit.place_prefab(source, "Prefabs/tree.tres", "tree",
		Vector3(1.5, 0, 1.5), Vector3i(12, 0, 12), 0)
	_check(lim_place["ok"], "linked lights do not count against the parent hard limit")
	var lim_id: int = int(lim_place["instance_id"])
	var lim_unpack: Dictionary = dlimit.unpack_prefab(lim_id)
	_check(not lim_unpack["ok"] and dlimit.prefab_instance(lim_id) != null
		and dlimit.voxel_count() == 0, "unpack refused atomically at 32 parent lights")

	print("prefabs: refresh + budget + bounds + nesting")
	var src2 := VoxelModel.from_grid({Vector3i(0, 0, 0): Color.YELLOW})
	src2.bounds = Vector3i(16, 16, 16)
	_check(ResourceSaver.save(src2, src_path) == OK, "source edited on disk")
	var d7 := VoxelDocument.new()
	d7.load_file(parent_path)
	_check(d7.prefab_cell_count() == 1, "fresh load sees the edited source")
	var refresh: Dictionary = d7.refresh_prefabs()
	_check(refresh["reloaded"] == 1 and d7.prefab_cell_count() == 1, "refresh reloads from disk: " + str(refresh))
	_check(not d7.dirty, "refresh does not dirty the document")

	source = _prefab_source(src_path)
	var d8 := VoxelDocument.new()
	d8.prefab_light_budget = 0
	var budget: Dictionary = d8.place_prefab(source, "Prefabs/tree.tres", "tree",
		Vector3(1.5, 0, 1.5), Vector3i(2, 0, 2), 0)
	_check(not budget["ok"] and budget["state"] == "budget", "soft budget refuses: " + str(budget))
	var budget_ok: Dictionary = d8.place_prefab(source, "Prefabs/tree.tres", "tree",
		Vector3(1.5, 0, 1.5), Vector3i(2, 0, 2), 0, true)
	_check(budget_ok["ok"] and d8.prefab_light_budget_exceeded(), "budget override places + reports over budget")

	var d9 := VoxelDocument.new()
	d9.place_prefab(source, "Prefabs/tree.tres", "tree", Vector3(1.5, 0, 1.5), Vector3i(30, 0, 30), 0)
	_check(not d9.resize_bounds(Vector3i(8, 8, 8)), "resize refuses to clip a prefab")
	_check(d9.content_extent() == Vector3i(32, 4, 32), "content extent includes prefab cells: " + str(d9.content_extent()))
	_check(d9.resize_bounds(d9.content_extent()) and d9.bounds == Vector3i(32, 4, 32), "fit bounds to prefab content")

	var nested := d9.to_model()
	var d10 := VoxelDocument.new()
	var nested_res: Dictionary = d10.place_prefab(nested, "nested.tres", "nested",
		Vector3.ZERO, Vector3i(1, 0, 1), 0)
	_check(not nested_res["ok"] and nested_res["state"] == "incompatible", "nesting refused: " + str(nested_res))

	_check(VoxelDocument.relative_path("/a/b/c", "/a/d/e.tres") == "../../d/e.tres", "relative_path")
	_check(VoxelDocument.relative_path("/a/b", "/x/y") == "/x/y", "relative_path without a shared root")
	_rmrf(dir)


## 3x3 floor of red voxels, one blue voxel above the centre, and one light.
func _prefab_source(path: String) -> VoxelModel:
	var grid: Dictionary = {}
	for x in 3:
		for z in 3:
			grid[Vector3i(x, 0, z)] = Color.RED
	grid[Vector3i(1, 1, 1)] = Color.BLUE
	var m := VoxelModel.from_grid(grid)
	m.bounds = Vector3i(16, 16, 16)
	m.lights = PackedFloat32Array([1, 1.0, 2.0, 1.0, 1.0, 0.8, 0.2, 1.5, 6.0, 1.0])
	_check(ResourceSaver.save(m, path) == OK, "prefab source saved")
	return m


func _rmrf(p: String) -> void:
	var d := DirAccess.open(p)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	for sub in d.get_directories():
		_rmrf(p.path_join(sub))
	DirAccess.remove_absolute(p)
