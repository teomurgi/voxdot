class_name VoxelModelEditor
extends Node3D

## Voxdot: standalone voxel model editor. Edit space is 1 voxel = 1 world unit (the saved
## VoxelModel.voxel_size only matters when the model is instanced in a game
## scene). Editing logic lives in VoxelDocument; this node owns the camera,
## tools, hover preview and UI.
##
## Controls: LMB tool | MMB/RMB orbit | Shift+MMB/RMB pan | wheel zoom
## 1-9 tools, 0 Prefab, M Material, K Character | H height lock, [ ] layer down/up | X/Z mirror | Q/E rotate view | P ortho | G grid | F reframe
## B catalogue | R rotate prefab | Ctrl+D duplicate prefab | Delete prefab/light | Esc cancel
## Ctrl+Z / Ctrl+Shift+Z undo/redo | Ctrl+N/O/S new/open/save (+Shift = save as)

## PREFAB is appended (not first) so the existing 1–9 shortcuts keep their
## tool; the Prefab tool itself is on `0`. MATERIAL is on `M`, CHARACTER on `K` (C is fly-down).
enum Tool { PLACE, ERASE, PAINT, PICK, BOX, BOX_ERASE, FILL, LIGHT_PLACE, LIGHT_EDIT, PREFAB, MATERIAL, CHARACTER }

const TOOL_NAMES: Array[String] = ["Place", "Erase", "Paint", "Pick", "Box", "Box Erase", "Fill", "Light", "Edit Light", "Prefab", "Material", "Character"]
const TOOL_HINTS: Array[String] = [
	"Click/drag to add voxels",
	"Click/drag to remove voxels",
	"Click/drag to recolor existing voxels",
	"Click a voxel to pick its color and material",
	"Drag a rectangle; Box depth extrudes it",
	"Drag a rectangle into the model; Box depth sets how deep",
	"Recolor all connected voxels of the same color",
	"Click to add a point light; drag on the work plane to position it",
	"Click a light handle to select it; drag to move it; Delete removes it",
	"Click an instance to select; drag to move; R rotate; Ctrl+D duplicate; B catalogue",
	"Click/drag to apply the active material and overrides",
	"Pick a preset, assign saved-model parts, preview animations on the live rig",
]
const APP_TITLE: String = "Voxdot"
const LEFT_PANEL_WIDTH: int = 264
const RIGHT_PANEL_WIDTH: int = 352

var doc := VoxelDocument.new()
var current_tool: Tool = Tool.PLACE
var color: Color = Color("c2c7d1")
var current_material: int = VoxelMaterial.Kind.DEFAULT
var current_material_overrides: int = 0
var box_depth: int = 1
var grid_visible: bool = true
var height_lock: bool = false
var work_layer: int = 0

var camera: Camera3D
var world_environment: Environment
var sun: DirectionalLight3D
var selected_light_id: int = -1
var light_rig: VoxelLightRig
var _drag_light_id: int = -1
var _light_edit_active: bool = false
var _drag_light_plane := Plane()
var _yaw: float = deg_to_rad(45.0)
var _pitch: float = deg_to_rad(-35.264)
var _distance: float = 60.0
var _focus: Vector3 = Vector3(16, 6, 16)

# --- Prefabs ---
## Linked instance currently selected in the viewport (-1 = none).
var selected_prefab_id: int = -1
## Asset armed for placement from the catalogue ("" = selection mode).
var armed_asset_id: String = ""
var armed_source: VoxelModel
var armed_pivot: Vector3 = Vector3.ZERO
var armed_yaw: int = 0
var prefab_rig: VoxelPrefabRig

# --- Character ---
## Live preview rig for the Character tool (hidden unless CHARACTER active).
var character_rig: VoxelCharacterRig
var _character_preset_option: OptionButton
var _character_slot_edits: Dictionary = {}  # slot StringName -> LineEdit
var _character_anim_label: Label
var _character_file_slot: StringName = &""
var catalog := VoxelPrefabCatalog.new()
var catalog_dialog: VoxelPrefabCatalogDialog
var _drag_prefab_id: int = -1
var _drag_prefab_origin: Vector3i = Vector3i.ZERO
var _drag_prefab_start := Vector3.ZERO
var _prefab_drag_active: bool = false
var _prefab_drag_moved: bool = false
var _prefab_panel_label: Label
var _prefab_selection_label: Label
var _prefab_problems_label: Label
var _prefab_budget_spin: SpinBox
var _prefab_unpack_button: Button
var _prefab_delete_button: Button
var armed_bounds: AABB = AABB()
var _ghost_check_key: String = ""
var _ghost_check_ok: bool = false
var _ghost_check_reason: String = ""
var _rmb_dragged: bool = false
var _library_dialog: FileDialog

var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _grid_mi: MeshInstance3D
var _mirror_x_mi: MeshInstance3D
var _mirror_z_mi: MeshInstance3D
var _layer_mi: MeshInstance3D
var _mesh_dirty: bool = true
# Chunked rendering: the world is split into CHUNK_SIZE^3 regions, each with
# its own MeshInstance3D, so a batch edit only rebuilds the chunks it touched.
# render_horizon additionally caps which chunks exist at all: only chunks
# within that horizontal distance of the camera are meshed, so raising it
# reveals progressively farther parts of the model. 0 means unlimited.
# The full grid is always kept and saved.
const CHUNK_SIZE: int = 64
const UNLIMITED_HORIZON: int = 1 << 30
var render_horizon: int = UNLIMITED_HORIZON
var _chunks: Dictionary = {}          # Vector2i(xz chunk) -> Dictionary(y -> {mi, dirty, cooldown})
# Chunk index over the raw grid, independent of what is currently meshed:
# _grid_chunks: chunk key -> true (chunk contains at least one voxel),
# _chunk_cells: chunk key -> Array[Vector3i] (cells ever written there; build
# filters through doc.grid, so stale keys from erases are harmless).
var _grid_chunks: Dictionary = {}
var _chunk_cells: Dictionary = {}
var _last_horizon_camera: Vector3 = Vector3(INF, 0, INF)
var _frame: int = 0
var _last_change_frame: int = -1000
var _doc_replaced: bool = false
const CHUNK_COOLDOWN: int = 48
const NAVIGATION_SPEED: float = 24.0
const NAVIGATION_FAST_MULTIPLIER: float = 4.0

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
var _stroke_mouse_driven: bool = false

# UI
var _tool_buttons: Array[Button] = []
var _color_button: ColorPickerButton
var _swatch_grid: GridContainer
var _material_buttons: Array[Button] = []
var _material_info_label: Label
var _solid_override_option: OptionButton
var _walkable_override_option: OptionButton

# --- Flipbook animation transport ---
var _anim_playing: bool = false
var _anim_time: float = 0.0
var _anim_frame_label: Label
var _anim_time_spin: SpinBox
var _anim_mode_option: OptionButton
var _anim_play_button: Button
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
var _horizon_spin: SpinBox
var _message_label: Label
var _hint_label: Label
var _file_dialog: FileDialog
var _screenshot_dialog: FileDialog
var _confirm_dialog: ConfirmationDialog
var _light_color_button: ColorPickerButton
var _light_position_spins: Array[SpinBox] = []
var _light_energy_spin: SpinBox
var _light_range_spin: SpinBox
var _light_shadows_check: CheckButton
var _light_handles_check: CheckButton
var _light_selection_label: Label
var _light_delete_button: Button
var _sun_energy_spin: SpinBox
var _sun_yaw_spin: SpinBox
var _sun_pitch_spin: SpinBox
var _sun_color_button: ColorPickerButton
var _sun_shadows_check: CheckButton
var _atmosphere_check: CheckButton
var _atmosphere_energy_spin: SpinBox
var _atmosphere_color_button: ColorPickerButton
var _mcp: MCPServer
var _ui_layer: CanvasLayer
var _capturing_screenshot: bool = false
var _pending_open: bool = false
var _pending_action: Callable = Callable()
var _syncing_ui: bool = false


func _ready() -> void:
	_build_world()
	_build_ui()
	doc.changed.connect(func() -> void:
		# Any document edit can change what a placement would overlap, so the
		# cached ghost validation must not outlive it.
		_ghost_check_key = ""
		if _doc_replaced:
			_doc_replaced = false
			_on_doc_reset()
		else:
			for p: Vector3i in doc.last_touched:
				_index_cell(p)
				_touch_chunk(p.x, p.z)
			for key: Vector2i in doc.last_touched_prefab_chunks:
				_touch_prefab_chunk(key)
		_sync_light_nodes()
		doc.last_touched.clear()
		doc.last_touched_lights.clear()
		doc.last_touched_prefab_chunks.clear()
		doc.last_touched_prefabs.clear()
		_last_change_frame = _frame
		_mesh_dirty = true
		if height_lock:
			_update_layer_plane())
	doc.meta_changed.connect(_on_meta_changed)
	doc.history_changed.connect(_refresh_history_buttons)
	doc.prefabs_changed.connect(_on_prefabs_changed)
	_on_meta_changed()
	_refresh_history_buttons()
	_set_tool(Tool.PLACE)
	_set_color(color)
	frame_model()
	_update_camera()
	# Closing the window must go through the unsaved-changes prompt.
	get_tree().set_auto_accept_quit(false)
	get_window().files_dropped.connect(_on_files_dropped)
	if MCPServer.enabled_from_env():
		_mcp = MCPServer.new()
		_mcp.editor = self
		add_child(_mcp)
		_mcp.start()
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
	# Set this BEFORE load_file so the changed signal emitted mid-load triggers
	# _on_doc_reset(), which rebuilds the chunk records for the new grid.
	_doc_replaced = true
	var err: Error = doc.load_file(p)
	if err == OK:
		if not doc.character_slots.is_empty():
			# Part-only model: the grid is empty by design, slots live on the
			# rig. Show the rig and frame it instead of the empty grid.
			_set_tool(Tool.CHARACTER)
			_frame_character_rig()
		else:
			if current_tool == Tool.CHARACTER:
				# Leaving a slot-bearing model: hide the rig, back to voxels.
				_set_tool(Tool.PLACE)
			frame_model()
		_say("Opened " + p)
	else:
		_doc_replaced = false
		_say("Open failed (%s): %s" % [error_string(err), p])


## Frames the live character rig (~1.6m tall at origin) after opening a
## slot-bearing model whose voxel grid is empty.
func _frame_character_rig() -> void:
	_yaw = deg_to_rad(218.0)
	_pitch = deg_to_rad(-12.0)
	_distance = 3.5
	_focus = Vector3(0, 0.8, 0)
	doc.set_sun({"yaw": 218.0, "pitch": -50.0, "energy": 1.2})
	_update_camera()


# --- World construction ---

func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.12, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = VoxelDocument.DEFAULT_ATMOSPHERE_COLOR
	# Keep a small constant ambient floor so unlit faces never go pitch black;
	# the scene's mood comes from the directional sun (see _apply_environment).
	env.ambient_light_energy = VoxelDocument.DEFAULT_ATMOSPHERE_ENERGY
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	world_environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(VoxelDocument.DEFAULT_SUN_PITCH, VoxelDocument.DEFAULT_SUN_YAW, 0.0)
	sun.light_energy = VoxelDocument.DEFAULT_SUN_ENERGY
	sun.shadow_enabled = true
	add_child(sun)
	self.sun = sun
	light_rig = VoxelLightRig.new()
	light_rig.name = "VoxelLights"
	add_child(light_rig)

	prefab_rig = VoxelPrefabRig.new()
	prefab_rig.name = "PrefabRig"
	add_child(prefab_rig)

	character_rig = VoxelCharacterRig.new()
	character_rig.name = "CharacterRig"
	add_child(character_rig)
	character_rig.visible = false

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.far = 1000.0
	camera.near = 0.05
	camera.current = true
	add_child(camera)

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
	_layer_mi = MeshInstance3D.new()
	_layer_mi.name = "WorkLayer"
	_layer_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_layer_mi.visible = false
	add_child(_layer_mi)


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


## Draws the work layer as a golden slice grid over the model's footprint.
## Lines instead of a filled sheet, so what is underneath stays readable.
func _update_layer_plane() -> void:
	var b: Vector3i = doc.bounds
	work_layer = clampi(work_layer, 0, b.y - 1)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p: Vector3i in doc.grid:
		lo = lo.min(Vector3(p))
		hi = hi.max(Vector3(p) + Vector3.ONE)
	if doc.grid.is_empty():
		lo = Vector3.ZERO
		hi = Vector3(b)
	var x0: int = floori(lo.x)
	var x1: int = ceili(hi.x)
	var z0: int = floori(lo.z)
	var z1: int = ceili(hi.z)
	var y: float = float(work_layer) + 0.002
	var minor := Color(1.0, 0.72, 0.25, 0.30)
	var major := Color(1.0, 0.86, 0.48, 0.65)
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for x in range(x0, x1 + 1):
		var c: Color = major if x % 8 == 0 else minor
		verts.append(Vector3(x, y, z0))
		verts.append(Vector3(x, y, z1))
		cols.append(c)
		cols.append(c)
	for z in range(z0, z1 + 1):
		var c: Color = major if z % 8 == 0 else minor
		verts.append(Vector3(x0, y, z))
		verts.append(Vector3(x1, y, z))
		cols.append(c)
		cols.append(c)
	var border := Color(1.0, 0.78, 0.22, 0.95)
	for pair: Array in [
		[Vector3(x0, y, z0), Vector3(x1, y, z0)],
		[Vector3(x0, y, z1), Vector3(x1, y, z1)],
		[Vector3(x0, y, z0), Vector3(x0, y, z1)],
		[Vector3(x1, y, z0), Vector3(x1, y, z1)],
	]:
		verts.append(pair[0])
		verts.append(pair[1])
		cols.append(border)
		cols.append(border)
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
	_layer_mi.mesh = mesh
	_layer_mi.visible = height_lock


