class_name VoxelModelEditor
extends Node3D

## Voxdot: standalone voxel model editor. Edit space is 1 voxel = 1 world unit (the saved
## VoxelModel.voxel_size only matters when the model is instanced in a game
## scene). Editing logic lives in VoxelDocument; this node owns the camera,
## tools, hover preview and UI.
##
## Controls: LMB tool | MMB/RMB orbit | Shift+MMB/RMB pan | wheel zoom
## 1-7 tools | H height lock, [ ] layer down/up | X/Z mirror | Q/E rotate view | P ortho | G grid | F reframe
## Ctrl+Z / Ctrl+Shift+Z undo/redo | Ctrl+N/O/S new/open/save (+Shift = save as)

enum Tool { PLACE, ERASE, PAINT, PICK, BOX, BOX_ERASE, FILL }

const TOOL_NAMES: Array[String] = ["Place", "Erase", "Paint", "Pick", "Box", "Box Erase", "Fill"]
const TOOL_HINTS: Array[String] = [
	"Click/drag to add voxels",
	"Click/drag to remove voxels",
	"Click/drag to recolor existing voxels",
	"Click a voxel to pick its color",
	"Drag a rectangle; Box depth extrudes it",
	"Drag a rectangle into the model; Box depth sets how deep",
	"Recolor all connected voxels of the same color",
]
const APP_TITLE: String = "Voxdot"

var doc := VoxelDocument.new()
var current_tool: Tool = Tool.PLACE
var color: Color = Color("c2c7d1")
var box_depth: int = 1
var grid_visible: bool = true
var height_lock: bool = false
var work_layer: int = 0

var camera: Camera3D
var _yaw: float = deg_to_rad(45.0)
var _pitch: float = deg_to_rad(-35.264)
var _distance: float = 60.0
var _focus: Vector3 = Vector3(16, 6, 16)

var _model_mi: MeshInstance3D
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _grid_mi: MeshInstance3D
var _mirror_x_mi: MeshInstance3D
var _mirror_z_mi: MeshInstance3D
var _layer_mi: MeshInstance3D
var _mesh_dirty: bool = true

var _hover: Dictionary = {"valid": false}
var _stroking: bool = false
var _stroke_tool: Tool = Tool.PLACE
var _plane_axis: int = 1
var _plane_coord: float = 0.0
var _plane_layer: int = 0
var _plane_normal: Vector3i = Vector3i.UP
var _stroke_start: Vector3i = Vector3i.ZERO
var _last_cell: Vector3i = Vector3i(-1, -1, -1)
var _box_end: Vector3i = Vector3i.ZERO

# UI
var _tool_buttons: Array[Button] = []
var _color_button: ColorPickerButton
var _swatch_grid: GridContainer
var _mirror_x_check: CheckButton
var _mirror_z_check: CheckButton
var _depth_spin: SpinBox
var _bound_spins: Array[SpinBox] = []
var _size_spin: SpinBox
var _undo_button: Button
var _redo_button: Button
var _status_label: Label
var _cursor_label: Label
var _lock_check: CheckButton
var _layer_spin: SpinBox
var _message_label: Label
var _hint_label: Label
var _file_dialog: FileDialog
var _confirm_dialog: ConfirmationDialog
var _pending_open: bool = false
var _pending_action: Callable = Callable()
var _syncing_ui: bool = false


func _ready() -> void:
	_build_world()
	_build_ui()
	doc.changed.connect(func() -> void: _mesh_dirty = true)
	doc.meta_changed.connect(_on_meta_changed)
	doc.history_changed.connect(_refresh_history_buttons)
	_on_meta_changed()
	_refresh_history_buttons()
	_set_tool(Tool.PLACE)
	_set_color(color)
	frame_model()
	_update_camera()
	# Closing the window must go through the unsaved-changes prompt.
	get_tree().set_auto_accept_quit(false)
	get_window().files_dropped.connect(_on_files_dropped)
	var arg: String = cli_model_path(OS.get_cmdline_user_args() + OS.get_cmdline_args())
	if arg != "":
		_open_path(arg)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_confirm_discard(get_tree().quit)


