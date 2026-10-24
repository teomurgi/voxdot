extends SceneTree

## Headless coverage for VoxelPrefabCatalog: library discovery, stable asset
## IDs, manifest pivots, metadata refresh, validation and thumbnails.
## Run: godot --headless --path . -s tests/voxel_prefab_catalog_test.gd

var _fails: int = 0
var _dir: String = "/tmp/opencode/voxdot_catalog_test"


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok   ", label)
	else:
		print("  FAIL ", label)
		_fails += 1


func _initialize() -> void:
	_run()


func _run() -> void:
	_rmrf(_dir)
	DirAccess.make_dir_recursive_absolute(_dir.path_join("Prefabs/sub"))
	var user_dir: String = _dir.path_join("UserPrefabs")
	DirAccess.make_dir_recursive_absolute(user_dir)

	var tree := VoxelModel.from_grid({
		Vector3i(0, 0, 0): Color.RED, Vector3i(1, 0, 0): Color.RED,
		Vector3i(0, 0, 1): Color.RED, Vector3i(1, 0, 1): Color.RED,
		Vector3i(0, 1, 0): Color.BLUE,
	})
	tree.bounds = Vector3i(16, 16, 16)
	tree.lights = PackedFloat32Array([1, 0.5, 2.0, 0.5, 1, 1, 1, 1, 4, 1])
	var tree_path: String = _dir.path_join("Prefabs/sub/tree.tres")
	_check(ResourceSaver.save(tree, tree_path) == OK, "tree saved")

	var lamp := VoxelModel.new()
	lamp.bounds = Vector3i(8, 8, 8)
	lamp.lights = PackedFloat32Array([1, 2.0, 3.0, 2.0, 1, 1, 0, 1, 5, 1])
	var lamp_path: String = _dir.path_join("Prefabs/lamp.tres")
	_check(ResourceSaver.save(lamp, lamp_path) == OK, "light-only lamp saved")

	var nested := VoxelModel.from_grid({Vector3i(0, 0, 0): Color.GREEN})
	var inst := VoxelPrefabInstance.new()
	inst.instance_id = 1
	inst.source = tree
	inst.source_path = "sub/tree.tres"
	inst.source_bounds = VoxelPrefabInstance.occupied_bounds(tree)
	nested.prefab_instances = [inst]
	var nested_path: String = _dir.path_join("Prefabs/nested.tres")
	_check(ResourceSaver.save(nested, nested_path) == OK, "nested source saved")

	var user_asset := VoxelModel.from_grid({Vector3i(0, 0, 0): Color.MAGENTA})
	user_asset.bounds = Vector3i(8, 8, 8)
	var user_path: String = user_dir.path_join("user_rock.tres")
	_check(ResourceSaver.save(user_asset, user_path) == OK, "user asset saved")

	print("catalogue scan")
	var cat := _catalog()
	var summary: Dictionary = cat.scan(_dir)
	_check(int(summary["assets"]) >= 4, "scanned assets: " + str(summary))
	var tree_a: Dictionary = cat.asset_at(tree_path)
	var lamp_a: Dictionary = cat.asset_at(lamp_path)
	var nested_a: Dictionary = cat.asset_at(nested_path)
	var user_a: Dictionary = cat.asset_at(user_path)
	_check(not tree_a.is_empty() and tree_a["valid"], "tree valid")
	_check(tree_a["cells"] == 5 and tree_a["lights"] == 1, "tree cell + light counts")
	_check(tree_a["pivot"] == Vector3(1, 0, 1), "tree default pivot: " + str(tree_a["pivot"]))
	_check(str(tree_a["asset_id"]).begins_with("prj_"), "project ID prefix")
	_check(str(user_a["asset_id"]).begins_with("usr_") and user_a["valid"], "user ID prefix + valid")
	_check(user_a["library"] == "user", "user library tagged")
	_check(lamp_a["valid"] and lamp_a["pivot"] == Vector3(2, 3, 2), "light-only pivot: " + str(lamp_a["pivot"]))
	_check(not nested_a["valid"] and nested_a["has_prefabs"], "nested source invalid: " + str(nested_a["reason"]))
	_check(FileAccess.file_exists(_dir.path_join("Prefabs/.voxdot/catalogue.cfg")), "project manifest written")
	_check(FileAccess.file_exists(user_dir.path_join(".voxdot/catalogue.cfg")), "user manifest written")

	print("stable IDs + pivots")
	var id: String = str(tree_a["asset_id"])
	var cat2 := _catalog()
	cat2.scan(_dir)
	var tree_b: Dictionary = cat2.asset_at(tree_path)
	_check(tree_b["asset_id"] == id, "ID stable across scans")

	var set: Dictionary = cat2.set_pivot(id, Vector3(1.0, 0.5, 0.5))
	_check(set["pivot"] == Vector3(1.0, 0.5, 0.5), "pivot set")
	var cat3 := _catalog()
	cat3.scan(_dir)
	var tree_c: Dictionary = cat3.asset_at(tree_path)
	_check(tree_c["pivot"] == Vector3(1.0, 0.5, 0.5), "pivot persists: " + str(tree_c["pivot"]))
	_check(tree_c["asset_id"] == id, "ID persists")
	_check(cat3.set_pivot(id, Vector3(1.25, 0, 0)).has("pivot_error"), "quarter-cell pivot refused")

	var thumb_before: String = cat3.thumbnail_path(tree_c)
	var reset: Dictionary = cat3.reset_pivot(id)
	_check(reset["pivot"] == Vector3(1, 0, 1), "reset pivot")
	_check(cat3.thumbnail_path(reset) != thumb_before, "thumbnail key changes with pivot")
	_check(cat3.thumbnail_path(reset).begins_with("user://prefab_thumbs/"), "thumbnails live under user://")

	print("metadata refresh")
	var grown := VoxelModel.from_grid({
		Vector3i(0, 0, 0): Color.RED, Vector3i(1, 0, 0): Color.RED,
		Vector3i(0, 0, 1): Color.RED, Vector3i(1, 0, 1): Color.RED,
		Vector3i(0, 1, 0): Color.BLUE, Vector3i(3, 0, 3): Color.GREEN,
	})
	grown.bounds = Vector3i(16, 16, 16)
	_check(ResourceSaver.save(grown, tree_path) == OK, "tree grown on disk")
	var cat4 := _catalog()
	cat4.scan(_dir)
	var tree_d: Dictionary = cat4.asset_at(tree_path)
	_check(tree_d["cells"] == 6, "metadata refreshed after mtime change")
	_check(tree_d["pivot"] == Vector3(1, 0, 1), "pivot stable after growth")
	var loaded: VoxelModel = cat4.load_asset(id)
	_check(loaded != null and loaded.voxel_count() == 6, "load_asset")
	var refreshed: Dictionary = cat4.refresh_asset(id)
	_check(refreshed["cells"] == 6 and refreshed["asset_id"] == id, "refresh_asset keeps ID")

	print("invalid files do not break the scan")
	var bad_path: String = _dir.path_join("Prefabs/bad.tres")
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	f.store_string("not a resource")
	f.close()
	var cat5 := _catalog()
	var s5: Dictionary = cat5.scan(_dir)
	_check(cat5.asset_at(bad_path)["valid"] == false, "invalid file listed as invalid: " + str(s5))
	_check(int(s5["invalid"]) >= 2, "invalid count includes bad + nested")

	print("library filters")
	_check(cat5.asset_count() == int(s5["assets"]), "asset_count matches summary")
	var user_count: int = 0
	for a: Dictionary in cat5.assets():
		if a["library"] == "user":
			user_count += 1
	_check(user_count == 1, "exactly one user asset")
	_check(cat5.find_by_asset_id(id)["path"] == tree_path, "find_by_asset_id")

	print("overlapping libraries are deduplicated")
	var cat6 := VoxelPrefabCatalog.new()
	cat6.user_library_override = _dir.path_join("Prefabs")
	var s6: Dictionary = cat6.scan(_dir)
	_check(int(s6["assets"]) == 4, "no duplicates when user + project library are the same")

	print("voxel_prefab_catalog_test: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	_rmrf(_dir)
	quit(1 if _fails > 0 else 0)


func _catalog() -> VoxelPrefabCatalog:
	var c := VoxelPrefabCatalog.new()
	c.user_library_override = _dir.path_join("UserPrefabs")
	return c


func _rmrf(p: String) -> void:
	var d := DirAccess.open(p)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	for sub in d.get_directories():
		_rmrf(p.path_join(sub))
	DirAccess.remove_absolute(p)