func _rebuild_mesh() -> void:
	_mesh_dirty = false
	_mark_all_chunks_dirty()
	_update_dirty_chunks()


## Chunk key for a world cell.
func _chunk_key(p: Vector3i) -> Vector2i:
	return Vector2i(p.x / CHUNK_SIZE, p.z / CHUNK_SIZE)


## Marks the chunk containing (x, z) dirty; creates the chunk record if new.
## Chunks entirely beyond the render horizon (measured from the camera focus)
## are skipped entirely (0 = all).
func _touch_chunk(x: int, z: int) -> void:
	var key := _chunk_key(Vector3i(x, 0, z))
	if not _chunk_within_horizon(key):
		return # chunk center is beyond the horizon
	var col: Dictionary = _chunks.get_or_add(key, {})
	var rec: Dictionary = col.get_or_add(0, {"mi": null, "dirty": true, "cooldown": -100000})
	rec["dirty"] = true
	col[0] = rec
	_mesh_dirty = true


## True when the chunk is within the render horizon of the camera. The
## distance is horizontal (chunks are full-height columns) and measured from
## the camera, so raising the horizon always reveals farther chunks and never
## pops in parts that were already closer to the viewer. Unlimited always
## passes.
func _chunk_within_horizon(key: Vector2i) -> bool:
	if render_horizon >= UNLIMITED_HORIZON:
		return true
	var center := Vector2(key.x * CHUNK_SIZE + CHUNK_SIZE * 0.5,
		key.y * CHUNK_SIZE + CHUNK_SIZE * 0.5)
	var cam := Vector2(camera.global_position.x, camera.global_position.z)
	return center.distance_to(cam) <= float(render_horizon)


## Adds a cell to the chunk-cell index so rebuilds never rescan the full grid.
## Erases need no index update: builds filter through doc.grid.
func _index_cell(p: Vector3i) -> void:
	var key := _chunk_key(p)
	if not _grid_chunks.has(key):
		_grid_chunks[key] = true
		_chunk_cells[key] = [] as Array[Vector3i]
	var cells: Array[Vector3i] = _chunk_cells[key]
	if not cells.has(p):
		cells.append(p)


## Registers and dirties a column that may contain only linked prefab cells
## (no local voxels), so prefab-only chunks still get a mesh.
func _touch_prefab_chunk(key: Vector2i) -> void:
	if not _grid_chunks.has(key):
		_grid_chunks[key] = true
		if not _chunk_cells.has(key):
			_chunk_cells[key] = [] as Array[Vector3i]
	_touch_chunk(key.x * CHUNK_SIZE, key.y * CHUNK_SIZE)


func _mark_all_chunks_dirty() -> void:
	for key: Vector2i in _chunks:
		for cy: int in _chunks[key]:
			_chunks[key][cy]["dirty"] = true
	_mesh_dirty = true


## Rebuilds dirty chunk meshes. During heavy streaming (recent writes) each
## chunk rebuilds at most once per CHUNK_COOLDOWN frames so the editor keeps
## rendering; idle edits rebuild immediately.
func _update_dirty_chunks() -> void:
	var streaming: bool = _frame - _last_change_frame < 30
	var rebuilt_any: bool = false
	for key: Vector2i in _chunks:
		var col: Dictionary = _chunks[key]
		for cy: int in col:
			var rec: Dictionary = col[cy]
			if not rec["dirty"]:
				continue
			# While batches stream in, rebuild each chunk at most once per
			# cooldown window so the editor keeps rendering; never built yet
			# (mi == null) builds immediately.
			var mi: MeshInstance3D = rec["mi"]
			if mi != null and streaming and _frame - int(rec["cooldown"]) < CHUNK_COOLDOWN:
				continue
			_build_chunk_mesh(key, col, cy, rec)
			rebuilt_any = true
	if rebuilt_any:
		_update_status()
	if not streaming:
		_mesh_dirty = false
	else:
		for key: Vector2i in _chunks:
			for cy: int in _chunks[key]:
				if _chunks[key][cy]["dirty"]:
					return
		_mesh_dirty = false


## Extracts the chunk's voxels from the chunk-cell index (no full-grid scan)
## and meshes them. Stale cells (erased since indexing) are simply absent from
## doc.grid, so they are skipped naturally.
func _build_chunk_mesh(key: Vector2i, col: Dictionary, _cy: int, rec: Dictionary) -> void:
	rec["dirty"] = false
	rec["cooldown"] = _frame
	var cells := {}
	for p: Vector3i in (_chunk_cells.get(key, []) as Array):
		if doc.grid.has(p):
			cells[p] = doc.grid[p]
	# Linked prefab cells merge before meshing so faces between a local voxel
	# and an adjacent instance cell are culled like any other neighbour.
	var prefab_colors: Dictionary = doc.prefab_composition.colors_in_column(key)
	for p: Vector3i in prefab_colors:
		cells[p] = prefab_colors[p]
	var mesh: ArrayMesh = VoxelMeshBuilder.build_mesh(cells, 1.0)
	var mi: MeshInstance3D = rec["mi"]
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "Chunk%d_%d" % [key.x, key.y]
		rec["mi"] = mi
		add_child(mi)
	mi.mesh = mesh
	col[_cy] = rec


func _on_doc_reset() -> void:
	selected_light_id = -1
	_drag_light_id = -1
	_light_edit_active = false
	_stroking = false
	selected_prefab_id = -1
	_drag_prefab_id = -1
	_prefab_drag_active = false
	_anim_playing = false
	_anim_bounce_back = false
	_anim_time = 0.0
	# An armed catalogue asset survives open/new: the user may be building a
	# scene from several models. Its source is independent of the document.
	_sync_light_nodes()
	_sync_prefab_rig()
	_apply_environment()
	_clear_chunks()
	_rebuild_chunks_from_grid()
	_mesh_dirty = true
	_refresh_prefab_ui()
	_refresh_animation_ui()


## Applies the sun saved in the document to the scene. Called on load/reset so
## a lit scene reopens as authored.
func _apply_environment() -> void:
	sun.light_energy = doc.sun_energy
	sun.light_color = doc.sun_color
	sun.shadow_enabled = doc.sun_shadows
	sun.rotation_degrees = Vector3(doc.sun_pitch, doc.sun_yaw, 0.0)
	sun.visible = doc.sun_energy > 0.001
	world_environment.ambient_light_color = doc.atmosphere_color
	world_environment.ambient_light_energy = doc.atmosphere_energy if doc.atmosphere_enabled else 0.0
	# The engine default (100 m) clips shadows out of large scenes: a 512^3
	# pagoda viewed from 390 m cast none. Cover the whole editable volume, but
	# cap at the camera far plane so the shadow map is not wasted off-screen.
	var shadow_distance: float = maxf(100.0, Vector3(doc.bounds).length() * 1.5)
	sun.directional_shadow_max_distance = minf(shadow_distance, camera.far)
	_sync_sun_ui()
	_sync_atmosphere_ui()


## Rebuilds the chunk-cell index from the raw grid and derives chunk records
## (after load/reset/horizon change): one record per touched 64x64 region whose
## center is within the horizon of the camera focus.
func _rebuild_chunks_from_grid() -> void:
	_grid_chunks = {}
	_chunk_cells = {}
	for p: Vector3i in doc.grid:
		var key := _chunk_key(p)
		if not _grid_chunks.has(key):
			_grid_chunks[key] = true
			_chunk_cells[key] = [] as Array[Vector3i]
		(_chunk_cells[key] as Array[Vector3i]).append(p)
	# Prefab-only columns have no local cells but still need a chunk record.
	for key: Vector2i in doc.prefab_composition.column_keys():
		_grid_chunks[key] = true
		if not _chunk_cells.has(key):
			_chunk_cells[key] = [] as Array[Vector3i]
	for key: Vector2i in _grid_chunks:
		_touch_chunk(key.x * CHUNK_SIZE, key.y * CHUNK_SIZE)


## Sets how far from the camera the renderer meshes (chunks whose center is
## farther are freed). 0 means unlimited. Shared by the UI spinbox and MCP.
## The meshed set follows the camera as it orbits, pans, zooms or flies.
func set_render_horizon(horizon: int) -> void:
	render_horizon = UNLIMITED_HORIZON if horizon <= 0 else horizon
	_last_horizon_camera = Vector3(INF, 0, INF) # force re-evaluation below
	if render_horizon >= UNLIMITED_HORIZON:
		# Back to unlimited: re-mesh everything that a previous cap dropped.
		for key: Vector2i in _grid_chunks:
			if not _chunks.has(key):
				_touch_chunk(key.x * CHUNK_SIZE, key.y * CHUNK_SIZE)
		return
	_update_horizon_chunks()


## Rebuilds the meshed chunk set around the current camera position. Cheap
## when the horizon is unlimited or the camera barely moved.
func _update_horizon_chunks() -> void:
	if render_horizon >= UNLIMITED_HORIZON:
		return
	var cam: Vector3 = camera.global_position
	if Vector2(cam.x - _last_horizon_camera.x, cam.z - _last_horizon_camera.z).length() < CHUNK_SIZE * 0.25:
		return
	_last_horizon_camera = cam
	# Add newly in-range chunks, free those that left the radius.
	for key: Vector2i in _grid_chunks:
		if _chunk_within_horizon(key) and not _chunks.has(key):
			_touch_chunk(key.x * CHUNK_SIZE, key.y * CHUNK_SIZE)
	var dropped: Array[Vector2i] = []
	for key: Vector2i in _chunks:
		if not _chunk_within_horizon(key):
			dropped.append(key)
	for key: Vector2i in dropped:
		var col: Dictionary = _chunks[key]
		for cy: int in col:
			var mi: MeshInstance3D = col[cy]["mi"]
			if mi != null:
				mi.queue_free()
		_chunks.erase(key)


func _clear_chunks() -> void:
	for key: Vector2i in _chunks:
		for cy: int in _chunks[key]:
			var rec: Dictionary = _chunks[key][cy]
			var mi: MeshInstance3D = rec["mi"]
			if mi != null:
				mi.queue_free()
	_chunks = {}


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


## Sets the directional sun (any of energy/yaw/pitch/color/shadows) and saves
## it with the model. Shared by the Lighting panel and MCP.
func set_sun_properties(properties: Dictionary) -> void:
	doc.set_sun(properties)
	_apply_environment()


## Sets the atmospheric/ambient fill light and saves it with the model.
func set_atmosphere_properties(properties: Dictionary) -> void:
	doc.set_atmosphere(properties)
	_apply_environment()


func _orbit(delta: Vector2) -> void:
	_yaw -= delta.x * 0.005
	_pitch = clampf(_pitch - delta.y * 0.005, deg_to_rad(-89.0), deg_to_rad(20.0))


func _pan(delta: Vector2) -> void:
	var rot := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	var k: float = _distance * 0.0016
	_focus += (-rot.x * delta.x + rot.y * delta.y) * k


