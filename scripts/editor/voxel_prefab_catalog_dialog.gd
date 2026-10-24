class_name VoxelPrefabCatalogDialog
extends Window

## Visual prefab browser: searchable thumbnail grid, folder grouping, details,
## a large orbitable preview with click-to-pick pivot, and a Problems tab for
## the current document's missing/conflicted/incompatible instances.
##
## The dialog reads the catalogue and the document but never mutates the
## document itself: placement, relink, delete and unpack are emitted as
## signals so the editor routes them through the same undoable paths as the
## viewport tools.

signal place_requested(asset_id: String)
signal select_instance_requested(instance_id: int)
signal relink_requested(instance_id: int, path: String)
signal delete_instance_requested(instance_id: int)
signal unpack_instance_requested(instance_id: int)
signal reload_requested
signal save_copy_requested

const MIN_SIZE: Vector2i = Vector2i(1000, 640)
const THUMB_SIZE: int = 192

var catalog: VoxelPrefabCatalog
var doc: VoxelDocument
var project_dir: String = ""

var _search: LineEdit
var _library_option: OptionButton
var _folder_list: ItemList
var _grid: GridContainer
var _grid_scroll: ScrollContainer
var _problems_scroll: ScrollContainer
var _problems_box: VBoxContainer
var _status: Label
var _name_label: Label
var _path_label: Label
var _meta_label: Label
var _reason_label: Label
var _place_button: Button
var _pivot_spins: Array[SpinBox] = []
var _pivot_note: Label
var _preview_container: SubViewportContainer
var _preview_viewport: SubViewport
var _preview_camera: Camera3D
var _preview_root: Node3D
var _preview_pivot: MeshInstance3D
var _preview_model: VoxelModel
var _preview_yaw: float = deg_to_rad(35.0)
var _preview_pitch: float = deg_to_rad(-25.0)
var _preview_distance: float = 12.0
var _preview_focus: Vector3 = Vector3.ZERO
var _preview_dragging: bool = false
var _preview_drag_moved: bool = false
var _preview_last_mouse: Vector2 = Vector2.ZERO
var _selected_asset_id: String = ""
var _selected_folder: String = ""
var _showing_problems: bool = false
var _thumb_queue: Array[String] = []
var _thumb_busy: bool = false
var _thumb_cache: Dictionary = {} # asset_id -> ImageTexture
var _relink_instance_id: int = -1
var _relink_dialog: FileDialog


func setup(catalog_ref: VoxelPrefabCatalog, doc_ref: VoxelDocument, open_dir: String) -> void:
	catalog = catalog_ref
	doc = doc_ref
	project_dir = open_dir
	if _grid != null:
		refresh()


func _ready() -> void:
	title = "Prefab Catalogue"
	min_size = MIN_SIZE
	close_requested.connect(hide)
	_build_ui()


func _process(_delta: float) -> void:
	if not visible or DisplayServer.get_name() == "headless":
		return
	if not _thumb_busy and not _thumb_queue.is_empty():
		_thumb_busy = true
		var id: String = _thumb_queue.pop_front()
		_render_thumbnail(id)


## Rescans the libraries and rebuilds the grid and problems list.
func refresh() -> void:
	if catalog == null:
		return
	catalog.scan(project_dir)
	_rebuild_folders()
	_rebuild_grid()
	_rebuild_problems()
	_update_footer()
	if _selected_asset_id != "" and not catalog.asset(_selected_asset_id).is_empty():
		_show_details(_selected_asset_id)
	elif not _selected_asset_id.is_empty():
		_selected_asset_id = ""
		_clear_details()


func open_assets() -> void:
	_showing_problems = false
	if _folder_list != null:
		_folder_list.deselect_all()
	popup_centered(MIN_SIZE)
	refresh()


func open_problems() -> void:
	_showing_problems = true
	popup_centered(MIN_SIZE)
	refresh()
	_show_problems_view()


func set_document(doc_ref: VoxelDocument, open_dir: String) -> void:
	doc = doc_ref
	project_dir = open_dir
	if visible:
		refresh()


