extends SceneTree

## Manual scale benchmark for the prefab composition (not part of CI).
## Run: godot --headless --path . -s tools/bench_prefabs.gd
##
## Builds a ~2k-cell source with two lights, places 500 non-overlapping
## instances (~1M composed cells), then times validation, a move, a full
## rebuild and a source refresh. Numbers are machine-dependent; use them to
## catch accidental O(scene) work, not as hard limits.

const INSTANCES: int = 500
const SOURCE_X: int = 10
const SOURCE_Y: int = 20
const SOURCE_Z: int = 10
const SPACING: int = 12


func _initialize() -> void:
	var dir: String = OS.get_user_data_dir().path_join("bench_prefabs")
	_rmrf(dir)
	DirAccess.make_dir_recursive_absolute(dir)

	print("building source (%d cells)..." % (SOURCE_X * SOURCE_Y * SOURCE_Z))
	var grid: Dictionary = {}
	for x in SOURCE_X:
		for y in SOURCE_Y:
			for z in SOURCE_Z:
				grid[Vector3i(x, y, z)] = Color.from_hsv(float(x + z) / 20.0, 0.5, 0.8)
	var source := VoxelModel.from_grid(grid)
	source.bounds = Vector3i(32, 32, 32)
	source.lights = PackedFloat32Array([
		1, 1.0, 10.0, 1.0, 1.0, 0.9, 0.7, 2.0, 8.0, 1.0,
		2, 8.0, 10.0, 8.0, 0.7, 0.8, 1.0, 2.0, 8.0, 1.0,
	])
	var src_path: String = dir.path_join("source.tres")
	_timed("save source", func() -> void:
		ResourceSaver.save(source, src_path))

	var doc := VoxelDocument.new()
	doc.resize_bounds(Vector3i(512, 64, 512))
	doc.prefab_light_budget = 4096
	var cols: int = int(ceil(sqrt(float(INSTANCES))))
	var pivot := VoxelPrefabInstance.snap_pivot(Vector3(
		SOURCE_X * 0.5, 0.0, SOURCE_Z * 0.5))
	var t0: int = Time.get_ticks_msec()
	for i in INSTANCES:
		var anchor := Vector3i((i % cols) * SPACING + 6, 0, (i / cols) * SPACING + 6)
		var res: Dictionary = doc.place_prefab(source, src_path, "bench", pivot, anchor, 0)
		if not res.get("ok", false):
			push_error("placement %d failed: %s" % [i, res])
			break
	var place_ms: int = Time.get_ticks_msec() - t0
	print("placed %d instances in %d ms (%.2f ms/instance)" % [
		doc.prefab_instances.size(), place_ms, float(place_ms) / maxf(1.0, float(INSTANCES))])
	print("composed: %d cells, %d lights" % [doc.prefab_cell_count(), doc.prefab_light_count()])

	var id: int = doc.prefab_instances[INSTANCES / 2].instance_id
	var inst: VoxelPrefabInstance = doc.prefab_instance(id)
	var move_target: Vector3i = inst.anchor + Vector3i(0, 1, 0)
	_timed("validate + move one instance", func() -> void:
		var res: Dictionary = doc.move_prefab(id, move_target)
		if not res.get("ok", false):
			push_error("move failed: %s" % [res]))
	_timed("validate + rotate one instance", func() -> void:
		var res: Dictionary = doc.rotate_prefab(id, 1)
		if not res.get("ok", false):
			push_error("rotate failed: %s" % [res]))
	_timed("composed raycast (down through 1M)", func() -> void:
		var hit: Dictionary = VoxelRaycast.cast_composed(doc.grid,
			doc.prefab_composition, doc.bounds, Vector3(8.5, 40.0, 8.5), Vector3.DOWN)
		if not hit.get("hit", false):
			push_error("bench raycast missed"))
	_timed("rebuild one 64x64 chunk mesh", func() -> void:
		var key: Vector2i = doc.prefab_composition.column_keys()[0]
		VoxelMeshBuilder.build_mesh(doc.prefab_composition.colors_in_column(key), 1.0))
	_timed("delete + undo one instance", func() -> void:
		if not doc.delete_prefab(id).get("ok", false):
			push_error("delete failed")
		if not doc.undo():
			push_error("undo failed"))

	_timed("full composition rebuild", func() -> void:
		doc.prefab_composition.rebuild(doc.prefab_instances, doc.grid, doc.bounds))
	_timed("refresh sources from disk", func() -> void:
		doc.refresh_prefabs())
	var parent_path: String = dir.path_join("parent.tres")
	_timed("save 500-instance parent", func() -> void:
		if doc.save_file(parent_path) != OK:
			push_error("save failed"))
	_timed("open 500-instance parent", func() -> void:
		var opened := VoxelDocument.new()
		if opened.load_file(parent_path) != OK:
			push_error("load failed")
		if opened.prefab_cell_count() != doc.prefab_cell_count():
			push_error("load composed a different cell count"))

	print("status: ", doc.prefab_status_counts())
	print("static memory: %.1f MiB" % (float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0))
	_rmrf(dir)
	quit(0)


func _timed(label: String, fn: Callable) -> void:
	var t0: int = Time.get_ticks_msec()
	fn.call()
	print("%-34s %5d ms" % [label + ":", Time.get_ticks_msec() - t0])


func _rmrf(p: String) -> void:
	var d := DirAccess.open(p)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	for sub in d.get_directories():
		_rmrf(p.path_join(sub))
	DirAccess.remove_absolute(p)