## Camera-relative flight: WASD follows the view horizontally, Space/C moves
## vertically. Speed follows the zoom distance so large models stay navigable.
func _update_navigation(delta: float) -> void:
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus != null and (focus is LineEdit or focus is TextEdit):
		return
	if Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_META):
		return
	var axis := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_SPACE)) - float(Input.is_physical_key_pressed(KEY_C)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if axis.is_zero_approx():
		return
	var rot: Basis = camera.global_transform.basis
	var right: Vector3 = rot.x
	var forward := Vector3(-rot.z.x, 0.0, -rot.z.z).normalized()
	var direction: Vector3 = right * axis.x + forward * -axis.z + Vector3.UP * axis.y
	if direction.is_zero_approx():
		return
	var speed: float = NAVIGATION_SPEED * maxf(_distance / 60.0, 0.1)
	if Input.is_physical_key_pressed(KEY_SHIFT):
		speed *= NAVIGATION_FAST_MULTIPLIER
	_focus += direction.normalized() * speed * delta


# --- Per-frame ---

func _process(delta: float) -> void:
	_frame += 1
	_update_navigation(delta)
	if _mesh_dirty:
		_update_dirty_chunks()
	_update_camera()
	_update_horizon_chunks()
	_tick_animation(delta)
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var origin: Vector3 = camera.project_ray_origin(mouse)
	var dir: Vector3 = camera.project_ray_normal(mouse)

	if _stroking:
		# Light drags live on a camera-facing plane; voxel strokes keep their
		# original face-locked plane and polling behavior.
		if _light_edit_active:
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				_stroke_mouse_driven = true
				_drag_light_to_screen(mouse)
			elif _stroke_mouse_driven:
				_finish_light_drag()
			return
		# via the MCP API (no button held) end through end_stroke instead.
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_stroke_mouse_driven = true
			_update_stroke(origin, dir)
			_update_ghost()
		elif _stroke_mouse_driven:
			_finish_stroke()
		return

	var camera_drag: bool = (Input.get_mouse_button_mask() & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0
	if get_viewport().gui_get_hovered_control() != null or camera_drag:
		_hover = {"valid": false}
	else:
		_hover = _compute_hover(origin, dir)
	_update_ghost()


func _compute_hover(origin: Vector3, dir: Vector3) -> Dictionary:
	var info: Dictionary = {"valid": false}
	var r: Dictionary = VoxelRaycast.cast_composed(doc.grid, doc.prefab_composition,
		doc.bounds, origin, dir)
	var placing: bool = current_tool == Tool.PREFAB and armed_source != null
	var adds: bool = current_tool == Tool.PLACE or current_tool == Tool.BOX \
		or current_tool == Tool.LIGHT_PLACE or placing
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
		info["prefab_id"] = int(r.get("prefab_id", 0))
		info["color"] = r.get("color", Color.WHITE)
	elif r["floor"] and adds:
		info["valid"] = true
		info["cell"] = r["pos"]
		info["normal"] = Vector3i.UP
		info["face_coord"] = 0.0
		info["prefab_id"] = 0
		info["color"] = Color.WHITE
	elif current_tool == Tool.PREFAB and not placing and prefab_rig != null:
		# Missing/conflicted/incompatible instances have no solid cells, so
		# fall back to their placeholder boxes for selection.
		var pid: int = prefab_rig.pick_placeholder(doc, origin, dir)
		if pid > 0:
			info["valid"] = true
			info["cell"] = Vector3i.ZERO
			info["normal"] = Vector3i.UP
			info["face_coord"] = 0.0
			info["prefab_id"] = pid
			info["placeholder"] = true
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
	if _anim_playing:
		_say("Stop playback (Animation section) before painting")
		return
	var cell: Vector3i = h["cell"]
	if current_tool == Tool.PREFAB:
		_begin_prefab_action(h)
		return
	if current_tool == Tool.LIGHT_PLACE:
		var p := Vector3(cell) + Vector3.ONE * 0.5
		var id: int = add_point_light(p, Color("ffd9a0"))
		_say("Added point light %d" % id if id >= 0 else "Light limit or bounds reached")
		return
	if current_tool == Tool.LIGHT_EDIT:
		var screen: Vector2 = get_viewport().get_mouse_position()
		var id: int = light_rig.pick(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
		if id >= 0:
			_begin_light_drag(id)
		else:
			_select_light(-1)
		return
	match current_tool:
		Tool.PICK:
			# Pick may sample linked content; it never selects or unpacks.
			if doc.grid.has(cell):
				_set_material(doc.material_at(cell))
				var local_bits: int = doc.material_override_at(cell)
				_set_material_overrides(VoxelMaterial.solid_override(local_bits),
					VoxelMaterial.walkable_override(local_bits))
				_set_color(doc.grid[cell])
			elif doc.prefab_composition.has_cell(cell):
				_set_material(doc.prefab_composition.material_at(cell))
				var linked_bits: int = doc.prefab_composition.override_at(cell)
				_set_material_overrides(VoxelMaterial.solid_override(linked_bits),
					VoxelMaterial.walkable_override(linked_bits))
				_set_color(doc.prefab_composition.color_at(cell))
			return
		Tool.FILL:
			if doc.prefab_composition.has_cell(cell):
				_say("Linked prefab: unpack to edit")
				return
			doc.paint_cells(doc.flood_cells(cell), color)
			return
		Tool.ERASE, Tool.PAINT, Tool.MATERIAL:
			if doc.prefab_composition.has_cell(cell):
				_say("Linked prefab: unpack to edit")
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
			doc.place_cells(one, color, current_material, current_material_overrides)
		Tool.ERASE:
			doc.erase_cells(one)
		Tool.PAINT:
			doc.paint_cells(one, color)
		Tool.MATERIAL:
			doc.paint_material(one, current_material, current_material_overrides)


func _update_stroke(origin: Vector3, dir: Vector3) -> void:
	if _stroke_tool == Tool.PREFAB:
		_update_prefab_drag(origin, dir)
		return
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
	if _stroke_tool == Tool.PREFAB:
		_finish_prefab_drag()
		return
	if _is_box_tool(_stroke_tool):
		var ext: Array[Vector3i] = _box_extent()
		var cells: Array[Vector3i] = VoxelDocument.box_cells(ext[0], ext[1])
		if _box_has_linked_cells(cells):
			# All-or-nothing for both Box and Box Erase: linked instances are
			# atomic, so a region that touches one is refused as a whole.
			_say("Linked prefab: unpack to edit")
			doc.end_stroke()
			_stroking = false
			_stroke_mouse_driven = false
			_last_cell = Vector3i(-1, -1, -1)
			return
		if _stroke_tool == Tool.BOX:
			doc.place_cells(cells, color, current_material, current_material_overrides)
		else:
			doc.erase_cells(cells)
	doc.end_stroke()
	_stroking = false
	_stroke_mouse_driven = false
	_last_cell = Vector3i(-1, -1, -1)


## True when the current box extent, including mirrored copies, contains any
## linked prefab cell.
func _box_has_linked_cells(cells: Array[Vector3i] = []) -> bool:
	var list: Array[Vector3i] = cells
	if list.is_empty():
		var ext: Array[Vector3i] = _box_extent()
		list = VoxelDocument.box_cells(ext[0], ext[1])
	for p: Vector3i in list:
		for q: Vector3i in doc.mirrored(p):
			if doc.prefab_composition.has_cell(q):
				return true
	return false


# --- Point-light editing ---

func _sync_light_nodes() -> void:
	if light_rig == null:
		return
	if selected_light_id >= 0 and not doc.lights.has(selected_light_id):
		selected_light_id = -1
	light_rig.sync(doc.lights, selected_light_id)
	_sync_light_ui()


func _select_light(id: int) -> bool:
	if id >= 0 and not doc.lights.has(id):
		return false
	selected_light_id = id
	if id >= 0 and selected_prefab_id >= 0:
		# One selection at a time, so Delete is unambiguous.
		selected_prefab_id = -1
		_sync_prefab_rig()
	_sync_light_nodes()
	return true


## Steps through the lights in ID order; direction -1 or +1. Selects the first
## (or last) light when nothing is selected. Returns the new selection.
func cycle_light(direction: int) -> int:
	if doc.lights.is_empty():
		return -1
	var ids: Array = doc.lights.keys()
	ids.sort()
	if selected_light_id < 0:
		_select_light(ids[0] if direction >= 0 else ids[ids.size() - 1])
		return selected_light_id
	# Find the current position and wrap around at the ends.
	var at: int = ids.find(selected_light_id)
	if at == -1:
		_select_light(ids[0])
		return selected_light_id
	var next: int = wrapi(at + (1 if direction >= 0 else -1), 0, ids.size())
	_select_light(ids[next])
	return selected_light_id


func add_point_light(position: Vector3, c: Color = Color("ffd9a0"), energy: float = VoxelDocument.LIGHT_DEFAULT_ENERGY, range_value: float = VoxelDocument.LIGHT_DEFAULT_RANGE, shadows: bool = true) -> int:
	var id: int = doc.add_light({"position": position, "color": c, "energy": energy, "range": range_value, "shadows": shadows})
	if id >= 0:
		selected_light_id = id
		_sync_light_nodes()
	return id


func update_point_light(id: int, properties: Dictionary) -> bool:
	doc.begin_stroke()
	var changed: bool = doc.update_light(id, properties)
	doc.end_stroke()
	if changed:
		_sync_light_nodes()
	return changed


func remove_point_light(id: int) -> bool:
	if not doc.lights.has(id):
		return false
	doc.begin_stroke()
	var changed: bool = doc.remove_light(id)
	doc.end_stroke()
	if changed:
		_sync_light_nodes()
	return changed


func _begin_light_drag(id: int) -> void:
	if id < 0 or not doc.lights.has(id):
		return
	_select_light(id)
	_drag_light_id = id
	_drag_light_plane = Plane(camera.global_basis.z, doc.lights[id]["position"])
	doc.begin_stroke()
	_light_edit_active = true
	_stroking = true
	_stroke_tool = Tool.LIGHT_EDIT
	_stroke_mouse_driven = false


func _drag_light_to_screen(screen: Vector2) -> void:
	if _drag_light_id < 0 or not doc.lights.has(_drag_light_id):
		return
	var origin: Vector3 = camera.project_ray_origin(screen)
	var dir: Vector3 = camera.project_ray_normal(screen)
	var hit: Variant = _drag_light_plane.intersects_ray(origin, dir)
	if hit != null:
		doc.update_light(_drag_light_id, {"position": hit})
		_sync_light_nodes()


func _finish_light_drag() -> void:
	doc.end_stroke()
	_light_edit_active = false
	_stroking = false
	_stroke_mouse_driven = false
	_drag_light_id = -1


func _sync_light_ui() -> void:
	if _light_selection_label == null:
		return
	var valid: bool = doc.lights.has(selected_light_id)
	_syncing_ui = true
	_light_selection_label.text = "Light %d / %d" % [selected_light_id, doc.lights.size()] if valid else "%d lights" % doc.lights.size()
	for spin: SpinBox in _light_position_spins:
		spin.editable = valid
	_light_energy_spin.editable = valid
	_light_range_spin.editable = valid
	_light_color_button.disabled = not valid
	_light_shadows_check.disabled = not valid
	_light_delete_button.disabled = not valid
	if valid:
		var l: Dictionary = doc.lights[selected_light_id]
		var p: Vector3 = l["position"]
		for i in 3:
			_light_position_spins[i].value = p[i]
		_light_color_button.color = l["color"]
		_light_energy_spin.value = l["energy"]
		_light_range_spin.value = l["range"]
		_light_shadows_check.set_pressed_no_signal(l["shadows"])
	_syncing_ui = false


func _update_selected_light(properties: Dictionary) -> void:
	if _syncing_ui or selected_light_id < 0:
		return
	if not update_point_light(selected_light_id, properties):
		_say("Light is outside the model bounds")
		_sync_light_ui()


func _update_selected_light_position(_value: float = 0.0) -> void:
	if _syncing_ui or selected_light_id < 0:
		return
	var p := Vector3(_light_position_spins[0].value, _light_position_spins[1].value, _light_position_spins[2].value)
	_update_selected_light({"position": p})


func _build_sun_ui(parent: VBoxContainer) -> void:
	var body := _section(parent, "Sun (directional)")
	var sun_energy_row := HBoxContainer.new()
	body.add_child(sun_energy_row)
	sun_energy_row.add_child(_label("Energy"))
	_sun_energy_spin = _spin(0, VoxelDocument.MAX_SUN_ENERGY, 0.05, VoxelDocument.DEFAULT_SUN_ENERGY)
	_sun_energy_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			set_sun_properties({"energy": v}))
	sun_energy_row.add_child(_sun_energy_spin)
	var sun_angle_row := HBoxContainer.new()
	body.add_child(sun_angle_row)
	sun_angle_row.add_child(_label("Yaw"))
	_sun_yaw_spin = _spin(-180, 180, 1, VoxelDocument.DEFAULT_SUN_YAW)
	_sun_yaw_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			set_sun_properties({"yaw": v}))
	sun_angle_row.add_child(_sun_yaw_spin)
	sun_angle_row.add_child(_label("Pitch"))
	_sun_pitch_spin = _spin(VoxelDocument.SUN_PITCH_MIN, VoxelDocument.SUN_PITCH_MAX, 1, VoxelDocument.DEFAULT_SUN_PITCH)
	_sun_pitch_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			set_sun_properties({"pitch": v}))
	sun_angle_row.add_child(_sun_pitch_spin)
	_sun_color_button = ColorPickerButton.new()
	_sun_color_button.edit_alpha = false
	_sun_color_button.custom_minimum_size = Vector2(0, 28)
	_sun_color_button.color = Color(1, 1, 1)
	_sun_color_button.color_changed.connect(func(c: Color) -> void:
		if not _syncing_ui:
			set_sun_properties({"color": c}))
	body.add_child(_sun_color_button)
	_sun_shadows_check = CheckButton.new()
	_sun_shadows_check.text = "Sun casts shadows"
	_sun_shadows_check.button_pressed = true
	_sun_shadows_check.focus_mode = Control.FOCUS_NONE
	_sun_shadows_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			set_sun_properties({"shadows": on}))
	body.add_child(_sun_shadows_check)
	_sync_sun_ui()