# --- UI construction ---

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	root.add_child(top)
	_search = LineEdit.new()
	_search.placeholder_text = "Search prefabs..."
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _rebuild_grid())
	top.add_child(_search)
	_library_option = OptionButton.new()
	_library_option.add_item("All libraries", 0)
	_library_option.add_item("User", 1)
	_library_option.add_item("Project", 2)
	_library_option.item_selected.connect(func(_i: int) -> void: _rebuild_folders(); _rebuild_grid())
	top.add_child(_library_option)
	top.add_child(_button("Refresh", func() -> void:
		refresh()
		reload_requested.emit()))
	top.add_child(_button("Save copy to library...", func() -> void: save_copy_requested.emit()))

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(180, 0)
	split.add_child(left)
	var folders_label := Label.new()
	folders_label.text = "Folders"
	folders_label.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
	left.add_child(folders_label)
	_folder_list = ItemList.new()
	_folder_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_folder_list.item_selected.connect(func(i: int) -> void:
		_showing_problems = false
		_selected_folder = "" if i == 0 else _folder_list.get_item_text(i)
		_show_assets_view()
		_rebuild_grid())
	left.add_child(_folder_list)
	var problems_button := _button("Problems", func() -> void:
		_showing_problems = true
		_show_problems_view()
		_rebuild_problems())
	left.add_child(problems_button)

	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(center)
	_grid_scroll = ScrollContainer.new()
	_grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_child(_grid_scroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.add_child(_grid)
	_problems_scroll = ScrollContainer.new()
	_problems_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_problems_scroll.visible = false
	center.add_child(_problems_scroll)
	_problems_box = VBoxContainer.new()
	_problems_box.add_theme_constant_override("separation", 6)
	_problems_scroll.add_child(_problems_box)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(330, 0)
	right.add_theme_constant_override("separation", 6)
	split.add_child(right)
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 16)
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_name_label)
	_path_label = Label.new()
	_path_label.add_theme_font_size_override("font_size", 11)
	_path_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	_path_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	right.add_child(_path_label)
	_meta_label = Label.new()
	_meta_label.add_theme_font_size_override("font_size", 12)
	right.add_child(_meta_label)
	_reason_label = Label.new()
	_reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reason_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	right.add_child(_reason_label)

	_preview_container = SubViewportContainer.new()
	_preview_container.custom_minimum_size = Vector2(320, 230)
	_preview_container.stretch = true
	_preview_container.focus_mode = Control.FOCUS_NONE
	_preview_container.gui_input.connect(_on_preview_input)
	right.add_child(_preview_container)
	_preview_viewport = SubViewport.new()
	_preview_viewport.size = Vector2i(320, 230)
	_preview_viewport.own_world_3d = true
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_container.add_child(_preview_viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.11, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.ambient_light_energy = 0.35
	var we := WorldEnvironment.new()
	we.environment = env
	_preview_viewport.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	_preview_viewport.add_child(sun)
	_preview_root = Node3D.new()
	_preview_viewport.add_child(_preview_root)
	_preview_camera = Camera3D.new()
	_preview_camera.fov = 35.0
	_preview_camera.current = true
	_preview_viewport.add_child(_preview_camera)
	_preview_pivot = MeshInstance3D.new()
	_preview_pivot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(_preview_pivot)

	var pivot_row := HBoxContainer.new()
	right.add_child(pivot_row)
	pivot_row.add_child(_label("Pivot"))
	for axis: String in ["X", "Y", "Z"]:
		pivot_row.add_child(_label(axis))
		var s := _spin(-VoxelDocument.MAX_BOUND, VoxelDocument.MAX_BOUND, 0.5, 0.0)
		s.custom_minimum_size = Vector2(74, 0)
		s.value_changed.connect(_on_pivot_spin)
		pivot_row.add_child(s)
		_pivot_spins.append(s)
	right.add_child(_button("Reset to bottom-center", _reset_pivot))
	_pivot_note = Label.new()
	_pivot_note.text = "Existing instances keep their pivot."
	_pivot_note.add_theme_font_size_override("font_size", 11)
	_pivot_note.add_theme_color_override("font_color", Color(0.65, 0.7, 0.8))
	right.add_child(_pivot_note)
	_place_button = _button("Place", func() -> void:
		if _selected_asset_id != "":
			place_requested.emit(_selected_asset_id))
	_place_button.custom_minimum_size = Vector2(0, 34)
	right.add_child(_place_button)
	var edit_button := _button("Edit source in new window", func() -> void:
		if _selected_asset_id != "":
			_edit_prefab_source(_selected_asset_id))
	edit_button.tooltip_text = "Open this prefab source in a second Voxdot window"
	right.add_child(edit_button)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	root.add_child(_status)

	_relink_dialog = FileDialog.new()
	_relink_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_relink_dialog.use_native_dialog = false
	_relink_dialog.filters = PackedStringArray(["*.tres, *.res ; Voxel Model"])
	_relink_dialog.size = Vector2i(760, 480)
	_relink_dialog.file_selected.connect(func(path: String) -> void:
		if _relink_instance_id >= 0:
			relink_requested.emit(_relink_instance_id, path)
			_relink_instance_id = -1)
	add_child(_relink_dialog)


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _spin(lo: float, hi: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	return s


# --- Grid / folders ---

func _rebuild_folders() -> void:
	if _folder_list == null:
		return
	var current: String = _selected_folder
	_folder_list.clear()
	_folder_list.add_item("All")
	var folders: Dictionary = {}
	for a: Dictionary in _visible_assets():
		var f: String = str(a.get("folder", "."))
		if f == ".":
			continue
		var parts: PackedStringArray = f.split("/", false)
		var prefix: String = ""
		for part: String in parts:
			prefix = part if prefix == "" else prefix + "/" + part
			folders[prefix] = true
	var keys: Array = folders.keys()
	keys.sort()
	for f: String in keys:
		_folder_list.add_item(f)
	for i in _folder_list.item_count:
		if _folder_list.get_item_text(i) == current:
			_folder_list.select(i)
			return
	_selected_folder = ""


func _visible_assets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if catalog == null:
		return out
	var lib: int = _library_option.selected if _library_option != null else 0
	for a: Dictionary in catalog.assets():
		if lib == 1 and str(a.get("library", "")) != "user":
			continue
		if lib == 2 and str(a.get("library", "")) != "project":
			continue
		out.append(a)
	return out


func _filtered_assets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var query: String = _search.text.strip_edges().to_lower() if _search != null else ""
	for a: Dictionary in _visible_assets():
		if not bool(a.get("valid", false)) and not _showing_problems:
			continue
		if query == "":
			if _selected_folder != "" and not (str(a.get("folder", ".")) == _selected_folder
					or str(a.get("folder", ".")).begins_with(_selected_folder + "/")):
				continue
		else:
			var hay: String = "%s %s" % [a.get("name", ""), a.get("relative_path", "")]
			if not hay.to_lower().contains(query):
				continue
		out.append(a)
	return out


func _rebuild_grid() -> void:
	if _grid == null:
		return
	for child: Node in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	for a: Dictionary in _filtered_assets():
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(150, 150)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.text = str(a.get("name", ""))
		b.expand_icon = true
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.icon = _thumbnail_for(a)
		b.tooltip_text = str(a.get("relative_path", ""))
		b.set_pressed_no_signal(str(a.get("asset_id", "")) == _selected_asset_id)
		b.pressed.connect(_select_asset.bind(str(a.get("asset_id", ""))))
		b.gui_input.connect(_on_item_gui_input.bind(str(a.get("asset_id", ""))))
		_grid.add_child(b)
		_queue_thumbnail(a)
	_update_footer()


func _thumbnail_for(a: Dictionary) -> Texture2D:
	var id: String = str(a.get("asset_id", ""))
	if _thumb_cache.has(id):
		return _thumb_cache[id]
	if catalog != null:
		var path: String = catalog.thumbnail_path(a)
		var abs_path: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			var img := Image.load_from_file(abs_path)
			if img != null:
				var tex := ImageTexture.create_from_image(img)
				_thumb_cache[id] = tex
				return tex
	var placeholder := _placeholder_texture(id)
	_thumb_cache[id] = placeholder
	return placeholder


func _placeholder_texture(id: String) -> ImageTexture:
	var img := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	var h: int = absi(id.hash()) % 360
	var base := Color.from_hsv(float(h) / 360.0, 0.35, 0.45)
	for y in 96:
		for x in 96:
			var c: Color = base.darkened(0.25) if ((x / 12) + (y / 12)) % 2 == 0 else base
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


func _queue_thumbnail(a: Dictionary) -> void:
	if DisplayServer.get_name() == "headless" or catalog == null:
		return
	var path: String = catalog.thumbnail_path(a)
	if FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return
	var id: String = str(a.get("asset_id", ""))
	if not _thumb_queue.has(id):
		_thumb_queue.append(id)


func _render_thumbnail(asset_id: String) -> void:
	if catalog == null:
		_thumb_busy = false
		return
	var a: Dictionary = catalog.asset(asset_id)
	var model: VoxelModel = catalog.load_asset(asset_id)
	if a.is_empty() or model == null:
		_thumb_busy = false
		return
	var vp := SubViewport.new()
	vp.size = Vector2i(THUMB_SIZE, THUMB_SIZE)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.13, 0.17)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.7)
	env.ambient_light_energy = 0.35
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 40, 0)
	sun.light_energy = 1.3
	vp.add_child(sun)
	var mi := MeshInstance3D.new()
	mi.mesh = model.build_mesh()
	vp.add_child(mi)
	var box: AABB = VoxelPrefabInstance.occupied_bounds(model)
	var center: Vector3 = box.get_center()
	var cam := Camera3D.new()
	cam.fov = 35.0
	cam.position = center + Vector3(1, 0.85, 1).normalized() * maxf(box.size.length() * 1.7, 3.0)
	cam.look_at(center)
	cam.current = true
	vp.add_child(cam)
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.12
	sphere.height = 0.24
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.35, 1.0, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.8, 0.9)
	sphere.material = mat
	marker.mesh = sphere
	marker.position = a.get("pivot", Vector3.ZERO)
	vp.add_child(marker)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	if img != null and not img.is_empty():
		var dir: String = ProjectSettings.globalize_path(VoxelPrefabCatalog.THUMB_DIR)
		DirAccess.make_dir_recursive_absolute(dir)
		img.save_png(catalog.thumbnail_path(a))
	vp.queue_free()
	_thumb_cache.erase(asset_id)
	_thumb_busy = false
	if visible:
		_rebuild_grid()