## First argument that names an existing .tres/.res file, made absolute against
## the shell's working directory. Returns "" when there is none.
static func cli_model_path(args: PackedStringArray) -> String:
	for a in args:
		if a.begins_with("-"):
			continue
		var ext: String = a.get_extension().to_lower()
		if ext != "tres" and ext != "res":
			continue
		var full: String = a
		if not a.is_absolute_path() and not a.begins_with("res://") and not a.begins_with("user://"):
			var cwd: String = OS.get_environment("PWD")
			if cwd == "":
				cwd = OS.get_executable_path().get_base_dir()
			full = cwd.path_join(a)
		if FileAccess.file_exists(full):
			return full
	return ""


func _on_files_dropped(files: PackedStringArray) -> void:
	var path: String = cli_model_path(files)
	if path != "":
		_confirm_discard(func() -> void: _open_path(path))


func _open_path(chosen: String) -> void:
	var p: String = ProjectSettings.localize_path(chosen)
	var err: Error = doc.load_file(p)
	if err == OK:
		frame_model()
		_say("Opened " + p)
	else:
		_say("Open failed (%s): %s" % [error_string(err), p])


# --- World construction ---

func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.12, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.57, 0.65)
	env.ambient_light_energy = 0.75
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.far = 1000.0
	camera.near = 0.05
	camera.current = true
	add_child(camera)

	_model_mi = MeshInstance3D.new()
	_model_mi.name = "Model"
	add_child(_model_mi)

	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(1, 1, 1, 0.45)
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	box.material = _ghost_mat
	_ghost = MeshInstance3D.new()
	_ghost.name = "Ghost"
	_ghost.mesh = box
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.visible = false
	add_child(_ghost)

	_grid_mi = MeshInstance3D.new()
	_grid_mi.name = "Grid"
	_grid_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_grid_mi)

	_mirror_x_mi = _make_mirror_plane("MirrorX")
	_mirror_z_mi = _make_mirror_plane("MirrorZ")
	_layer_mi = _make_mirror_plane("WorkLayer")
	((_layer_mi.mesh as QuadMesh).material as StandardMaterial3D).albedo_color = Color(1.0, 0.75, 0.25, 0.14)


func _make_mirror_plane(node_name: String) -> MeshInstance3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.3, 0.8, 1.0, 0.12)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var q := QuadMesh.new()
	q.material = m
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = q
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return mi


func _rebuild_grid() -> void:
	var b: Vector3i = doc.bounds
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var minor := Color(1, 1, 1, 0.08)
	var major := Color(1, 1, 1, 0.22)
	var y: float = -0.002
	for x in range(b.x + 1):
		var c: Color = major if x % 8 == 0 else minor
		verts.append(Vector3(x, y, 0))
		verts.append(Vector3(x, y, b.z))
		cols.append(c)
		cols.append(c)
	for z in range(b.z + 1):
		var c: Color = major if z % 8 == 0 else minor
		verts.append(Vector3(0, y, z))
		verts.append(Vector3(b.x, y, z))
		cols.append(c)
		cols.append(c)
	var frame := Color(0.95, 0.8, 0.35, 0.55)
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(Vector3(b.x * (i & 1), b.y * ((i >> 1) & 1), b.z * ((i >> 2) & 1)))
	for pair: Vector2i in [
		Vector2i(0, 1), Vector2i(2, 3), Vector2i(4, 5), Vector2i(6, 7),
		Vector2i(0, 2), Vector2i(1, 3), Vector2i(4, 6), Vector2i(5, 7),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]:
		verts.append(corners[pair.x])
		verts.append(corners[pair.y])
		cols.append(frame)
		cols.append(frame)
	# Axis hints at the origin corner: +X red, +Z blue.
	var axis_len: float = float(mini(b.x, 8))
	verts.append(Vector3(0, y - 0.002, 0))
	verts.append(Vector3(axis_len, y - 0.002, 0))
	cols.append(Color(1, 0.3, 0.3, 1))
	cols.append(Color(1, 0.3, 0.3, 1))
	axis_len = float(mini(b.z, 8))
	verts.append(Vector3(0, y - 0.002, 0))
	verts.append(Vector3(0, y - 0.002, axis_len))
	cols.append(Color(0.3, 0.5, 1, 1))
	cols.append(Color(0.3, 0.5, 1, 1))

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, mat)
	_grid_mi.mesh = mesh
	_grid_mi.visible = grid_visible

	_mirror_x_mi.position = Vector3(b.x * 0.5, b.y * 0.5, b.z * 0.5)
	_mirror_x_mi.rotation_degrees = Vector3(0, 90, 0)
	(_mirror_x_mi.mesh as QuadMesh).size = Vector2(b.z, b.y)
	_mirror_z_mi.position = _mirror_x_mi.position
	_mirror_z_mi.rotation_degrees = Vector3.ZERO
	(_mirror_z_mi.mesh as QuadMesh).size = Vector2(b.x, b.y)
	_update_layer_plane()