func _build_atmosphere_ui(parent: VBoxContainer) -> void:
	var body := _section(parent, "Atmosphere")
	_atmosphere_check = CheckButton.new()
	_atmosphere_check.text = "Atmospheric light"
	_atmosphere_check.focus_mode = Control.FOCUS_NONE
	_atmosphere_check.tooltip_text = "Ambient fill light that lifts unlit faces; independent of the Sun"
	_atmosphere_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			set_atmosphere_properties({"enabled": on}))
	body.add_child(_atmosphere_check)
	var energy_row := HBoxContainer.new()
	body.add_child(energy_row)
	energy_row.add_child(_label("Energy"))
	_atmosphere_energy_spin = _spin(0, VoxelDocument.MAX_ATMOSPHERE_ENERGY, 0.01,
		VoxelDocument.DEFAULT_ATMOSPHERE_ENERGY)
	_atmosphere_energy_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			set_atmosphere_properties({"energy": v}))
	energy_row.add_child(_atmosphere_energy_spin)
	_atmosphere_color_button = ColorPickerButton.new()
	_atmosphere_color_button.edit_alpha = false
	_atmosphere_color_button.custom_minimum_size = Vector2(0, 28)
	_atmosphere_color_button.color = VoxelDocument.DEFAULT_ATMOSPHERE_COLOR
	_atmosphere_color_button.color_changed.connect(func(c: Color) -> void:
		if not _syncing_ui:
			set_atmosphere_properties({"color": c}))
	body.add_child(_atmosphere_color_button)
	_sync_atmosphere_ui()


func _sync_atmosphere_ui() -> void:
	if _atmosphere_check == null:
		return
	_syncing_ui = true
	_atmosphere_check.set_pressed_no_signal(doc.atmosphere_enabled)
	_atmosphere_energy_spin.value = doc.atmosphere_energy
	_atmosphere_color_button.color = doc.atmosphere_color
	_atmosphere_energy_spin.editable = doc.atmosphere_enabled
	_atmosphere_color_button.disabled = not doc.atmosphere_enabled
	_syncing_ui = false


func _build_light_ui(parent: VBoxContainer) -> void:
	# Point lights are the tallest section, so they start collapsed.
	var body := _section(parent, "Lighting — point lights", false)
	_light_handles_check = CheckButton.new()
	_light_handles_check.text = "Show light handles"
	_light_handles_check.button_pressed = true
	_light_handles_check.focus_mode = Control.FOCUS_NONE
	_light_handles_check.toggled.connect(func(on: bool) -> void:
		light_rig.handles_visible = on)
	body.add_child(_light_handles_check)
	# < Light 3/9 > [Delete] — cycle through lights and remove the current one.
	var cycle_row := HBoxContainer.new()
	cycle_row.add_theme_constant_override("separation", 4)
	body.add_child(cycle_row)
	var prev_button := _button("<", func() -> void: cycle_light(-1))
	prev_button.custom_minimum_size = Vector2(26, 26)
	prev_button.tooltip_text = "Select the previous light"
	cycle_row.add_child(prev_button)
	_light_selection_label = _label("0 lights")
	_light_selection_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_light_selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cycle_row.add_child(_light_selection_label)
	var next_button := _button(">", func() -> void: cycle_light(1))
	next_button.custom_minimum_size = Vector2(26, 26)
	next_button.tooltip_text = "Select the next light"
	cycle_row.add_child(next_button)
	_light_delete_button = _button("Delete", func() -> void: remove_point_light(selected_light_id))
	_light_delete_button.custom_minimum_size = Vector2(64, 26)
	_light_delete_button.tooltip_text = "Delete the selected light (Delete key)"
	cycle_row.add_child(_light_delete_button)
	var pos_row := HBoxContainer.new()
	body.add_child(pos_row)
	for axis: String in ["X", "Y", "Z"]:
		pos_row.add_child(_label(axis))
		var spin: SpinBox = _spin(0, 1024, 0.1, 0)
		spin.value_changed.connect(_update_selected_light_position)
		_light_position_spins.append(spin)
		pos_row.add_child(spin)
	var energy_row := HBoxContainer.new()
	body.add_child(energy_row)
	energy_row.add_child(_label("Energy"))
	_light_energy_spin = _spin(0, VoxelDocument.LIGHT_MAX_ENERGY, 0.05, 1.0)
	_light_energy_spin.value_changed.connect(func(v: float) -> void: _update_selected_light({"energy": v}))
	energy_row.add_child(_light_energy_spin)
	var range_row := HBoxContainer.new()
	body.add_child(range_row)
	range_row.add_child(_label("Radius"))
	_light_range_spin = _spin(VoxelDocument.LIGHT_MIN_RANGE, VoxelDocument.LIGHT_MAX_RANGE, 0.25, VoxelDocument.LIGHT_DEFAULT_RANGE)
	_light_range_spin.value_changed.connect(func(v: float) -> void: _update_selected_light({"range": v}))
	range_row.add_child(_light_range_spin)
	_light_color_button = ColorPickerButton.new()
	_light_color_button.edit_alpha = false
	_light_color_button.custom_minimum_size = Vector2(0, 28)
	_light_color_button.color = Color("ffd9a0")
	_light_color_button.color_changed.connect(func(c: Color) -> void: _update_selected_light({"color": c}))
	body.add_child(_light_color_button)
	_light_shadows_check = CheckButton.new()
	_light_shadows_check.text = "Cast shadows"
	_light_shadows_check.button_pressed = true
	_light_shadows_check.toggled.connect(func(on: bool) -> void: _update_selected_light({"shadows": on}))
	body.add_child(_light_shadows_check)
	_sync_sun_ui()
	_sync_light_ui()


func _sync_sun_ui() -> void:
	if _sun_energy_spin == null:
		return
	_syncing_ui = true
	_sun_energy_spin.value = doc.sun_energy
	_sun_yaw_spin.value = doc.sun_yaw
	_sun_pitch_spin.value = doc.sun_pitch
	_sun_color_button.color = doc.sun_color
	_sun_shadows_check.set_pressed_no_signal(doc.sun_shadows)
	_syncing_ui = false


func _build_material_ui(parent: VBoxContainer) -> void:
	var body := _section(parent, "Material")
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 3)
	grid.add_theme_constant_override("v_separation", 3)
	body.add_child(grid)
	for i in VoxelMaterial.count():
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(52, 26)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.text = VoxelMaterial.display_name(i)
		b.add_theme_font_size_override("font_size", 10)
		var tags_text: String = ", ".join(VoxelMaterial.tags(i))
		b.tooltip_text = "%s\nSolid: %s · Walkable: %s\nTags: %s" % [
			VoxelMaterial.display_name(i),
			"yes" if VoxelMaterial.base_solid(i) else "no",
			"yes" if VoxelMaterial.base_walkable(i) else "no", tags_text]
		var c: Color = VoxelMaterial.color(i)
		var text_color: Color = Color.WHITE if c.get_luminance() < 0.55 else Color(0.08, 0.08, 0.1)
		b.add_theme_color_override("font_color", text_color)
		b.add_theme_color_override("font_pressed_color", text_color)
		b.add_theme_color_override("font_hover_color", text_color)
		for state: String in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = c if state != "hover" else c.lightened(0.18)
			sb.set_border_width_all(1)
			sb.border_color = Color(0, 0, 0, 0.6) if state != "focus" else Color.WHITE
			b.add_theme_stylebox_override(state, sb)
		b.pressed.connect(_set_material.bind(i))
		grid.add_child(b)
		_material_buttons.append(b)
	_material_info_label = Label.new()
	_material_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_material_info_label.add_theme_font_size_override("font_size", 12)
	body.add_child(_material_info_label)
	var solid_row := HBoxContainer.new()
	body.add_child(solid_row)
	solid_row.add_child(_label("Solid"))
	_solid_override_option = OptionButton.new()
	_solid_override_option.focus_mode = Control.FOCUS_NONE
	_solid_override_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_solid_override_option.add_item("Material default", VoxelMaterial.Override.INHERIT)
	_solid_override_option.add_item("Solid", VoxelMaterial.Override.ON)
	_solid_override_option.add_item("Non-solid", VoxelMaterial.Override.OFF)
	_solid_override_option.item_selected.connect(func(_i: int) -> void: _on_material_override_changed())
	solid_row.add_child(_solid_override_option)
	var walkable_row := HBoxContainer.new()
	body.add_child(walkable_row)
	walkable_row.add_child(_label("Walkable"))
	_walkable_override_option = OptionButton.new()
	_walkable_override_option.focus_mode = Control.FOCUS_NONE
	_walkable_override_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_walkable_override_option.add_item("Material default", VoxelMaterial.Override.INHERIT)
	_walkable_override_option.add_item("Walkable", VoxelMaterial.Override.ON)
	_walkable_override_option.add_item("Not walkable", VoxelMaterial.Override.OFF)
	_walkable_override_option.item_selected.connect(func(_i: int) -> void: _on_material_override_changed())
	walkable_row.add_child(_walkable_override_option)
	var note := Label.new()
	note.text = "Place uses the active material. Material repaints existing voxels."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color(0.65, 0.7, 0.8))
	body.add_child(note)
	_sync_material_ui()


func _sync_material_ui() -> void:
	if _material_info_label == null:
		return
	_syncing_ui = true
	for i in _material_buttons.size():
		_material_buttons[i].set_pressed_no_signal(i == current_material)
	var solid: bool = VoxelMaterial.is_solid(current_material, current_material_overrides)
	var walkable: bool = VoxelMaterial.is_walkable(current_material, current_material_overrides)
	var tags: PackedStringArray = VoxelMaterial.tags(current_material)
	var override_note: String = ""
	if VoxelMaterial.solid_override(current_material_overrides) != VoxelMaterial.Override.INHERIT \
			or VoxelMaterial.walkable_override(current_material_overrides) != VoxelMaterial.Override.INHERIT:
		override_note = " (overridden)"
	_material_info_label.text = "%s · %s · %s%s\nTags: %s" % [
		VoxelMaterial.display_name(current_material),
		"solid" if solid else "non-solid",
		"walkable" if walkable else "not walkable",
		override_note, ", ".join(tags)]
	_solid_override_option.select(_solid_override_option.get_item_index(
		VoxelMaterial.solid_override(current_material_overrides)))
	_walkable_override_option.select(_walkable_override_option.get_item_index(
		VoxelMaterial.walkable_override(current_material_overrides)))
	_syncing_ui = false


func _build_animation_ui(parent: VBoxContainer) -> void:
	var body := _section(parent, "Animation")
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 4)
	body.add_child(nav)
	for entry: Array in [["|◀", -100], ["<", -1], [">", 1], [">|", 100]]:
		var label_text: String = entry[0]
		var step: int = entry[1]
		var b := _button(label_text, func() -> void: _anim_step(step))
		b.tooltip_text = "Go to first/prev/next/last frame"
		b.custom_minimum_size = Vector2(40, 0)
		nav.add_child(b)
	_anim_frame_label = _label("Frame 1/1")
	_anim_frame_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_anim_frame_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav.add_child(_anim_frame_label)
	var edit_row := HBoxContainer.new()
	edit_row.add_theme_constant_override("separation", 4)
	body.add_child(edit_row)
	var add_b := _button("+ Frame", _anim_add_frame)
	add_b.tooltip_text = "Duplicate the current frame (paint it into the next pose)"
	add_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_row.add_child(add_b)
	var del_b := _button("Delete", _anim_delete_frame)
	del_b.tooltip_text = "Delete the current frame (never the last one)"
	del_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_row.add_child(del_b)
	var time_row := HBoxContainer.new()
	body.add_child(time_row)
	time_row.add_child(_label("Secs"))
	_anim_time_spin = _spin(0.05, 10.0, 0.05, 0.5)
	_anim_time_spin.tooltip_text = "How long the current frame shows during playback"
	_anim_time_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			doc.set_frame_time(doc.current_frame, v)
			_refresh_animation_ui())
	time_row.add_child(_anim_time_spin)
	var mode_row := HBoxContainer.new()
	body.add_child(mode_row)
	mode_row.add_child(_label("Repeat"))
	_anim_mode_option = OptionButton.new()
	_anim_mode_option.focus_mode = Control.FOCUS_NONE
	_anim_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_anim_mode_option.add_item("Once", 0)
	_anim_mode_option.add_item("Loop", 1)
	_anim_mode_option.add_item("Ping-pong", 2)
	_anim_mode_option.item_selected.connect(_on_anim_mode_selected)
	mode_row.add_child(_anim_mode_option)
	_anim_play_button = _button("Play frames", _toggle_anim_playback)
	_anim_play_button.tooltip_text = "Play the voxel frames (voxels change; bones don't)"
	body.add_child(_anim_play_button)
	_refresh_animation_ui()


func _anim_step(step: int) -> void:
	if _anim_playing:
		_set_anim_playing(false)
	if step <= -100:
		doc.goto_frame(0)
	elif step >= 100:
		doc.goto_frame(doc.frame_count() - 1)
	else:
		doc.goto_frame(doc.current_frame + step)
	_refresh_animation_ui()


func _anim_add_frame() -> void:
	if _anim_playing:
		_set_anim_playing(false)
	var i: int = doc.add_frame_from_current()
	_say("Frame %d added (duplicate of %d)" % [i + 1, i])
	_refresh_animation_ui()


func _anim_delete_frame() -> void:
	if _anim_playing:
		_set_anim_playing(false)
	if doc.delete_frame(doc.current_frame):
		_say("Frame deleted")
	else:
		_say("Cannot delete the only frame")
	_refresh_animation_ui()