# --- Selection / details ---

func _select_asset(asset_id: String) -> void:
	_selected_asset_id = asset_id
	_show_details(asset_id)
	_rebuild_grid()


func _on_item_gui_input(event: InputEvent, asset_id: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or not mb.double_click:
		return
	get_viewport().set_input_as_handled()
	_edit_prefab_source(asset_id)


## Open the prefab source in a new Voxdot editor instance. The current
## executable is reused with --path <project> -- <absolute source path>.
func _edit_prefab_source(asset_id: String) -> void:
	if catalog == null:
		return
	var a: Dictionary = catalog.asset(asset_id)
	if a.is_empty():
		return
	var path: String = str(a.get("path", ""))
	if path == "" or not FileAccess.file_exists(path):
		_status.text = "Prefab source file is missing: " + path
		return
	var args: PackedStringArray = new_instance_args(path)
	var pid: int = OS.create_instance(args)
	if pid < 0:
		_status.text = "Could not launch a new Voxdot instance for " + path.get_file()
		push_warning("Failed to open prefab source in new Voxdot instance: %s" % path)
	else:
		hide()


## Arguments for a second editor instance. In the editor, `res://` points at
## the project; in a packaged build it is empty and the wrapper's `--main-pack`
## is not exposed through OS.get_cmdline_args(), so find the adjacent pack.
static func new_instance_args(source_path: String) -> PackedStringArray:
	var project_path: String = ProjectSettings.globalize_path("res://")
	if project_path != "":
		return PackedStringArray(["--path", project_path, "--", source_path])
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	for candidate: String in [
			exe_dir.path_join("voxdot.pck"),
			exe_dir.path_join("../Resources/voxdot.pck").simplify_path()]:
		if FileAccess.file_exists(candidate):
			return PackedStringArray(["--main-pack", candidate, "--", source_path])
	# Embedded pack or an unusual layout: let the runtime decide.
	return PackedStringArray(["--", source_path])


func _show_details(asset_id: String) -> void:
	var a: Dictionary = catalog.asset(asset_id)
	if a.is_empty():
		_clear_details()
		return
	_name_label.text = "%s%s" % [a.get("name", ""),
		"  [Incompatible]" if bool(a.get("has_prefabs", false)) else ""]
	_path_label.text = "%s  (%s)" % [a.get("relative_path", ""), a.get("library", "")]
	_meta_label.text = "%d cells  |  %d lights  |  bounds %dx%dx%d\nasset %s" % [
		int(a.get("cells", 0)), int(a.get("lights", 0)),
		(a.get("bounds", Vector3i.ZERO) as Vector3i).x,
		(a.get("bounds", Vector3i.ZERO) as Vector3i).y,
		(a.get("bounds", Vector3i.ZERO) as Vector3i).z,
		a.get("asset_id", "")]
	_reason_label.text = "" if bool(a.get("valid", false)) else str(a.get("reason", "invalid"))
	_place_button.disabled = not bool(a.get("valid", false))
	_syncing_pivot = true
	var p: Vector3 = a.get("pivot", Vector3.ZERO)
	for i in 3:
		_pivot_spins[i].value = p[i]
	_syncing_pivot = false
	_preview_model = catalog.load_asset(asset_id)
	_rebuild_preview(_preview_model, p)


var _syncing_pivot: bool = false


func _clear_details() -> void:
	_name_label.text = ""
	_path_label.text = ""
	_meta_label.text = ""
	_reason_label.text = ""
	_place_button.disabled = true
	_preview_model = null
	_rebuild_preview(null, Vector3.ZERO)


func _on_pivot_spin(_v: float) -> void:
	if _syncing_pivot or _selected_asset_id == "" or catalog == null:
		return
	var p := Vector3(_pivot_spins[0].value, _pivot_spins[1].value, _pivot_spins[2].value)
	var updated: Dictionary = catalog.set_pivot(_selected_asset_id, p)
	if updated.has("pivot_error"):
		_reason_label.text = str(updated["pivot_error"])
		return
	_reason_label.text = ""
	_update_preview_pivot(updated.get("pivot", p))


func _reset_pivot() -> void:
	if _selected_asset_id == "":
		return
	var updated: Dictionary = catalog.reset_pivot(_selected_asset_id)
	if updated.is_empty():
		return
	_syncing_pivot = true
	var p: Vector3 = updated.get("pivot", Vector3.ZERO)
	for i in 3:
		_pivot_spins[i].value = p[i]
	_syncing_pivot = false
	_update_preview_pivot(p)


# --- Preview ---

func _rebuild_preview(model: VoxelModel, pivot: Vector3) -> void:
	for child: Node in _preview_root.get_children():
		if child != _preview_pivot:
			_preview_root.remove_child(child)
			child.queue_free()
	if model == null:
		_preview_pivot.visible = false
		return
	var mi := MeshInstance3D.new()
	mi.mesh = model.build_mesh()
	_preview_root.add_child(mi)
	var box: AABB = VoxelPrefabInstance.occupied_bounds(model)
	_preview_focus = box.get_center()
	_preview_distance = maxf(box.size.length() * 1.8, 4.0)
	_update_preview_camera()
	_update_preview_pivot(pivot)


func _update_preview_pivot(pivot: Vector3) -> void:
	_preview_pivot.visible = true
	_preview_pivot.position = pivot
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var c := Color(0.35, 1.0, 1.0, 1.0)
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		verts.append(pivot - axis * 0.8)
		verts.append(pivot + axis * 0.8)
		cols.append(c)
		cols.append(c)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	_preview_pivot.mesh = mesh


func _update_preview_camera() -> void:
	if _preview_camera == null:
		return
	var rot := Basis.from_euler(Vector3(_preview_pitch, _preview_yaw, 0.0))
	_preview_camera.position = _preview_focus + rot.z * _preview_distance
	_preview_camera.look_at(_preview_focus)


func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_preview_dragging = true
				_preview_drag_moved = false
				_preview_last_mouse = mb.position
			else:
				if _preview_dragging and not _preview_drag_moved:
					_pick_pivot(mb.position)
				_preview_dragging = false
			_preview_container.accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_preview_distance = clampf(_preview_distance * 0.9, 1.0, 500.0)
			_update_preview_camera()
			_preview_container.accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_preview_distance = clampf(_preview_distance / 0.9, 1.0, 500.0)
			_update_preview_camera()
			_preview_container.accept_event()
	elif event is InputEventMouseMotion and _preview_dragging:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_preview_last_mouse) > 1.0:
			_preview_drag_moved = true
		_preview_yaw -= mm.relative.x * 0.01
		_preview_pitch = clampf(_preview_pitch - mm.relative.y * 0.01,
			deg_to_rad(-85.0), deg_to_rad(85.0))
		_preview_last_mouse = mm.position
		_update_preview_camera()
		_preview_container.accept_event()


