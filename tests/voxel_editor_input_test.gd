extends SceneTree

## Pushes real InputEvents through the viewport into the voxel editor to cover
## the _unhandled_input / _process stroke path: drag-painting across frames,
## UI click-through protection, orbit, keyboard shortcuts.
## Run: godot --headless --path godot -s tests/voxel_editor_input_test.gd

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


var _last_pos: Vector2 = Vector2.ZERO


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
		e.pressed = pressed
		e.ctrl_pressed = ctrl
		e.shift_pressed = shift
		Input.parse_input_event(e)


func _frames(n: int = 3) -> void:
	for i in n:
		await process_frame


func _screen(world: Vector3) -> Vector2:
	return _ed.camera.unproject_position(world)


func _run() -> void:
	await _frames(2)
	# The headless dummy window is 64x64; with canvas_items stretch that scales
	# mouse coordinates, so pin a 1:1 window for deterministic event positions.
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	await _frames(3)
	Input.use_accumulated_input = false
	_ed.doc.reset()
	# Park the view on the model-free floor with the panel out of the way.
	_ed._set_color(Color.RED)

	print("drag stroke")
	var a: Vector2 = _screen(Vector3(14.5, 0, 14.5))
	var b: Vector2 = _screen(Vector3(18.5, 0, 14.5))
	_check(a.x > 300 and b.x > 300, "test cells are outside the UI panel")
	_move(a)
	await _frames()
	_button(a, MOUSE_BUTTON_LEFT, true)
	await _frames()
	for i in 9:
		_move(a.lerp(b, float(i + 1) / 9.0), MOUSE_BUTTON_MASK_LEFT)
		await _frames(2)
	_button(b, MOUSE_BUTTON_LEFT, false)
	await _frames(3)
	var row: int = 0
	for x in range(14, 19):
		if _ed.doc.grid.has(Vector3i(x, 0, 14)):
			row += 1
	_check(row == 5, "dragging across 5 floor cells places 5 voxels (got %d)" % row)
	_check(_ed.doc.voxel_count() == 5, "no stray voxels / stacking while holding still")
	_check(not _ed._stroking, "stroke ended on release")
	_ed.doc.undo()
	_check(_ed.doc.voxel_count() == 0, "whole drag is a single undo step")

	print("UI click-through")
	var on_panel := Vector2(100, 8)
	_move(on_panel)
	await _frames()
	_button(on_panel, MOUSE_BUTTON_LEFT, true)
	await _frames()
	_button(on_panel, MOUSE_BUTTON_LEFT, false)
	await _frames()
	_check(_ed.doc.voxel_count() == 0, "clicking the panel does not edit the model")

	print("camera + keys")
	var yaw0: float = _ed._yaw
	var dist0: float = _ed._distance
	_move(Vector2(600, 300))
	_button(Vector2(600, 300), MOUSE_BUTTON_MIDDLE, true)
	await _frames()
	_move(Vector2(650, 300), MOUSE_BUTTON_MASK_MIDDLE)
	await _frames()
	_button(Vector2(650, 300), MOUSE_BUTTON_MIDDLE, false)
	await _frames()
	_check(not is_equal_approx(_ed._yaw, yaw0), "middle-drag orbits")
	_button(Vector2(600, 300), MOUSE_BUTTON_WHEEL_UP, true)
	await _frames()
	_check(_ed._distance < dist0, "wheel zooms in")
	_key(KEY_3)
	await _frames()
	_check(_ed.current_tool == VoxelModelEditor.Tool.PAINT, "key 3 selects Paint")
	_key(KEY_X)
	await _frames()
	_check(_ed.doc.mirror_x and _ed._mirror_x_check.button_pressed, "key X toggles mirror + checkbox")
	_key(KEY_X)
	_ed.doc.place_cells([Vector3i(1, 0, 1)] as Array[Vector3i], Color.RED)
	_key(KEY_Z, true)
	await _frames()
	_check(_ed.doc.voxel_count() == 0, "Ctrl+Z undoes")
	_key(KEY_Z, true, true)
	await _frames()
	_check(_ed.doc.voxel_count() == 1, "Ctrl+Shift+Z redoes")
	_key(KEY_P)
	await _frames()
	_check(_ed.camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "key P toggles orthographic")

	print("voxel_editor_input_test: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	quit(1 if _fails > 0 else 0)