func _on_anim_mode_selected(index: int) -> void:
	doc.set_anim_mode(int(_anim_mode_option.get_item_id(index)))
	_refresh_animation_ui()


func _toggle_anim_playback() -> void:
	_set_anim_playing(not _anim_playing)


func _set_anim_playing(on: bool) -> void:
	if on and _stroking:
		_say("Finish the stroke before playing")
		return
	_anim_playing = on
	_anim_time = 0.0
	if on and doc.frame_count() > 1:
		doc.goto_frame(0)
	_refresh_animation_ui()


## Advances playback: holds each frame for its time, then steps per mode
## (once stops at the end, loop wraps, ping-pong bounces). Called from
## `_process`; refuses to run while a stroke is active.
func _tick_animation(delta: float) -> void:
	if not _anim_playing or _stroking:
		return
	if doc.frame_count() <= 1:
		_set_anim_playing(false)
		return
	_anim_time += delta
	var cur: int = doc.current_frame
	var hold: float = float(doc.frame_times[cur]) if cur < doc.frame_times.size() else 0.5
	if _anim_time < hold:
		return
	_anim_time = 0.0
	var last: int = doc.frame_count() - 1
	var nxt: int = cur + 1
	if doc.anim_mode == 2 and _anim_bounce_back:
		nxt = cur - 1
	if nxt > last:
		if doc.anim_mode == 0:
			_set_anim_playing(false)
			return
		elif doc.anim_mode == 1:
			nxt = 0
		else:
			_anim_bounce_back = true
			nxt = maxi(cur - 1, 0)
	elif nxt < 0:
		_anim_bounce_back = false
		nxt = mini(cur + 1, last)
	elif doc.anim_mode == 2 and nxt == last:
		_anim_bounce_back = true
	doc.goto_frame(nxt)
	_refresh_animation_ui()


var _anim_bounce_back: bool = false


func _refresh_animation_ui() -> void:
	if _anim_frame_label == null:
		return
	_syncing_ui = true
	var n: int = doc.frame_count()
	_anim_frame_label.text = "Frame %d/%d%s" % [doc.current_frame + 1, n, " · ▶" if _anim_playing else ""]
	if doc.current_frame < doc.frame_times.size():
		_anim_time_spin.value = doc.frame_times[doc.current_frame]
	_anim_mode_option.select(_anim_mode_option.get_item_index(doc.anim_mode))
	_anim_play_button.text = "Stop" if _anim_playing else "Play frames"
	_syncing_ui = false


func _set_material(kind: int) -> void:
	kind = clampi(kind, 0, VoxelMaterial.count() - 1)
	if kind == current_material:
		_sync_material_ui()
		return
	var was_default_color: bool = color.is_equal_approx(VoxelMaterial.color(current_material))
	current_material = kind
	if was_default_color:
		_set_color(VoxelMaterial.color(kind))
	_sync_material_ui()


func _set_material_overrides(solid: int, walkable: int) -> void:
	current_material_overrides = VoxelMaterial.make_overrides(solid, walkable)
	_sync_material_ui()


func _on_material_override_changed() -> void:
	if _syncing_ui:
		return
	_set_material_overrides(_solid_override_option.get_selected_id(),
		_walkable_override_option.get_selected_id())


## Compact action/status surface for prefabs. The visual browser lives in
## `VoxelPrefabCatalogDialog`; this section never shows a grid.
func _build_prefab_ui(parent: VBoxContainer) -> void:
	var body := _section(parent, "Prefabs", false)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	body.add_child(row)
	var open_button := _button("Catalogue (B)", open_catalogue)
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(open_button)
	var reload_button := _button("Reload", _reload_prefabs)
	reload_button.tooltip_text = "Reload every prefab source from disk and revalidate all instances"
	row.add_child(reload_button)
	_prefab_selection_label = _label("No instance selected")
	_prefab_selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prefab_selection_label.add_theme_font_size_override("font_size", 12)
	body.add_child(_prefab_selection_label)
	var sel_row := HBoxContainer.new()
	sel_row.add_theme_constant_override("separation", 4)
	body.add_child(sel_row)
	_prefab_unpack_button = _button("Unpack", _unpack_selected_prefab)
	_prefab_unpack_button.tooltip_text = "Replace the linked instance with editable voxels and lights (one undo step)"
	_prefab_unpack_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_row.add_child(_prefab_unpack_button)
	_prefab_delete_button = _button("Delete", _delete_selected_prefab)
	_prefab_delete_button.tooltip_text = "Delete the selected instance (Delete key)"
	_prefab_delete_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_row.add_child(_prefab_delete_button)
	var lights_row := HBoxContainer.new()
	body.add_child(lights_row)
	_prefab_panel_label = _label("Instance lights: 0 / 64")
	_prefab_panel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prefab_panel_label.add_theme_font_size_override("font_size", 12)
	lights_row.add_child(_prefab_panel_label)
	_prefab_budget_spin = _spin(0, 4096, 1, 64)
	_prefab_budget_spin.custom_minimum_size = Vector2(76, 0)
	_prefab_budget_spin.tooltip_text = "Soft warning threshold for instance lights; no light is ever dropped"
	_prefab_budget_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			doc.set_prefab_light_budget(int(v)))
	lights_row.add_child(_prefab_budget_spin)
	_prefab_problems_label = _label("No prefab problems")
	_prefab_problems_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prefab_problems_label.add_theme_font_size_override("font_size", 12)
	body.add_child(_prefab_problems_label)
	body.add_child(_button("Review problems...", open_prefab_problems))
	var copy_button := _button("Save a copy to library...", _ask_save_copy_to_library)
	copy_button.tooltip_text = "Save this model into the prefab library without changing the open document"
	body.add_child(copy_button)
	_refresh_prefab_ui()