func _update_layer_plane() -> void:
	var b: Vector3i = doc.bounds
	work_layer = clampi(work_layer, 0, b.y - 1)
	_layer_mi.position = Vector3(b.x * 0.5, float(work_layer) + 0.002, b.z * 0.5)
	_layer_mi.rotation_degrees = Vector3(-90, 0, 0)
	(_layer_mi.mesh as QuadMesh).size = Vector2(b.x, b.z)
	_layer_mi.visible = height_lock


func _rebuild_mesh() -> void:
	_mesh_dirty = false
	_model_mi.mesh = VoxelMeshBuilder.build_mesh(doc.grid, 1.0)


# --- Camera ---

func frame_model() -> void:
	var b := Vector3(doc.bounds)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p: Vector3i in doc.grid:
		lo = lo.min(Vector3(p))
		hi = hi.max(Vector3(p) + Vector3.ONE)
	if doc.grid.is_empty():
		_focus = Vector3(b.x * 0.5, b.y * 0.2, b.z * 0.5)
		_distance = maxf(b.x, b.z) * 1.9
	else:
		_focus = (lo + hi) * 0.5
		_distance = maxf((hi - lo).length() * 1.6, 12.0)


func _update_camera() -> void:
	var rot := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	camera.transform = Transform3D(rot, _focus + rot.z * _distance)
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		camera.size = _distance * 0.8


func _set_orthographic(on: bool) -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL if on else Camera3D.PROJECTION_PERSPECTIVE
	_update_camera()


func _orbit(delta: Vector2) -> void:
	_yaw -= delta.x * 0.005
	_pitch = clampf(_pitch - delta.y * 0.005, deg_to_rad(-89.0), deg_to_rad(20.0))


func _pan(delta: Vector2) -> void:
	var rot := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	var k: float = _distance * 0.0016
	_focus += (-rot.x * delta.x + rot.y * delta.y) * k


# --- Per-frame ---