## Click a face in the preview to place the pivot there. The intersection is
## approximated at the hit face centre and snapped to the nearest 0.5.
func _pick_pivot(local_pos: Vector2) -> void:
	if _preview_model == null:
		return
	# The container stretches the 320x230 SubViewport, so normalize the click
	# into viewport pixels before projecting the ray.
	var vp_pos: Vector2 = local_pos
	var container_size: Vector2 = _preview_container.size
	if container_size.x > 0.0 and container_size.y > 0.0:
		vp_pos = local_pos / container_size * Vector2(_preview_viewport.size)
	var origin: Vector3 = _preview_camera.project_ray_origin(vp_pos)
	var dir: Vector3 = _preview_camera.project_ray_normal(vp_pos)
	var r: Dictionary = VoxelRaycast.cast(_preview_model.to_grid(), _preview_model.bounds, origin, dir)
	if not r["hit"]:
		return
	var cell: Vector3i = r["pos"]
	var normal: Vector3i = r["normal"]
	var point: Vector3 = Vector3(cell) + Vector3.ONE * 0.5 + Vector3(normal) * 0.5
	var p: Vector3 = VoxelPrefabInstance.snap_pivot(point)
	var updated: Dictionary = catalog.set_pivot(_selected_asset_id, p)
	if updated.has("pivot_error"):
		return
	_syncing_pivot = true
	for i in 3:
		_pivot_spins[i].value = p[i]
	_syncing_pivot = false
	_update_preview_pivot(p)