func _build_character_ui(parent: VBoxContainer) -> void:
	var body := _section(parent, "Character", false)
	body.add_child(_label("Preset"))
	_character_preset_option = OptionButton.new()
	_character_preset_option.focus_mode = Control.FOCUS_NONE
	_character_preset_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in VoxelCharacterRig.PRESETS.size():
		_character_preset_option.add_item(str(VoxelCharacterRig.PRESETS[i][&"name"]), i)
	_character_preset_option.item_selected.connect(_on_character_preset_selected)
	body.add_child(_character_preset_option)
	body.add_child(_label("Part models (saved .tres, empty = procedural)"))
	for slot: StringName in [&"helmet", &"chest", &"main_hand", &"off_hand"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		body.add_child(row)
		var tag := _label(str(slot).capitalize().replace("_", " "))
		tag.custom_minimum_size = Vector2(78, 0)
		row.add_child(tag)
		var path_edit := LineEdit.new()
		path_edit.placeholder_text = "procedural"
		path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		path_edit.focus_mode = Control.FOCUS_CLICK
		var captured: StringName = slot
		path_edit.text_submitted.connect(func(t: String) -> void: _on_character_slot_committed(captured, t))
		row.add_child(path_edit)
		_character_slot_edits[slot] = path_edit
		var browse := _button("...", func() -> void: _ask_character_slot_file(slot))
		browse.tooltip_text = "Choose a saved .tres part model for %s" % str(slot)
		browse.custom_minimum_size = Vector2(30, 0)
		row.add_child(browse)
		var clear := _button("x", func() -> void: _on_character_slot_committed(slot, ""))
		clear.tooltip_text = "Back to procedural %s" % str(slot)
		clear.custom_minimum_size = Vector2(30, 0)
		row.add_child(clear)
	body.add_child(_label("Animation"))
	var anim_row := HBoxContainer.new()
	anim_row.add_theme_constant_override("separation", 4)
	body.add_child(anim_row)
	for entry: Array in [["Idle", 0], ["Walk", 1], ["Run", 2]]:
		var label_text: String = entry[0]
		var state_id: int = entry[1]
		var b := _button(label_text, func() -> void: _set_character_anim_state(state_id))
		b.tooltip_text = "Preview %s on the live rig" % label_text
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		anim_row.add_child(b)
	var attack := _button("Attack", _play_character_attack)
	attack.tooltip_text = "Play one attack swing on the live rig"
	attack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	anim_row.add_child(attack)
	_character_anim_label = _label("Idle")
	_character_anim_label.add_theme_font_size_override("font_size", 12)
	body.add_child(_character_anim_label)
	_refresh_character_ui()


## Applies a class preset to the live rig (rewrites the slot indices behind a
## guard like the rig's own Inspector path). Slot model paths are untouched.
func _on_character_preset_selected(index: int) -> void:
	if character_rig == null:
		return
	character_rig.apply_preset(int(_character_preset_option.get_item_id(index)))
	_character_anim_label.text = "Preset: %s" % str(VoxelCharacterRig.PRESETS[character_rig.current_preset][&"name"])


## Commits a slot model path: loads the model, refuses nesting, stores the
## path on both the document (saved) and the live rig (displayed).
func _on_character_slot_committed(slot: StringName, model_path: String) -> void:
	if character_rig == null:
		return
	var trimmed: String = model_path.strip_edges()
	if trimmed.is_empty():
		character_rig.set_slot_model(slot, "")
		doc.set_character_slot(str(slot), "")
		_refresh_character_ui()
		_say("Character %s: procedural" % str(slot))
		return
	var err: String = character_rig.set_slot_model(slot, trimmed)
	if err != "":
		_say(err)
		_refresh_character_ui()
		return
	doc.set_character_slot(str(slot), trimmed)
	_refresh_character_ui()
	_say("Character %s: %s" % [str(slot), trimmed.get_file()])


func _ask_character_slot_file(slot: StringName) -> void:
	if _file_dialog == null:
		return
	_character_file_slot = slot
	_file_dialog.title = "Choose %s part model" % str(slot)
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.tres, *.res ; Voxel Model"])
	if doc.path != "":
		_file_dialog.current_dir = doc.path.get_base_dir()
	_file_dialog.popup_centered()


func _set_character_anim_state(state_id: int) -> void:
	if character_rig == null:
		return
	character_rig.set_anim_state(state_id as VoxelCharacterRig.AnimState)
	_character_anim_label.text = ["Idle", "Walk", "Run"][clampi(state_id, 0, 2)]


func _play_character_attack() -> void:
	if character_rig == null:
		return
	character_rig.play_attack()
	_character_anim_label.text = "Attack"


func _refresh_character_ui() -> void:
	if _character_preset_option == null:
		return
	_syncing_ui = true
	if character_rig != null:
		_character_preset_option.select(maxi(character_rig.current_preset, 0))
	for slot: Variant in _character_slot_edits:
		var edit: LineEdit = _character_slot_edits[slot]
		edit.text = str(doc.character_slots.get(str(slot), character_rig.slot_model_paths.get(slot, "")))
	_syncing_ui = false


# --- Prefabs ---

## Opens the visual catalogue. Scanning is lazy: the editor itself never scans
## the libraries at startup.
func open_catalogue() -> void:
	if catalog_dialog == null:
		return
	catalog_dialog.setup(catalog, doc, doc.path.get_base_dir())
	catalog_dialog.open_assets()


func open_prefab_problems() -> void:
	if catalog_dialog == null:
		return
	catalog_dialog.setup(catalog, doc, doc.path.get_base_dir())
	catalog_dialog.open_problems()


func _toggle_catalogue() -> void:
	if catalog_dialog == null:
		return
	if catalog_dialog.visible:
		catalog_dialog.hide()
	else:
		open_catalogue()


## Arms a catalogue asset for repeated placement and switches to the Prefab
## tool. The source stays referenced; placement is what dirties the document.
func arm_prefab(asset_id: String, source: VoxelModel, pivot: Vector3) -> void:
	if source == null:
		_say("Cannot place: source is missing")
		return
	armed_asset_id = asset_id
	armed_source = source
	armed_pivot = VoxelPrefabInstance.snap_pivot(pivot)
	armed_bounds = VoxelPrefabInstance.occupied_bounds(source)
	armed_yaw = 0
	_ghost_check_key = ""
	_set_tool(Tool.PREFAB)
	_say("Placing %s — LMB place, R rotate, Esc cancel" % _asset_display_name(asset_id))


func disarm_prefab() -> void:
	armed_source = null
	armed_asset_id = ""
	armed_yaw = 0
	armed_bounds = AABB()
	_ghost_check_key = ""
	if prefab_rig != null:
		prefab_rig.hide_ghost()


func _asset_display_name(asset_id: String) -> String:
	var a: Dictionary = catalog.asset(asset_id)
	if a.is_empty():
		return asset_id if asset_id != "" else "prefab"
	return str(a.get("name", asset_id))


func _select_prefab(id: int) -> void:
	selected_prefab_id = id
	if id >= 0 and selected_light_id >= 0:
		# One selection at a time, so Delete is unambiguous.
		selected_light_id = -1
		_sync_light_nodes()
	_sync_prefab_rig()
	if id >= 0:
		var inst: VoxelPrefabInstance = doc.prefab_instance(id)
		if inst != null:
			_say("Selected prefab #%d at (%d, %d, %d)" % [
				id, inst.anchor.x, inst.anchor.y, inst.anchor.z])


## Rebuilds instance lights, placeholders and the selection outline.
func _sync_prefab_rig() -> void:
	if prefab_rig == null:
		return
	if selected_prefab_id >= 0 and doc.prefab_instance(selected_prefab_id) == null:
		selected_prefab_id = -1
	prefab_rig.sync(doc, selected_prefab_id)
	_refresh_prefab_ui()


func _on_prefabs_changed() -> void:
	_sync_prefab_rig()
	_update_status()


## Validates the armed asset at `anchor`, caching the result per anchor/yaw so
## large sources are not re-walked every frame.
func _ghost_candidate(anchor: Vector3i) -> Dictionary:
	var key := "%d,%d,%d|%d|%d|%d" % [anchor.x, anchor.y, anchor.z, armed_yaw,
		armed_source.get_instance_id(), armed_source.cells.size()]
	if key == _ghost_check_key:
		return {"ok": _ghost_check_ok, "reason": _ghost_check_reason}
	var probe := VoxelPrefabInstance.new()
	probe.asset_id = armed_asset_id
	probe.source = armed_source
	probe.source_bounds = armed_bounds
	probe.pivot = armed_pivot
	probe.anchor = anchor
	probe.yaw_quarters = armed_yaw
	var res: Dictionary = doc.prefab_composition.validate_candidate(probe, doc.grid, doc.bounds)
	_ghost_check_key = key
	_ghost_check_ok = bool(res.get("ok", false))
	_ghost_check_reason = str(res.get("reason", ""))
	return res


func _update_prefab_ghost() -> void:
	if prefab_rig == null:
		return
	if _stroking:
		prefab_rig.hide_ghost()
		_reset_prefab_hint()
		return
	if armed_source == null:
		prefab_rig.hide_ghost()
		_reset_prefab_hint()
		return
	if not _hover.get("valid", false):
		prefab_rig.hide_ghost()
		_set_cursor_text(null)
		_reset_prefab_hint()
		return
	var anchor: Vector3i = _hover["cell"]
	var candidate: Dictionary = _ghost_candidate(anchor)
	prefab_rig.show_ghost(armed_source, armed_pivot, anchor, armed_yaw,
		bool(candidate["ok"]), armed_bounds)
	_set_cursor_text(anchor)
	var hint: String = "Place at (%d, %d, %d)" % [anchor.x, anchor.y, anchor.z]
	if not candidate["ok"]:
		hint = "Cannot place: " + str(candidate.get("reason", "invalid"))
	if _hint_label != null and current_tool == Tool.PREFAB:
		_hint_label.text = hint


## Restores the default Prefab hint after the placement hint no longer applies.
func _reset_prefab_hint() -> void:
	if _hint_label != null and current_tool == Tool.PREFAB:
		_hint_label.text = TOOL_HINTS[int(Tool.PREFAB)]


func _place_armed_at(cell: Vector3i) -> void:
	var source: VoxelModel = armed_source
	var asset_id: String = armed_asset_id
	var pivot: Vector3 = armed_pivot
	var yaw: int = armed_yaw
	if source == null:
		return
	var res: Dictionary = doc.place_prefab(source, source.resource_path, asset_id,
		pivot, cell, yaw)
	if res.get("ok", false):
		selected_prefab_id = int(res["instance_id"])
		_sync_prefab_rig()
		_say("Placed %s at (%d, %d, %d)" % [_asset_display_name(asset_id), cell.x, cell.y, cell.z])
		return
	if str(res.get("state", "")) == "budget":
		var added: int = int(res.get("added_lights", 0))
		_ask_budget_override(added, func() -> void:
			var forced: Dictionary = doc.place_prefab(source, source.resource_path,
				asset_id, pivot, cell, yaw, true)
			if forced.get("ok", false):
				selected_prefab_id = int(forced["instance_id"])
				_sync_prefab_rig()
				_say("Placed %s over the soft light budget" % _asset_display_name(asset_id))
			else:
				_say("Cannot place: " + str(forced.get("reason", ""))))
		return
	_say("Cannot place: " + str(res.get("reason", "")))


func _ask_budget_override(added: int, retry: Callable) -> void:
	if _confirm_dialog == null:
		return
	_confirm_dialog.dialog_text = "This placement adds %d instance lights; the scene will have %d (soft budget %d). Place anyway?" % [
		added, doc.prefab_light_count() + added, doc.prefab_light_budget]
	_confirm_dialog.ok_button_text = "Place anyway"
	_pending_action = retry
	_confirm_dialog.popup_centered()


func _begin_prefab_action(h: Dictionary) -> void:
	if armed_source != null:
		_place_armed_at(h["cell"])
		return
	var id: int = int(h.get("prefab_id", 0))
	if id <= 0:
		_select_prefab(-1)
		return
	_select_prefab(id)
	var inst: VoxelPrefabInstance = doc.prefab_instance(id)
	if inst == null:
		return
	_drag_prefab_id = id
	_drag_prefab_origin = inst.anchor
	# Lock the drag to the grabbed face plane (same rule as voxel strokes), so
	# dragging sideways on a top face never sinks the instance in Y.
	var normal: Vector3i = h.get("normal", Vector3i.UP)
	if normal == Vector3i.ZERO:
		normal = Vector3i.UP
	_plane_axis = _axis_of(normal)
	_plane_coord = float(h.get("face_coord", 0.0))
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var start: Variant = _prefab_plane_hit(camera.project_ray_origin(mouse),
		camera.project_ray_normal(mouse))
	_drag_prefab_start = (start as Vector3) if start != null else Vector3(inst.anchor)
	_prefab_drag_active = true
	_prefab_drag_moved = false
	_stroking = true
	_stroke_tool = Tool.PREFAB
	_stroke_mouse_driven = false
	doc.begin_stroke()


## Intersection of a ray with the active face plane, or null when the ray is
## parallel or points away.
func _prefab_plane_hit(origin: Vector3, dir: Vector3) -> Variant:
	var a: int = _plane_axis
	if absf(dir[a]) < 1e-6:
		return null
	var t: float = (_plane_coord - origin[a]) / dir[a]
	if t < 0.0:
		return null
	return origin + dir * t


func _update_prefab_drag(origin: Vector3, dir: Vector3) -> void:
	if _drag_prefab_id < 0:
		return
	var hit: Variant = _prefab_plane_hit(origin, dir)
	if hit == null:
		return
	var delta: Vector3 = (hit as Vector3) - _drag_prefab_start
	delta[_plane_axis] = 0.0
	var step := Vector3i(roundi(delta.x), roundi(delta.y), roundi(delta.z))
	var target: Vector3i = _drag_prefab_origin + step
	var inst: VoxelPrefabInstance = doc.prefab_instance(_drag_prefab_id)
	if inst == null or inst.anchor == target:
		return
	_prefab_drag_moved = true
	var res: Dictionary = doc.move_prefab(_drag_prefab_id, target)
	if not res.get("ok", false):
		_say("Cannot move: " + str(res.get("reason", "")))


func _finish_prefab_drag() -> void:
	doc.end_stroke()
	_prefab_drag_active = false
	_prefab_drag_moved = false
	_drag_prefab_id = -1
	_stroking = false
	_stroke_mouse_driven = false
	_sync_prefab_rig()


func _rotate_prefab_action() -> void:
	if armed_source != null:
		armed_yaw = VoxelPrefabInstance.normalize_yaw(armed_yaw + 1)
		_ghost_check_key = ""
		_say("Placement yaw %d°" % (armed_yaw * 90))
		return
	if selected_prefab_id < 0:
		return
	var id: int = selected_prefab_id
	var res: Dictionary = doc.rotate_prefab(id, 1)
	if res.get("ok", false):
		var inst: VoxelPrefabInstance = doc.prefab_instance(id)
		var yaw: int = inst.yaw_quarters * 90 if inst != null else 0
		_say("Rotated prefab #%d to %d°" % [id, yaw])
	else:
		_say("Cannot rotate: " + str(res.get("reason", "")))


func _duplicate_selected_prefab() -> void:
	var inst: VoxelPrefabInstance = doc.prefab_instance(selected_prefab_id)
	if inst == null:
		return
	if inst.source == null:
		_say("Cannot duplicate: source is missing (relink it first)")
		return
	arm_prefab(inst.asset_id, inst.source, inst.pivot)
	armed_yaw = inst.yaw_quarters
	_say("Placing a duplicate of prefab #%d — Esc cancels" % inst.instance_id)


func _delete_selected_prefab() -> void:
	if selected_prefab_id < 0:
		return
	var id: int = selected_prefab_id
	var res: Dictionary = doc.delete_prefab(id)
	if res.get("ok", false):
		selected_prefab_id = -1
		_sync_prefab_rig()
		_say("Deleted prefab #%d" % id)


func _unpack_selected_prefab() -> void:
	if selected_prefab_id < 0:
		return
	var id: int = selected_prefab_id
	var res: Dictionary = doc.unpack_prefab(id)
	if res.get("ok", false):
		selected_prefab_id = -1
		_sync_prefab_rig()
		_say("Unpacked prefab #%d: %d voxels, %d lights" % [
			id, int(res.get("cells", 0)), int(res.get("lights", 0))])
	else:
		_say("Cannot unpack: " + str(res.get("reason", "")))


func _cancel_prefab_action() -> void:
	if armed_source != null:
		disarm_prefab()
		_say("Placement cancelled")
		return
	if selected_prefab_id >= 0:
		_select_prefab(-1)


## Reloads every source from disk, revalidates the composition and refreshes
## the catalogue. Not undoable and does not dirty the document.
func _reload_prefabs() -> void:
	var res: Dictionary = doc.refresh_prefabs()
	_ghost_check_key = ""
	_sync_prefab_rig()
	catalog.scan(doc.path.get_base_dir())
	if catalog_dialog != null and catalog_dialog.visible:
		catalog_dialog.refresh()
	_say("Reloaded %d prefabs: %d updated, %d missing, %d conflicted, %d incompatible" % [
		int(res.get("reloaded", 0)), int(res.get("updated", 0)),
		int(res.get("missing", 0)), int(res.get("conflicted", 0)),
		int(res.get("incompatible", 0))])


func _on_catalogue_place(asset_id: String) -> void:
	var model: VoxelModel = catalog.load_asset(asset_id)
	if model == null:
		_say("Cannot place: asset could not be loaded")
		return
	var a: Dictionary = catalog.asset(asset_id)
	arm_prefab(asset_id, model, a.get("pivot", Vector3.ZERO))
	if catalog_dialog != null:
		catalog_dialog.hide()


func _on_catalogue_select_instance(id: int) -> void:
	_set_tool(Tool.PREFAB)
	_select_prefab(id)
	frame_prefab(id)


func _on_catalogue_relink(id: int, path: String) -> void:
	var model: VoxelModel = VoxelDocument.load_model_tolerant(path)
	if model == null:
		_say("Relink failed: not a VoxelModel")
		return
	var asset: Dictionary = catalog.asset_at(path)
	var asset_id: String = str(asset.get("asset_id", ""))
	var r: Dictionary = doc.relink_prefab(id, model, path, asset_id)
	if r.get("ok", false):
		_sync_prefab_rig()
		_say("Relinked prefab #%d to %s" % [id, path.get_file()])
	else:
		_say("Relink failed: " + str(r.get("reason", "")))


func _on_catalogue_delete(id: int) -> void:
	selected_prefab_id = id
	_delete_selected_prefab()


func _on_catalogue_unpack(id: int) -> void:
	selected_prefab_id = id
	_unpack_selected_prefab()


## Frames the camera on one instance (used by the catalogue's Select action).
func frame_prefab(id: int) -> void:
	var box: AABB = doc.prefab_bounds(id)
	if box.size.is_zero_approx():
		var inst: VoxelPrefabInstance = doc.prefab_instance(id)
		if inst == null:
			return
		box = inst.placeholder_bounds()
	if box.size.is_zero_approx():
		return
	_focus = box.get_center()
	_distance = maxf(box.size.length() * 1.8, 12.0)


## Saves the current model into a prefab library without touching the open
## document's path or dirty state. Refused for models with instances, because
## a prefab source may not contain prefabs.
func _ask_save_copy_to_library() -> void:
	if not doc.prefab_instances.is_empty():
		_say("Cannot save a copy: unpack the prefabs first (a prefab cannot contain prefabs)")
		return
	var dir: String = catalog.user_library()
	DirAccess.make_dir_recursive_absolute(dir)
	_library_dialog.current_dir = dir
	_library_dialog.current_file = (doc.path.get_file().get_basename() if doc.path != "" else "prefab") + ".tres"
	_library_dialog.popup_centered()


func _on_library_file_selected(chosen: String) -> void:
	var p: String = chosen
	if p.get_extension() == "":
		p += ".tres"
	var model: VoxelModel = doc.to_model()
	var err: Error = ResourceSaver.save(model, p, ResourceSaver.FLAG_RELATIVE_PATHS)
	if err != OK:
		_say("Save copy failed (%s): %s" % [error_string(err), p])
		return
	catalog.scan(doc.path.get_base_dir())
	if catalog_dialog != null and catalog_dialog.visible:
		catalog_dialog.refresh()
	_say("Saved prefab copy " + p)


func _refresh_prefab_ui() -> void:
	if _prefab_panel_label == null:
		return
	_syncing_ui = true
	var inst: VoxelPrefabInstance = doc.prefab_instance(selected_prefab_id)
	var state: String = "ok"
	if inst != null:
		state = str(doc.prefab_status(selected_prefab_id).get("state", "ok"))
		_prefab_selection_label.text = "%s  #%d\nanchor (%d, %d, %d)  yaw %d°  [%s]" % [
			inst.source_path.get_file() if inst.source_path != "" else "instance",
			inst.instance_id, inst.anchor.x, inst.anchor.y, inst.anchor.z,
			inst.yaw_quarters * 90, state.capitalize()]
	else:
		_prefab_selection_label.text = "No instance selected"
	if _prefab_unpack_button != null:
		_prefab_unpack_button.disabled = inst == null or state != "ok"
	if _prefab_delete_button != null:
		_prefab_delete_button.disabled = inst == null
	var over: bool = doc.prefab_light_budget_exceeded()
	_prefab_panel_label.text = "Instance lights: %d / %d%s" % [
		doc.prefab_light_count(), doc.prefab_light_budget,
		"  (over budget)" if over else ""]
	_prefab_panel_label.add_theme_color_override("font_color",
		Color(1.0, 0.55, 0.4) if over else Color(0.85, 0.88, 0.95))
	var counts: Dictionary = doc.prefab_status_counts()
	var problems: int = int(counts.get("missing", 0)) + int(counts.get("conflict", 0)) \
		+ int(counts.get("incompatible", 0))
	if problems > 0:
		_prefab_problems_label.text = "Problems: %d missing, %d conflicted, %d incompatible" % [
			int(counts.get("missing", 0)), int(counts.get("conflict", 0)),
			int(counts.get("incompatible", 0))]
		_prefab_problems_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.4))
	else:
		_prefab_problems_label.text = "No prefab problems"
		_prefab_problems_label.add_theme_color_override("font_color", Color(0.65, 0.85, 0.65))
	if _prefab_budget_spin != null:
		_prefab_budget_spin.value = doc.prefab_light_budget
	_syncing_ui = false