func _process(_delta: float) -> void:
	if _mesh_dirty:
		_rebuild_mesh()
		_update_status()
	_update_camera()

	var mouse: Vector2 = get_viewport().get_mouse_position()
	var origin: Vector3 = camera.project_ray_origin(mouse)
	var dir: Vector3 = camera.project_ray_normal(mouse)

	if _stroking:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_finish_stroke()
		else:
			_update_stroke(origin, dir)
			_update_ghost()
			return

	var camera_drag: bool = (Input.get_mouse_button_mask() & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0
	if get_viewport().gui_get_hovered_control() != null or camera_drag:
		_hover = {"valid": false}
	else:
		_hover = _compute_hover(origin, dir)
	_update_ghost()


func _compute_hover(origin: Vector3, dir: Vector3) -> Dictionary:
	var info: Dictionary = {"valid": false}
	var r: Dictionary = VoxelRaycast.cast(doc.grid, doc.bounds, origin, dir)
	var adds: bool = current_tool == Tool.PLACE or current_tool == Tool.BOX
	if height_lock and adds:
		return _hover_on_layer(origin, dir)
	var normal: Vector3i = r["normal"]
	if r["hit"]:
		var pos: Vector3i = r["pos"]
		if normal == Vector3i.ZERO:
			normal = Vector3i.UP
		var cell: Vector3i = pos + normal if adds else pos
		if not doc.in_bounds(cell):
			return info
		var a: int = _axis_of(normal)
		info["valid"] = true
		info["cell"] = cell
		info["normal"] = normal
		info["face_coord"] = float(pos[a] + (1 if normal[a] > 0 else 0))
	elif r["floor"] and adds:
		info["valid"] = true
		info["cell"] = r["pos"]
		info["normal"] = Vector3i.UP
		info["face_coord"] = 0.0
	return info


## Height lock: add tools target the horizontal plane at `work_layer`,
## ignoring any voxels in the way.
func _hover_on_layer(origin: Vector3, dir: Vector3) -> Dictionary:
	var info: Dictionary = {"valid": false}
	if absf(dir.y) < 1e-6:
		return info
	var t: float = (float(work_layer) - origin.y) / dir.y
	if t < 0.0:
		return info
	var p: Vector3 = origin + dir * t
	var cell := Vector3i(floori(p.x), work_layer, floori(p.z))
	if not doc.in_bounds(cell):
		return info
	info["valid"] = true
	info["cell"] = cell
	info["normal"] = Vector3i.UP
	info["face_coord"] = float(work_layer)
	return info


static func _axis_of(n: Vector3i) -> int:
	if n.x != 0:
		return 0
	if n.z != 0:
		return 2
	return 1


# --- Stroke handling ---

func _begin_stroke(h: Dictionary) -> void:
	var cell: Vector3i = h["cell"]
	match current_tool:
		Tool.PICK:
			if doc.grid.has(cell):
				_set_color(doc.grid[cell])
			return
		Tool.FILL:
			doc.paint_cells(doc.flood_cells(cell), color)
			return
	_stroking = true
	_stroke_tool = current_tool
	_plane_normal = h["normal"]
	_plane_axis = _axis_of(_plane_normal)
	_plane_coord = h["face_coord"]
	_plane_layer = cell[_plane_axis]
	_stroke_start = cell
	_last_cell = cell
	_box_end = cell
	doc.begin_stroke()
	if not _is_box_tool(_stroke_tool):
		_apply_cell(cell)


func _is_box_tool(t: Tool) -> bool:
	return t == Tool.BOX or t == Tool.BOX_ERASE


func _apply_cell(cell: Vector3i) -> void:
	var one: Array[Vector3i] = [cell]
	match _stroke_tool:
		Tool.PLACE:
			doc.place_cells(one, color)
		Tool.ERASE:
			doc.erase_cells(one)
		Tool.PAINT:
			doc.paint_cells(one, color)


func _update_stroke(origin: Vector3, dir: Vector3) -> void:
	var a: int = _plane_axis
	if absf(dir[a]) < 1e-6:
		return
	var t: float = (_plane_coord - origin[a]) / dir[a]
	if t < 0.0:
		return
	var p: Vector3 = origin + dir * t
	var cell := Vector3i(floori(p.x), floori(p.y), floori(p.z))
	cell[a] = _plane_layer
	if _is_box_tool(_stroke_tool):
		_box_end = cell.clamp(Vector3i.ZERO, doc.bounds - Vector3i.ONE)
	elif cell != _last_cell:
		_last_cell = cell
		_apply_cell(cell)


func _box_extent() -> Array[Vector3i]:
	var a: int = _plane_axis
	var lo := Vector3i(mini(_stroke_start.x, _box_end.x), mini(_stroke_start.y, _box_end.y), mini(_stroke_start.z, _box_end.z))
	var hi := Vector3i(maxi(_stroke_start.x, _box_end.x), maxi(_stroke_start.y, _box_end.y), maxi(_stroke_start.z, _box_end.z))
	var sign_n: int = _plane_normal[a]
	if _stroke_tool == Tool.BOX_ERASE:
		sign_n = -sign_n
	var far: int = _plane_layer + sign_n * (box_depth - 1)
	lo[a] = mini(_plane_layer, far)
	hi[a] = maxi(_plane_layer, far)
	var top: Vector3i = doc.bounds - Vector3i.ONE
	return [lo.clamp(Vector3i.ZERO, top), hi.clamp(Vector3i.ZERO, top)]


func _finish_stroke() -> void:
	if _is_box_tool(_stroke_tool):
		var ext: Array[Vector3i] = _box_extent()
		var cells: Array[Vector3i] = VoxelDocument.box_cells(ext[0], ext[1])
		if _stroke_tool == Tool.BOX:
			doc.place_cells(cells, color)
		else:
			doc.erase_cells(cells)
	doc.end_stroke()
	_stroking = false
	_last_cell = Vector3i(-1, -1, -1)


# --- Ghost preview ---

func _update_ghost() -> void:
	var tool_for_ghost: Tool = _stroke_tool if _stroking else current_tool
	if _stroking and _is_box_tool(_stroke_tool):
		var ext: Array[Vector3i] = _box_extent()
		_show_ghost(Vector3(ext[0]) + Vector3(ext[1] - ext[0] + Vector3i.ONE) * 0.5,
				Vector3(ext[1] - ext[0] + Vector3i.ONE), tool_for_ghost)
		_set_cursor_text(_box_end)
		return
	if _stroking:
		_show_ghost(Vector3(_last_cell) + Vector3.ONE * 0.5, Vector3.ONE, tool_for_ghost)
		_set_cursor_text(_last_cell)
		return
	if not _hover.get("valid", false):
		_ghost.visible = false
		_set_cursor_text(null)
		return
	var cell: Vector3i = _hover["cell"]
	_set_cursor_text(cell)
	_show_ghost(Vector3(cell) + Vector3.ONE * 0.5, Vector3.ONE, tool_for_ghost)


func _set_cursor_text(cell: Variant) -> void:
	if _cursor_label == null:
		return
	if cell == null:
		_cursor_label.text = "Cursor: -"
	else:
		var c: Vector3i = cell
		_cursor_label.text = "Cursor: %d, %d, %d" % [c.x, c.y, c.z]


func _show_ghost(center: Vector3, extent: Vector3, t: Tool) -> void:
	_ghost.visible = true
	_ghost.position = center
	_ghost.scale = extent + Vector3.ONE * 0.04
	var c: Color
	match t:
		Tool.ERASE, Tool.BOX_ERASE:
			c = Color(1.0, 0.25, 0.25, 0.5)
		Tool.PICK:
			c = Color(1, 1, 1, 0.35)
		Tool.FILL:
			c = Color(color.r, color.g, color.b, 0.6)
		_:
			c = Color(color.r, color.g, color.b, 0.5)
	_ghost_mat.albedo_color = c


# --- Input ---

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_LEFT:
					get_viewport().gui_release_focus()
					if _hover.get("valid", false) and not _stroking:
						_begin_stroke(_hover)
				MOUSE_BUTTON_WHEEL_UP:
					_distance = clampf(_distance * 0.9, 3.0, 400.0)
				MOUSE_BUTTON_WHEEL_DOWN:
					_distance = clampf(_distance / 0.9, 3.0, 400.0)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if (mm.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0:
			if mm.shift_pressed:
				_pan(mm.relative)
			else:
				_orbit(mm.relative)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and _handle_key(k):
			get_viewport().set_input_as_handled()


func _handle_key(k: InputEventKey) -> bool:
	if k.ctrl_pressed or k.meta_pressed:
		match k.keycode:
			KEY_Z:
				if k.shift_pressed:
					_do_redo()
				else:
					_do_undo()
			KEY_Y:
				_do_redo()
			KEY_S:
				_save(k.shift_pressed)
			KEY_O:
				_ask_open()
			KEY_N:
				_ask_new()
			_:
				return false
		return true
	match k.keycode:
		KEY_1: _set_tool(Tool.PLACE)
		KEY_2: _set_tool(Tool.ERASE)
		KEY_3: _set_tool(Tool.PAINT)
		KEY_4: _set_tool(Tool.PICK)
		KEY_5: _set_tool(Tool.BOX)
		KEY_6: _set_tool(Tool.BOX_ERASE)
		KEY_7: _set_tool(Tool.FILL)
		KEY_H: _set_height_lock(not height_lock)
		KEY_BRACKETRIGHT, KEY_PAGEUP: _step_layer(1)
		KEY_BRACKETLEFT, KEY_PAGEDOWN: _step_layer(-1)
		KEY_X: _set_mirror(not doc.mirror_x, doc.mirror_z)
		KEY_Z: _set_mirror(doc.mirror_x, not doc.mirror_z)
		KEY_Q: _yaw += deg_to_rad(90.0)
		KEY_E: _yaw -= deg_to_rad(90.0)
		KEY_P: _set_orthographic(camera.projection == Camera3D.PROJECTION_PERSPECTIVE)
		KEY_G:
			grid_visible = not grid_visible
			_grid_mi.visible = grid_visible
		KEY_F: frame_model()
		_:
			return false
	return true


# --- Actions ---

func _set_tool(t: Tool) -> void:
	if _stroking:
		return
	current_tool = t
	for i in _tool_buttons.size():
		_tool_buttons[i].set_pressed_no_signal(i == int(t))
	if _hint_label != null:
		_hint_label.text = TOOL_HINTS[int(t)]


func _set_color(c: Color) -> void:
	color = Color(c.r, c.g, c.b, 1.0)
	if _color_button != null:
		_color_button.color = color


func _set_height_lock(on: bool) -> void:
	height_lock = on
	_layer_mi.visible = on
	if _lock_check != null:
		_lock_check.set_pressed_no_signal(on)
	_say("Height lock %s (layer Y=%d)" % ["on" if on else "off", work_layer])


## Moves the work layer and turns the lock on, since adjusting it implies use.
func _set_layer(y: int) -> void:
	work_layer = clampi(y, 0, doc.bounds.y - 1)
	_update_layer_plane()
	if _layer_spin != null:
		_syncing_ui = true
		_layer_spin.value = work_layer
		_syncing_ui = false
	if not height_lock:
		_set_height_lock(true)


func _step_layer(d: int) -> void:
	_set_layer(work_layer + d)


func _set_mirror(x: bool, z: bool) -> void:
	doc.set_mirror(x, z)


func _do_undo() -> void:
	if not _stroking and doc.undo():
		_say("Undo")


func _do_redo() -> void:
	if not _stroking and doc.redo():
		_say("Redo")


func _say(msg: String) -> void:
	if _message_label != null:
		_message_label.text = msg


func _save(force_dialog: bool) -> void:
	if doc.path == "" or force_dialog:
		_open_file_dialog(false)
		return
	_write_file(doc.path)


func _write_file(target: String) -> void:
	var err: Error = doc.save_file(target)
	if err == OK:
		_say("Saved " + target)
	else:
		_say("Save failed (%s): %s" % [error_string(err), target])


func _ask_new() -> void:
	_confirm_discard(func() -> void:
		doc.reset()
		frame_model()
		_say("New model"))


func _ask_open() -> void:
	_confirm_discard(func() -> void: _open_file_dialog(true))


func _confirm_discard(action: Callable) -> void:
	if not doc.dirty:
		action.call()
		return
	_pending_action = action
	_confirm_dialog.popup_centered()


func _open_file_dialog(for_open: bool) -> void:
	_pending_open = for_open
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE if for_open else FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.title = "Open Voxel Model" if for_open else "Save Voxel Model"
	if doc.path != "":
		_file_dialog.current_dir = ProjectSettings.globalize_path(doc.path).get_base_dir()
	else:
		_file_dialog.current_dir = _default_dir()
	_file_dialog.popup_centered()


func _default_dir() -> String:
	var docs: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs == "":
		docs = OS.get_user_data_dir()
	var dir: String = docs.path_join(APP_TITLE)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _on_file_selected(chosen: String) -> void:
	var p: String = ProjectSettings.localize_path(chosen)
	if _pending_open:
		_open_path(chosen)
	else:
		var ext: String = p.get_extension()
		if ext != "tres" and ext != "res":
			p += ".tres"
		_write_file(p)


# --- UI ---

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var panel := PanelContainer.new()
	panel.name = "ToolPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	panel.custom_minimum_size = Vector2(250, 0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.13, 0.14, 0.18, 1.0)
	panel_style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", panel_style)
	root.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)
	scroll.add_child(vb)

	var title := Label.new()
	title.text = APP_TITLE
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)

	_section(vb, "Tool")
	var tools := GridContainer.new()
	tools.columns = 2
	vb.add_child(tools)
	for i in TOOL_NAMES.size():
		var b := Button.new()
		b.text = "%d  %s" % [i + 1, TOOL_NAMES[i]]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_set_tool.bind(i as Tool))
		tools.add_child(b)
		_tool_buttons.append(b)
	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	vb.add_child(_hint_label)

	var depth_row := HBoxContainer.new()
	vb.add_child(depth_row)
	depth_row.add_child(_label("Box depth"))
	_depth_spin = _spin(1, 64, 1, 1)
	_depth_spin.value_changed.connect(func(v: float) -> void: box_depth = int(v))
	depth_row.add_child(_depth_spin)

	var lock_row := HBoxContainer.new()
	vb.add_child(lock_row)
	_lock_check = CheckButton.new()
	_lock_check.text = "Height lock (H)"
	_lock_check.focus_mode = Control.FOCUS_NONE
	_lock_check.tooltip_text = "Place/Box target the horizontal plane at layer Y instead of surfaces. [ ] or PageUp/PageDown change the layer."
	_lock_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			_set_height_lock(on))
	lock_row.add_child(_lock_check)
	var layer_row := HBoxContainer.new()
	vb.add_child(layer_row)
	layer_row.add_child(_label("Layer Y"))
	_layer_spin = _spin(0, 31, 1, 0)
	_layer_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			_set_layer(int(v)))
	layer_row.add_child(_layer_spin)

	_section(vb, "Color")
	_color_button = ColorPickerButton.new()
	_color_button.edit_alpha = false
	_color_button.custom_minimum_size = Vector2(0, 30)
	_color_button.focus_mode = Control.FOCUS_NONE
	_color_button.color = color
	_color_button.color_changed.connect(func(c: Color) -> void: color = Color(c.r, c.g, c.b, 1.0))
	vb.add_child(_color_button)
	_swatch_grid = GridContainer.new()
	_swatch_grid.columns = 8
	_swatch_grid.add_theme_constant_override("h_separation", 3)
	_swatch_grid.add_theme_constant_override("v_separation", 3)
	vb.add_child(_swatch_grid)
	var add_swatch := _button("+ Add current color to palette", func() -> void: doc.add_swatch(color))
	vb.add_child(add_swatch)

	_section(vb, "Symmetry")
	_mirror_x_check = CheckButton.new()
	_mirror_x_check.text = "Mirror X  (X)"
	_mirror_x_check.focus_mode = Control.FOCUS_NONE
	_mirror_x_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			_set_mirror(on, doc.mirror_z))
	vb.add_child(_mirror_x_check)
	_mirror_z_check = CheckButton.new()
	_mirror_z_check.text = "Mirror Z  (Z)"
	_mirror_z_check.focus_mode = Control.FOCUS_NONE
	_mirror_z_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			_set_mirror(doc.mirror_x, on))
	vb.add_child(_mirror_z_check)

	_section(vb, "Model")
	var axes: Array[String] = ["W", "H", "D"]
	var bounds_row := HBoxContainer.new()
	vb.add_child(bounds_row)
	for i in 3:
		bounds_row.add_child(_label(axes[i]))
		var s := _spin(VoxelDocument.MIN_BOUND, VoxelDocument.MAX_BOUND, 1, 32)
		s.value_changed.connect(_on_bounds_spin)
		bounds_row.add_child(s)
		_bound_spins.append(s)
	var size_row := HBoxContainer.new()
	vb.add_child(size_row)
	size_row.add_child(_label("Voxel size (m)"))
	_size_spin = _spin(0.005, 4.0, 0.0005, 0.0625)
	_size_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			doc.set_voxel_size(v))
	size_row.add_child(_size_spin)

	var hist := HBoxContainer.new()
	vb.add_child(hist)
	_undo_button = _button("Undo", _do_undo)
	_undo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hist.add_child(_undo_button)
	_redo_button = _button("Redo", _do_redo)
	_redo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hist.add_child(_redo_button)

	_section(vb, "File")
	var file_row := HBoxContainer.new()
	vb.add_child(file_row)
	for entry: Array in [["New", _ask_new], ["Open", _ask_open], ["Save", _save.bind(false)], ["Save As", _save.bind(true)]]:
		var b := _button(entry[0], entry[1])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		file_row.add_child(b)

	_section(vb, "View")
	var view_row := HBoxContainer.new()
	vb.add_child(view_row)
	var ortho := CheckButton.new()
	ortho.text = "Ortho (P)"
	ortho.focus_mode = Control.FOCUS_NONE
	ortho.toggled.connect(_set_orthographic)
	view_row.add_child(ortho)
	view_row.add_child(_button("Frame (F)", frame_model))

	_cursor_label = Label.new()
	_cursor_label.text = "Cursor: -"
	vb.add_child(_cursor_label)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status_label)
	_message_label = Label.new()
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	vb.add_child(_message_label)

	var help := Label.new()
	help.text = "LMB tool   MMB/RMB orbit\nShift+MMB/RMB pan   Wheel zoom\nQ/E rotate view   G grid\nH height lock   [ ] layer up/down\nCtrl+Z/Y undo/redo   Ctrl+S save"
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	help.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	help.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	help.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	help.offset_top = 8
	help.offset_right = -10
	root.add_child(help)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = false
	_file_dialog.filters = PackedStringArray(["*.tres, *.res ; Voxel Model"])
	_file_dialog.size = Vector2i(760, 480)
	_file_dialog.file_selected.connect(_on_file_selected)
	layer.add_child(_file_dialog)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.dialog_text = "Discard unsaved changes?"
	_confirm_dialog.ok_button_text = "Discard"
	_confirm_dialog.confirmed.connect(func() -> void:
		var action: Callable = _pending_action
		_pending_action = Callable()
		if action.is_valid():
			action.call())
	layer.add_child(_confirm_dialog)


