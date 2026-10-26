extends SceneTree

## Run with -- <absolute game asset directory> [reopen].
var failures: int = 0

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		quit(2)
		return
	var folder: String = args[0]
	var path: String = folder.path_join("world.tres")
	if args.size() > 1:
		var reopened := VoxelDocument.new()
		check(reopened.load_file(path) == OK, "open game-owned world in Voxdot")
		check(reopened.prefab_instances[0].source != null, "relative native prefab resolves")
		check(str(reopened.character_slots["helmet"]).begins_with(folder), "slot resolves within moved game directory")
		reopened.place_cells([Vector3i(2, 0, 0)] as Array[Vector3i], Color.GREEN)
		check(reopened.save_file(path) == OK, "edit/save game asset in place")
		var preview := VoxelCharacterRig.new()
		root.add_child(preview)
		check(preview.apply_model_loadout(VoxelModel.load_with_prefabs(path)).is_empty(), "preview consumes portable loadout")
		check(preview.slot_models.size() == 4, "all preview slots loaded")
		preview.free()
	else:
		DirAccess.make_dir_recursive_absolute(folder.path_join("Prefabs"))
		DirAccess.make_dir_recursive_absolute(folder.path_join("Parts"))
		var part := VoxelModel.from_grid({Vector3i(0, 5, 0): Color.GOLD}, 0.125)
		check(part.save_portable(folder.path_join("Parts/part.tres")) == OK, "save part directly into game")
		var tree := VoxelModel.from_grid({Vector3i.ZERO: Color.ORANGE}, 0.125)
		tree.lights = PackedFloat32Array([1, 0, 2, 0, 1, 0.5, 0.1, 2, 8, 0])
		check(tree.save_portable(folder.path_join("Prefabs/tree.tres")) == OK, "save prefab directly into game")
		tree = load(folder.path_join("Prefabs/tree.tres")) as VoxelModel
		var doc := VoxelDocument.new()
		doc.voxel_size = 0.25
		doc.place_cells([Vector3i.ZERO] as Array[Vector3i], Color.RED, VoxelMaterial.Kind.STONE)
		check(doc.place_prefab(tree, tree.resource_path, "tree", Vector3.ZERO, Vector3i(4, 0, 4), 0).get("ok", false), "place prefab")
		for slot: String in ["helmet", "chest", "main_hand", "off_hand"]:
			doc.set_character_slot(slot, folder.path_join("Parts/part.tres"))
		doc.add_frame_from_current()
		doc.place_cells([Vector3i(1, 0, 0)] as Array[Vector3i], Color.BLUE)
		doc.set_frame_time(0, 0.2)
		doc.set_frame_time(1, 0.3)
		doc.anim_mode = 1
		doc.set_character_style({"preset": 2, "chest": 3, "helmet": 2, "main_hand": 3, "off_hand": 0})
		check(doc.save_file(path) == OK, "save world directly into game")
		# Save As must rebase both prefab and character paths.
		DirAccess.make_dir_recursive_absolute(folder.path_join("variants"))
		check(doc.save_file(folder.path_join("variants/alternate.tres")) == OK, "Save As")
		var alternate := VoxelModel.load_with_prefabs(folder.path_join("variants/alternate.tres"))
		check(alternate.character_slots["helmet"] == "../Parts/part.tres", "Save As rebases slots")
		check(alternate.prefab_instances[0].source_path == "../Prefabs/tree.tres", "Save As rebases prefabs")
	var text: String = FileAccess.get_file_as_string(path)
	check(not text.contains(folder), "saved file contains no absolute asset directory")
	check(text.contains('path="Prefabs/tree.tres"'), "native dependency is relative")
	check(text.contains('res://scripts/editor/voxel_model.gd'), "script contract stays canonical")
	print("game_asset_authoring_test: ", "PASS" if failures == 0 else "FAIL")
	quit(1 if failures else 0)