# --- Problems ---

func _show_assets_view() -> void:
	_grid_scroll.visible = true
	_problems_scroll.visible = false


func _show_problems_view() -> void:
	_grid_scroll.visible = false
	_problems_scroll.visible = true
	_rebuild_problems()


func _rebuild_problems() -> void:
	if _problems_box == null:
		return
	for child: Node in _problems_box.get_children():
		_problems_box.remove_child(child)
		child.queue_free()
	if doc == null:
		return
	var any: bool = false
	for inst: VoxelPrefabInstance in doc.prefab_instances:
		if inst == null:
			continue
		var st: Dictionary = doc.prefab_status(inst.instance_id)
		var state: String = str(st.get("state", "ok"))
		if state == "ok":
			continue
		any = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var src_name: String = inst.source_path.get_file() if inst.source_path != "" else "instance #%d" % inst.instance_id
		label.text = "[%s]  %s  #%d  anchor (%d, %d, %d)\n%s" % [
			state.capitalize(), src_name, inst.instance_id,
			inst.anchor.x, inst.anchor.y, inst.anchor.z, st.get("reason", "")]
		row.add_child(label)
		row.add_child(_button("Select", func() -> void:
			select_instance_requested.emit(inst.instance_id)))
		if state == "missing" or state == "incompatible":
			row.add_child(_button("Relink...", func() -> void:
				_relink_instance_id = inst.instance_id
				_relink_dialog.popup_centered()))
		row.add_child(_button("Delete", func() -> void:
			delete_instance_requested.emit(inst.instance_id)))
		_problems_box.add_child(row)
	if not any:
		var ok := Label.new()
		ok.text = "No prefab problems in this model."
		ok.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
		_problems_box.add_child(ok)


func _update_footer() -> void:
	if _status == null or catalog == null:
		return
	var counts: Dictionary = {"ok": 0, "missing": 0, "conflict": 0, "incompatible": 0}
	if doc != null:
		counts = doc.prefab_status_counts()
	var visible_count: int = _filtered_assets().size()
	_status.text = "%d assets shown · %d in libraries · %d missing · %d conflicted · %d incompatible" % [
		visible_count, catalog.asset_count(),
		int(counts.get("missing", 0)), int(counts.get("conflict", 0)),
		int(counts.get("incompatible", 0))]