func _section(parent: Control, text: String) -> void:
	parent.add_child(HSeparator.new())
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
	parent.add_child(l)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _spin(lo: float, hi: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func _on_bounds_spin(_v: float) -> void:
	if _syncing_ui:
		return
	var want := Vector3i(int(_bound_spins[0].value), int(_bound_spins[1].value), int(_bound_spins[2].value))
	if doc.resize_bounds(want):
		return
	_say("Can't shrink: voxels exist outside the new size")
	_sync_ui_from_doc()


func _rebuild_swatches() -> void:
	for child in _swatch_grid.get_children():
		_swatch_grid.remove_child(child)
		child.queue_free()
	for c in doc.swatches:
		var b := Button.new()
		b.custom_minimum_size = Vector2(24, 24)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "#" + c.to_html(false)
		for state: String in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = c
			sb.set_border_width_all(1)
			sb.border_color = Color(0, 0, 0, 0.6) if state != "hover" else Color.WHITE
			b.add_theme_stylebox_override(state, sb)
		b.pressed.connect(_set_color.bind(c))
		_swatch_grid.add_child(b)


func _on_meta_changed() -> void:
	_rebuild_grid()
	_sync_ui_from_doc()
	if _swatch_grid != null and _swatch_grid.get_child_count() != doc.swatches.size():
		_rebuild_swatches()
	_mirror_x_mi.visible = doc.mirror_x
	_mirror_z_mi.visible = doc.mirror_z
	_update_status()


func _sync_ui_from_doc() -> void:
	if _bound_spins.is_empty():
		return
	_syncing_ui = true
	_bound_spins[0].value = doc.bounds.x
	_bound_spins[1].value = doc.bounds.y
	_bound_spins[2].value = doc.bounds.z
	_size_spin.value = doc.voxel_size
	_layer_spin.max_value = doc.bounds.y - 1
	_layer_spin.value = clampi(work_layer, 0, doc.bounds.y - 1)
	_mirror_x_check.set_pressed_no_signal(doc.mirror_x)
	_mirror_z_check.set_pressed_no_signal(doc.mirror_z)
	_syncing_ui = false


func _refresh_history_buttons() -> void:
	if _undo_button != null:
		_undo_button.disabled = not doc.can_undo()
		_redo_button.disabled = not doc.can_redo()


func _update_status() -> void:
	if _status_label == null:
		return
	var name_text: String = doc.path.get_file() if doc.path != "" else "(unsaved)"
	get_window().title = "%s%s - %s" % [name_text, "*" if doc.dirty else "", APP_TITLE]
	_status_label.text = "%s%s\n%d voxels  |  %dx%dx%d" % [
		name_text, "*" if doc.dirty else "", doc.voxel_count(),
		doc.bounds.x, doc.bounds.y, doc.bounds.z]
