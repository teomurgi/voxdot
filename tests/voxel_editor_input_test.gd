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
		_key_event(code, pressed, ctrl, shift)


func _key_event(code: Key, pressed: bool, ctrl: bool = false, shift: bool = false) -> void:
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
	# Wheel over the side panel: the ScrollContainer consumes it mid-list, but
	# at its top/bottom edge the event used to fall through and zoom.
	var panel_dist: float = _ed._distance
	_move(on_panel)
	await _frames()
	var hovered: Control = root.gui_get_hovered_control()
	_check(hovered != null, "panel position hovers a control")
	if hovered != null:
		_button(on_panel, MOUSE_BUTTON_WHEEL_DOWN, true)
		await _frames()
		_check(is_equal_approx(_ed._distance, panel_dist), "wheel over the panel does not zoom at the scroll edge")
	_button(Vector2(600, 300), MOUSE_BUTTON_WHEEL_DOWN, true)
	await _frames()
	_check(_ed._distance > panel_dist, "wheel over the viewport still zooms")
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
	await _test_navigation()

	print("voxel_editor_input_test: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	quit(1 if _fails > 0 else 0)


func _test_navigation() -> void:
	print("WASD navigation")
	_ed.set_process(false)
	root.gui_release_focus()
	_ed._update_camera()
	var before: Vector3 = _ed._focus
	var forward := Vector3(-_ed.camera.global_basis.z.x, 0.0, -_ed.camera.global_basis.z.z).normalized()
	_key_event(KEY_W, true)
	_ed._update_navigation(0.5)
	var forward_step: Vector3 = _ed._focus - before
	_check(forward_step.length() > 0.1 and forward_step.normalized().dot(forward) > 0.999,
			"holding W moves toward the camera's horizontal forward")

	before = _ed._focus
	_key_event(KEY_D, true)
	_ed._update_navigation(0.5)
	var diagonal_step: Vector3 = _ed._focus - before
	_check(is_equal_approx(diagonal_step.length(), forward_step.length()), "diagonal movement is normalized")
	_key_event(KEY_W, false)
	_key_event(KEY_D, false)

	before = _ed._focus
	_key_event(KEY_SHIFT, true)
	_key_event(KEY_W, true)
	_ed._update_navigation(0.5)
	var fast_step: Vector3 = _ed._focus - before
	_check(is_equal_approx(fast_step.length(), forward_step.length() * VoxelModelEditor.NAVIGATION_FAST_MULTIPLIER),
			"Shift boosts navigation speed")
	_key_event(KEY_W, false)
	_key_event(KEY_SHIFT, false)

	before = _ed._focus
	_key_event(KEY_SPACE, true)
	_ed._update_navigation(0.25)
	_check(_ed._focus.y > before.y and is_equal_approx(_ed._focus.x, before.x) and is_equal_approx(_ed._focus.z, before.z),
			"Space flies straight up")
	_key_event(KEY_SPACE, false)
	before = _ed._focus
	_key_event(KEY_C, true)
	_ed._update_navigation(0.25)
	_check(_ed._focus.y < before.y, "C flies down")
	_key_event(KEY_C, false)

	_ed._depth_spin.get_line_edit().grab_focus()
	before = _ed._focus
	_key_event(KEY_W, true)
	_ed._update_navigation(0.5)
	_check(_ed._focus == before, "typing in a numeric field does not move the camera")
	_key_event(KEY_W, false)

	# Middle-dragging to orbit must also drop the spin box's keyboard focus:
	# otherwise WASD stayed dead until the next left click.
	_ed._depth_spin.get_line_edit().grab_focus()
	_check(root.gui_get_focus_owner() != null, "a spin box can hold keyboard focus")
	_button(Vector2(600, 300), MOUSE_BUTTON_MIDDLE, true)
	await _frames()
	_button(Vector2(600, 300), MOUSE_BUTTON_MIDDLE, false)
	await _frames()
	_check(root.gui_get_focus_owner() == null, "middle click in the viewport releases spin box focus")
	before = _ed._focus
	_key_event(KEY_W, true)
	_ed._update_navigation(0.5)
	_check(_ed._focus != before, "WASD works right after middle-dragging the view")
	_key_event(KEY_W, false)
	root.gui_release_focus()

	before = _ed._focus
	_key_event(KEY_CTRL, true, true)
	_key_event(KEY_W, true, true)
	_ed._update_navigation(0.5)
	_check(_ed._focus == before, "Ctrl+W does not trigger navigation")
	_key_event(KEY_W, false, true)
	_key_event(KEY_CTRL, false)
	_ed.set_process(true)