# --- Ghost preview ---

func _update_ghost() -> void:
	if current_tool == Tool.PREFAB:
		_ghost.visible = false
		_update_prefab_ghost()
		return
	var tool_for_ghost: Tool = _stroke_tool if _stroking else current_tool
	if _stroking and _is_box_tool(_stroke_tool):
		var ext: Array[Vector3i] = _box_extent()
		_show_ghost(Vector3(ext[0]) + Vector3(ext[1] - ext[0] + Vector3i.ONE) * 0.5,
				Vector3(ext[1] - ext[0] + Vector3i.ONE), tool_for_ghost)
		if _box_has_linked_cells():
			# Box and Box Erase both refuse a region that touches a linked
			# instance, so both previews turn red.
			_ghost_mat.albedo_color = Color(1.0, 0.2, 0.2, 0.55)
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
	# Editing gestures that would touch a linked cell preview as refused.
	if doc.prefab_composition.has_cell(cell) \
			and (current_tool == Tool.ERASE or current_tool == Tool.PAINT \
				or current_tool == Tool.FILL or current_tool == Tool.BOX_ERASE):
		_ghost_mat.albedo_color = Color(1.0, 0.2, 0.2, 0.55)


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
		Tool.LIGHT_PLACE, Tool.LIGHT_EDIT:
			c = Color(1.0, 0.85, 0.6, 0.55)
		_:
			c = Color(color.r, color.g, color.b, 0.5)
	_ghost_mat.albedo_color = c


# --- Input ---

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
					# Any click that reaches the viewport drops keyboard focus
					# from a spin box. Without this, a field edited earlier keeps
					# eating WASD/Space/C until the next *left* click, so
					# middle-dragging to orbit appeared to break navigation.
					get_viewport().gui_release_focus()
					if mb.button_index == MOUSE_BUTTON_LEFT and _hover.get("valid", false) and not _stroking:
						_begin_stroke(_hover)
					elif mb.button_index == MOUSE_BUTTON_LEFT and current_tool == Tool.PREFAB and not _stroking:
						# A click on empty space clears the instance selection.
						_select_prefab(-1)
					elif mb.button_index == MOUSE_BUTTON_RIGHT:
						_rmb_dragged = false
				MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
					# A ScrollContainer at its top/bottom edge no longer consumes
					# the wheel, and the event would fall through to zoom here.
					# Ignore it while any control is hovered (same gate as clicks).
					if get_viewport().gui_get_hovered_control() != null:
						get_viewport().set_input_as_handled()
						return
					get_viewport().gui_release_focus()
					if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
						_distance = clampf(_distance * 0.9, 3.0, 400.0)
					else:
						_distance = clampf(_distance / 0.9, 3.0, 400.0)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			# A right-click without a drag exits armed placement (orbit still
			# works: moving the mouse marks the press as a drag).
			if armed_source != null and not _rmb_dragged:
				_cancel_prefab_action()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if (mm.button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) != 0:
			if (mm.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
				_rmb_dragged = true
			if mm.shift_pressed:
				_pan(mm.relative)
			else:
				_orbit(mm.relative)
	elif event is InputEventKey:
		var k := event as InputEventKey
		# Cmd (meta) = Ctrl on macOS; ignore raw modifier presses.
		if k.keycode == KEY_META:
			return
		if k.pressed and not k.echo and _handle_key(k):
			get_viewport().set_input_as_handled()


func _handle_key(k: InputEventKey) -> bool:
	# Shortcuts fire on Ctrl (Windows/Linux) or Cmd (macOS).
	var mod: bool = k.ctrl_pressed or k.command_or_control_autoremap
	if mod:
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
			KEY_D:
				if _text_field_focused():
					return false
				_duplicate_selected_prefab()
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
		KEY_8: _set_tool(Tool.LIGHT_PLACE)
		KEY_9: _set_tool(Tool.LIGHT_EDIT)
		KEY_0: _set_tool(Tool.PREFAB)
		KEY_M:
			if _text_field_focused():
				return false
			_set_tool(Tool.MATERIAL)
		KEY_K:
			if _text_field_focused():
				return false
			_set_tool(Tool.CHARACTER)
		KEY_B:
			if _text_field_focused():
				return false
			_toggle_catalogue()
		KEY_R:
			if _text_field_focused():
				return false
			_rotate_prefab_action()
		KEY_DELETE, KEY_BACKSPACE:
			if _text_field_focused():
				return false
			if selected_prefab_id >= 0:
				_delete_selected_prefab()
			elif selected_light_id >= 0:
				remove_point_light(selected_light_id)
		KEY_ESCAPE:
			_cancel_prefab_action()
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

## True when typing should win over single-key shortcuts. SpinBoxes focus
## their internal LineEdit, so the LineEdit check covers them too.
func _text_field_focused() -> bool:
	var f: Control = get_viewport().gui_get_focus_owner()
	return f != null and (f is LineEdit or f is TextEdit or f is SpinBox)


func _set_tool(t: Tool) -> void:
	if _stroking:
		return
	current_tool = t
	for i in _tool_buttons.size():
		_tool_buttons[i].set_pressed_no_signal(i == int(t))
	if _hint_label != null:
		_hint_label.text = TOOL_HINTS[int(t)]
	if t != Tool.PREFAB and prefab_rig != null:
		prefab_rig.hide_ghost()
		if selected_prefab_id >= 0:
			_select_prefab(-1)
	if character_rig != null:
		character_rig.visible = (t == Tool.CHARACTER)
		character_rig.set_process(t == Tool.CHARACTER)


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
		_doc_replaced = true
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
	_confirm_dialog.dialog_text = "Discard unsaved changes?"
	_confirm_dialog.ok_button_text = "Discard"
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
	if _character_file_slot != &"":
		var slot: StringName = _character_file_slot
		_character_file_slot = &""
		_on_character_slot_committed(slot, chosen)
		return
	var p: String = ProjectSettings.localize_path(chosen)
	if _pending_open:
		_open_path(chosen)
	else:
		var ext: String = p.get_extension()
		if ext != "tres" and ext != "res":
			p += ".tres"
		_write_file(p)


# --- Screenshots ---

func _ask_save_screenshot() -> void:
	var model_name: String = doc.path.get_file().get_basename() if doc.path != "" else "voxdot"
	_screenshot_dialog.current_dir = _default_screenshot_dir()
	_screenshot_dialog.current_file = model_name + ".png"
	_screenshot_dialog.popup_centered()


func _default_screenshot_dir() -> String:
	var pictures: String = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if pictures == "":
		return _default_dir()
	var dir: String = pictures.path_join(APP_TITLE)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## Captures only the model and background as a PNG. The UI, grid, bounds,
## mirror/work planes and placement ghost are hidden for one clean frame, then
## restored exactly. Returns an empty string in headless mode or on failure.
func save_screenshot(target: String) -> String:
	if _capturing_screenshot:
		_say("A screenshot is already being captured")
		return ""
	var p: String = target
	if p.get_extension().to_lower() != "png":
		p += ".png"
	var dir: String = p.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var dir_err: Error = DirAccess.make_dir_recursive_absolute(dir)
		if dir_err != OK:
			_say("Screenshot folder failed (%s): %s" % [error_string(dir_err), dir])
			return ""
	if DisplayServer.get_name() == "headless":
		_say("Screenshot unavailable in headless mode")
		return ""
	_capturing_screenshot = true
	var overlays: Array[Node3D] = [_grid_mi, _ghost, _mirror_x_mi, _mirror_z_mi, _layer_mi, light_rig.handles_root, prefab_rig, character_rig]
	var visibility: Array[bool] = []
	for overlay: Node3D in overlays:
		visibility.append(overlay.visible)
	var ui_visible: bool = _ui_layer.visible
	_set_screenshot_overlays_visible(false)
	# Two draws: one for canvas/dialog hiding to take effect, one clean image.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var result: String = ""
	var tex: ViewportTexture = get_viewport().get_texture()
	if tex == null:
		_say("Screenshot unavailable: no viewport texture")
	else:
		var img: Image = tex.get_image()
		if img == null or img.is_empty():
			_say("Screenshot unavailable: empty viewport image")
		else:
			var err: Error = img.save_png(p)
			if err == OK:
				_say("Screenshot saved " + p)
				result = p
			else:
				_say("Screenshot failed (%s): %s" % [error_string(err), p])
	for i in overlays.size():
		overlays[i].visible = visibility[i]
	_ui_layer.visible = ui_visible
	_capturing_screenshot = false
	return result


func _set_screenshot_overlays_visible(on: bool) -> void:
	_ui_layer.visible = on
	for overlay: Node3D in [_grid_mi, _ghost, _mirror_x_mi, _mirror_z_mi, _layer_mi, light_rig.handles_root, prefab_rig, character_rig]:
		overlay.visible = on


func _on_screenshot_selected(chosen: String) -> void:
	# Close the picker before the clean-frame capture starts.
	await get_tree().process_frame
	save_screenshot(chosen)


# --- UI ---

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	_ui_layer = layer
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var vb := _side_panel(root, "ToolPanel", LEFT_PANEL_WIDTH, false)

	var title := Label.new()
	title.text = APP_TITLE
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)

	# Undo/redo sit above the sections so they stay reachable without scrolling.
	var hist := HBoxContainer.new()
	vb.add_child(hist)
	_undo_button = _button("Undo", _do_undo)
	_undo_button.tooltip_text = "Undo the last edit (Ctrl+Z / Cmd+Z)"
	_undo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hist.add_child(_undo_button)
	_redo_button = _button("Redo", _do_redo)
	_redo_button.tooltip_text = "Redo the last undone edit (Ctrl+Shift+Z or Ctrl+Y)"
	_redo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hist.add_child(_redo_button)

	var file_body := _section(vb, "File")
	var file_grid := GridContainer.new()
	file_grid.columns = 2
	file_body.add_child(file_grid)
	for entry: Array in [
		["New", _ask_new, "New model (Ctrl+N)"],
		["Open", _ask_open, "Open a model (Ctrl+O)"],
		["Save", _save.bind(false), "Save (Ctrl+S)"],
		["Save As", _save.bind(true), "Save under a new name (Ctrl+Shift+S)"],
	]:
		var b := _button(entry[0], entry[1])
		b.tooltip_text = entry[2]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		file_grid.add_child(b)

	var model_body := _section(vb, "Model", false)
	var axes: Array[String] = ["W", "H", "D"]
	var bounds_row := HBoxContainer.new()
	model_body.add_child(bounds_row)
	for i in 3:
		bounds_row.add_child(_label(axes[i]))
		var s := _spin(VoxelDocument.MIN_BOUND, VoxelDocument.MAX_BOUND, 1, 32)
		s.value_changed.connect(_on_bounds_spin)
		bounds_row.add_child(s)
		_bound_spins.append(s)
	var fit_button := _button("Fit bounds to content", _fit_bounds_to_content)
	fit_button.tooltip_text = "Shrink or grow W/H/D to the furthest occupied cell; the origin stays at 0"
	model_body.add_child(fit_button)
	var size_row := HBoxContainer.new()
	model_body.add_child(size_row)
	size_row.add_child(_label("Voxel size (m)"))
	_size_spin = _spin(0.005, 4.0, 0.0005, 0.0625)
	_size_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			doc.set_voxel_size(v))
	size_row.add_child(_size_spin)

	var tool_body := _section(vb, "Tool")
	var tools := GridContainer.new()
	tools.columns = 3
	tool_body.add_child(tools)
	for i in TOOL_NAMES.size():
		var b := Button.new()
		var key_label: String = str(i + 1)
		if i == int(Tool.PREFAB):
			key_label = "0"
		elif i == int(Tool.MATERIAL):
			key_label = "M"
		elif i == int(Tool.CHARACTER):
			key_label = "K"
		b.text = "%s %s" % [key_label, TOOL_NAMES[i]]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		b.custom_minimum_size = Vector2(0, 26)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_set_tool.bind(i as Tool))
		tools.add_child(b)
		_tool_buttons.append(b)
	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	tool_body.add_child(_hint_label)

	var depth_row := HBoxContainer.new()
	tool_body.add_child(depth_row)
	depth_row.add_child(_label("Box depth"))
	_depth_spin = _spin(1, 64, 1, 1)
	_depth_spin.value_changed.connect(func(v: float) -> void: box_depth = int(v))
	depth_row.add_child(_depth_spin)

	var lock_row := HBoxContainer.new()
	tool_body.add_child(lock_row)
	_lock_check = CheckButton.new()
	_lock_check.text = "Height lock (H)"
	_lock_check.focus_mode = Control.FOCUS_NONE
	_lock_check.tooltip_text = "Place/Box target the horizontal plane at layer Y instead of surfaces. [ ] or PageUp/PageDown change the layer."
	_lock_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			_set_height_lock(on))
	lock_row.add_child(_lock_check)
	var layer_row := HBoxContainer.new()
	tool_body.add_child(layer_row)
	layer_row.add_child(_label("Layer Y"))
	_layer_spin = _spin(0, 31, 1, 0)
	_layer_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			_set_layer(int(v)))
	layer_row.add_child(_layer_spin)

	# Mirror flags are edit settings, so they live with the tools.
	var mirror_row := HBoxContainer.new()
	tool_body.add_child(mirror_row)
	_mirror_x_check = CheckButton.new()
	_mirror_x_check.text = "Mirror X  (X)"
	_mirror_x_check.focus_mode = Control.FOCUS_NONE
	_mirror_x_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			_set_mirror(on, doc.mirror_z))
	mirror_row.add_child(_mirror_x_check)
	_mirror_z_check = CheckButton.new()
	_mirror_z_check.text = "Mirror Z  (Z)"
	_mirror_z_check.focus_mode = Control.FOCUS_NONE
	_mirror_z_check.toggled.connect(func(on: bool) -> void:
		if not _syncing_ui:
			_set_mirror(doc.mirror_x, on))
	mirror_row.add_child(_mirror_z_check)

	var color_body := _section(vb, "Color")
	_color_button = ColorPickerButton.new()
	_color_button.edit_alpha = false
	_color_button.custom_minimum_size = Vector2(0, 30)
	_color_button.focus_mode = Control.FOCUS_NONE
	_color_button.color = color
	_color_button.color_changed.connect(func(c: Color) -> void: color = Color(c.r, c.g, c.b, 1.0))
	color_body.add_child(_color_button)
	_swatch_grid = GridContainer.new()
	_swatch_grid.columns = 8
	_swatch_grid.add_theme_constant_override("h_separation", 3)
	_swatch_grid.add_theme_constant_override("v_separation", 3)
	color_body.add_child(_swatch_grid)
	var add_swatch := _button("+ Add current color to palette", func() -> void: doc.add_swatch(color))
	color_body.add_child(add_swatch)

	_build_material_ui(vb)
	_build_animation_ui(vb)

	var view_body := _section(vb, "View")
	var view_row := HBoxContainer.new()
	view_body.add_child(view_row)
	var ortho := CheckButton.new()
	ortho.text = "Ortho (P)"
	ortho.focus_mode = Control.FOCUS_NONE
	ortho.toggled.connect(_set_orthographic)
	view_row.add_child(ortho)
	view_row.add_child(_button("Frame (F)", frame_model))
	var screenshot_button := _button("Screenshot…", _ask_save_screenshot)
	screenshot_button.tooltip_text = "Save only the model and background as a PNG; HUD and editing overlays are excluded."
	view_body.add_child(screenshot_button)
	var horizon_row := HBoxContainer.new()
	view_body.add_child(horizon_row)
	horizon_row.add_child(_label("Render horizon"))
	_horizon_spin = _spin(0, 4096, 16, 0)
	_horizon_spin.tooltip_text = "Render horizon: only mesh chunks within this horizontal distance of the camera; raising it reveals farther parts of the model. The full model is kept and saved. 0 renders everything."
	_horizon_spin.value_changed.connect(func(v: float) -> void:
		if not _syncing_ui:
			set_render_horizon(int(v)))
	horizon_row.add_child(_horizon_spin)

	var help_body := _section(vb, "Help", false)
	var help_text := Label.new()
	help_text.text = "Mouse\nLMB tool · MMB/RMB orbit\nShift+MMB/RMB pan · Wheel zoom\n\nKeyboard\nWASD fly · Space/C up/down · Shift fast\n1-9 tools · 0 Prefab · M Material · K Character · B catalogue\nR rotate prefab · Ctrl+D duplicate\nDelete deletes prefab or light\nQ/E rotate view · G grid\nH height lock · [ ] layer up/down\nCtrl+Z/Y undo/redo · Ctrl+S save\n(Cmd instead of Ctrl on macOS)"
	help_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help_text.add_theme_font_size_override("font_size", 12)
	help_text.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	help_body.add_child(help_text)

	vb.add_child(HSeparator.new())
	_cursor_label = Label.new()
	_cursor_label.text = "Cursor: -"
	_cursor_label.add_theme_font_size_override("font_size", 12)
	vb.add_child(_cursor_label)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 12)
	vb.add_child(_status_label)
	_message_label = Label.new()
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.add_theme_font_size_override("font_size", 12)
	_message_label.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	vb.add_child(_message_label)

	# Lighting and prefab content live in a separate inspector on the right,
	# leaving the left panel for file/model/tool editing.
	var scene := _side_panel(root, "ScenePanel", RIGHT_PANEL_WIDTH, true)
	var scene_title := Label.new()
	scene_title.text = "Scene"
	scene_title.add_theme_font_size_override("font_size", 16)
	scene.add_child(scene_title)
	_build_sun_ui(scene)
	_build_atmosphere_ui(scene)
	_build_light_ui(scene)
	_build_prefab_ui(scene)
	_build_character_ui(scene)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = false
	_file_dialog.filters = PackedStringArray(["*.tres, *.res ; Voxel Model"])
	_file_dialog.size = Vector2i(760, 480)
	_file_dialog.file_selected.connect(_on_file_selected)
	layer.add_child(_file_dialog)

	_screenshot_dialog = FileDialog.new()
	_screenshot_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_screenshot_dialog.use_native_dialog = false
	_screenshot_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_screenshot_dialog.title = "Save Screenshot As"
	_screenshot_dialog.filters = PackedStringArray(["*.png ; PNG Image"])
	_screenshot_dialog.size = Vector2i(760, 480)
	_screenshot_dialog.file_selected.connect(_on_screenshot_selected)
	layer.add_child(_screenshot_dialog)

	_confirm_dialog = ConfirmationDialog.new()
	_confirm_dialog.dialog_text = "Discard unsaved changes?"
	_confirm_dialog.ok_button_text = "Discard"
	_confirm_dialog.confirmed.connect(func() -> void:
		var action: Callable = _pending_action
		_pending_action = Callable()
		if action.is_valid():
			action.call())
	layer.add_child(_confirm_dialog)

	_library_dialog = FileDialog.new()
	_library_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_library_dialog.use_native_dialog = false
	_library_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_library_dialog.title = "Save Prefab Copy To Library"
	_library_dialog.filters = PackedStringArray(["*.tres ; Voxel Model"])
	_library_dialog.size = Vector2i(760, 480)
	_library_dialog.file_selected.connect(_on_library_file_selected)
	layer.add_child(_library_dialog)

	catalog_dialog = VoxelPrefabCatalogDialog.new()
	layer.add_child(catalog_dialog)
	# A Window is visible when added; an open catalogue would swallow viewport
	# input until the user asks for it.
	catalog_dialog.visible = false
	catalog_dialog.doc = doc
	catalog_dialog.place_requested.connect(_on_catalogue_place)
	catalog_dialog.select_instance_requested.connect(_on_catalogue_select_instance)
	catalog_dialog.relink_requested.connect(_on_catalogue_relink)
	catalog_dialog.delete_instance_requested.connect(_on_catalogue_delete)
	catalog_dialog.unpack_instance_requested.connect(_on_catalogue_unpack)
	catalog_dialog.reload_requested.connect(_reload_prefabs)
	catalog_dialog.save_copy_requested.connect(_ask_save_copy_to_library)


## Creates a scrollable side panel anchored to the left or right edge.
func _side_panel(root: Control, panel_name: String, width: int, on_right: bool) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.name = panel_name
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	if on_right:
		panel.anchor_left = 1.0
		panel.anchor_right = 1.0
		panel.offset_left = -float(width)
		panel.offset_right = 0.0
	else:
		panel.anchor_left = 0.0
		panel.anchor_right = 0.0
		panel.offset_left = 0.0
		panel.offset_right = float(width)
	panel.offset_top = 0.0
	panel.offset_bottom = 0.0
	panel.custom_minimum_size = Vector2(width, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.14, 0.18, 1.0)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 4)
	scroll.add_child(vb)
	return vb


## Adds a collapsible section header and returns the VBox to fill. Clicking the
## header hides/shows the contents, which keeps the panel short enough that most
## sections fit without scrolling. `expanded` sets the initial state.
func _section(parent: Control, text: String, expanded: bool = true) -> VBoxContainer:
	parent.add_child(HSeparator.new())
	var header := Button.new()
	header.text = ("▼  " if expanded else "▶  ") + text
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.flat = true
	header.focus_mode = Control.FOCUS_NONE
	header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	header.tooltip_text = "Click to show or hide %s" % text
	header.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
	header.add_theme_font_size_override("font_size", 13)
	header.custom_minimum_size = Vector2(0, 22)
	parent.add_child(header)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	body.visible = expanded
	parent.add_child(body)
	header.pressed.connect(func() -> void:
		body.visible = not body.visible
		header.text = ("▼  " if body.visible else "▶  ") + text)
	return body


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


func _fit_bounds_to_content() -> void:
	var fit: Vector3i = doc.content_extent()
	if fit == Vector3i.ZERO:
		_say("Nothing to fit: the model is empty")
		return
	if doc.resize_bounds(fit):
		_say("Fitted bounds to %d x %d x %d" % [fit.x, fit.y, fit.z])
	else:
		_say("Can't fit bounds to the content")
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
	_apply_environment()
	if _swatch_grid != null and _swatch_grid.get_child_count() != doc.swatches.size():
		_rebuild_swatches()
	_mirror_x_mi.visible = doc.mirror_x
	_mirror_z_mi.visible = doc.mirror_z
	_refresh_prefab_ui()
	_sync_character_slots()
	_update_status()


## Reapplies the document's saved character slot paths to the live rig
## (open/new/reset). Unknown slot names are ignored; missing files clear.
func _sync_character_slots() -> void:
	if character_rig == null:
		return
	for slot: StringName in [&"helmet", &"chest", &"main_hand", &"off_hand"]:
		var p: String = str(doc.character_slots.get(str(slot), ""))
		character_rig.set_slot_model(slot, p)
	_refresh_character_ui()

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
	var horizon_value: int = 0
	if render_horizon < UNLIMITED_HORIZON:
		horizon_value = mini(render_horizon, int(_horizon_spin.max_value))
	_horizon_spin.value = horizon_value
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
	var counts: Dictionary = doc.prefab_status_counts()
	var problems: int = int(counts.get("missing", 0)) + int(counts.get("conflict", 0)) \
		+ int(counts.get("incompatible", 0))
	var line: String = "%s%s\n%d local voxels  |  %d linked  |  %dx%dx%d  |  %d prefabs  |  %d lights" % [
		name_text, "*" if doc.dirty else "", doc.voxel_count(), doc.prefab_cell_count(),
		doc.bounds.x, doc.bounds.y, doc.bounds.z, doc.prefab_instances.size(),
		doc.lights.size() + doc.prefab_light_count()]
	if doc.frame_count() > 1 or _anim_playing:
		line += "  |  Frame %d/%d%s" % [doc.current_frame + 1, doc.frame_count(), " ▶" if _anim_playing else ""]
	if problems > 0:
		line += "\n%d missing, %d conflicted, %d incompatible" % [
			int(counts.get("missing", 0)), int(counts.get("conflict", 0)),
			int(counts.get("incompatible", 0))]
	_status_label.text = line
	if problems > 0:
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.62, 0.45))
	else:
		_status_label.add_theme_color_override("font_color", Color(0.88, 0.9, 0.95))
