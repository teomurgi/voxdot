extends SceneTree

## Generates the README screenshots by driving the editor scene directly and
## grabbing the rendered frame, so no compositor or mouse is involved.
##
## Run: godot --path . -s tools/make_screenshots.gd
##
## Writes PNGs to docs/screenshots/.

const OUT_DIR: String = "res://docs/screenshots"

const C_STONE := Color("6e6a63")
const C_STONE_DARK := Color("565249")
const C_STONE_LIGHT := Color("857f75")
const C_MOSS := Color("5c6e46")
const C_GRASS := Color("4a6b33")
const C_DIRT := Color("3f3226")
const C_ROOF := Color("3b3a4f")
const C_ROOF_DARK := Color("2c2b3c")
const C_WOOD := Color("6e4a26")
const C_WOOD_DARK := Color("4a3222")
const C_BANNER := Color("8f2d2d")
const C_GOLD := Color("dfb134")
const C_GLASS := Color("1b2a3a")
const C_FIRE := Color("eb7d22")

const SHOT_SIZE := Vector2i(1440, 900)

var _ed: VoxelModelEditor
var _view: SubViewport


func _initialize() -> void:
	_view = SubViewport.new()
	_view.size = SHOT_SIZE
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view.transparent_bg = false
	_view.handle_input_locally = false
	root.add_child(_view)
	_ed = (load("res://scenes/voxdot.tscn") as PackedScene).instantiate() as VoxelModelEditor
	_view.add_child(_ed)
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	# Drive everything by hand: the editor's _process would overwrite the
	# hover state with a mouse ray we do not have.
	_ed.set_process(false)
	await _shot_editor()
	await _shot_height_lock()
	await _shot_box_tool()
	await _shot_lighting()
	print("screenshots written to ", ProjectSettings.globalize_path(OUT_DIR))
	quit()


func _grab(file_name: String) -> void:
	await process_frame
	await process_frame
	var img: Image = _view.get_texture().get_image()
	var path: String = ProjectSettings.globalize_path(OUT_DIR.path_join(file_name))
	img.save_png(path)
	print("  ", path, "  ", img.get_size())


## Sets the document contents and frames the camera on the result. Assigning
## `doc.grid` directly does not emit `last_touched`, so mark the document as
## replaced to route the change through `_on_doc_reset()`, which rebuilds the
## chunk records (the chunk renderer keeps its own cell index).
func _load_model(grid: Dictionary, voxel_size: float = 0.0625) -> void:
	_ed.doc.reset()
	_ed.doc.set_voxel_size(voxel_size)
	_ed.doc.grid = grid
	_ed._doc_replaced = true
	_ed.doc.changed.emit()
	_ed._rebuild_mesh()


## --- Shot 1: the editor with a finished model ---

func _shot_editor() -> void:
	_load_model(_build_castle())
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)
	_ed._set_color(Color("c2c7d1"))
	_ed._hover = {"valid": true, "cell": Vector3i(14, 10, 14), "normal": Vector3i.UP, "face_coord": 10.0}
	_ed._update_ghost()
	_frame(Vector3(13, 6, 13), 37.0)
	await _grab("01-editor.png")


## --- Shot 2: height lock, building on a work plane ---

func _shot_height_lock() -> void:
	_load_model(_build_construction())
	_ed._set_tool(VoxelModelEditor.Tool.PLACE)
	_ed._set_color(Color("dfb134"))
	_ed._set_layer(9)
	_ed._set_color(Color("dfb134"))
	_ed._hover = {"valid": true, "cell": Vector3i(7, 9, 7), "normal": Vector3i.UP, "face_coord": 9.0}
	_ed._update_ghost()
	_frame(Vector3(11, 6, 11), 33.0)
	await _grab("02-height-lock.png")


## --- Shot 3: the box tool previewing an extrusion ---

func _shot_box_tool() -> void:
	_load_model(_build_castle())
	_ed.set_process(false)
	# Reset the state left over from the previous shot.
	_ed._set_layer(0)
	_ed._set_height_lock(false)
	_ed._set_tool(VoxelModelEditor.Tool.BOX)
	_ed._depth_spin.value = 4
	_ed._set_color(Color("45e3eb"))
	_ed._stroke_tool = VoxelModelEditor.Tool.BOX
	_ed._stroking = true
	_ed._plane_axis = 1
	_ed._plane_normal = Vector3i.UP
	_ed._plane_layer = 0
	_ed._plane_coord = 0.0
	_ed._stroke_start = Vector3i(9, 0, 19)
	_ed._box_end = Vector3i(15, 0, 23)
	_ed._update_ghost()
	_frame(Vector3(13, 6, 13), 37.0)
	await _grab("03-box-tool.png")
	_ed._stroking = false


## --- Shot 4: point lights + the directional sun ---

func _shot_lighting() -> void:
	_load_model(_build_castle())
	_ed._set_height_lock(false)
	_ed._set_layer(0)
	_ed._set_tool(VoxelModelEditor.Tool.LIGHT_EDIT)
	# Dusk sun: low, warm, long shadows.
	_ed.doc.set_sun({"energy": 0.45, "yaw": 118.0, "pitch": -16.0, "color": Color("ffb27a"), "shadows": true})
	# Braziers by the gate plus two warm lanterns on the path.
	var ids: Array[int] = []
	ids.append(_ed.add_point_light(Vector3(9.5, 3.5, 22.5), Color("ff9a3c"), 4.0, 16.0))
	ids.append(_ed.add_point_light(Vector3(16.5, 3.5, 22.5), Color("ff9a3c"), 4.0, 16.0))
	ids.append(_ed.add_point_light(Vector3(12.5, 3.0, 12.5), Color("ffd28a"), 2.5, 12.0))
	ids.append(_ed.add_point_light(Vector3(13.5, 3.0, 12.5), Color("ffd28a"), 2.5, 12.0))
	_ed._select_light(ids[0])
	# Show the lighting inspector, but fold the drawing sections so it fits.
	_set_section("Tool", false)
	_set_section("Color", false)
	_set_section("Lighting", true)
	_ed._hover = {"valid": false}
	_ed._update_ghost()
	_ed._yaw = deg_to_rad(42.0)
	_ed._pitch = deg_to_rad(-20.0)
	_frame(Vector3(13, 6, 13), 40.0)
	_ed.light_rig.update_handle_scales(_ed.camera)
	await _grab("04-lighting.png")


## Expands/collapses a side-panel section by name.
func _set_section(name: String, expanded: bool) -> void:
	var headers: Array[Button] = []
	_collect_headers(_ed.get_node("UI"), headers)
	for h: Button in headers:
		if h.text.contains(name):
			var is_open: bool = h.text.begins_with("▼")
			if is_open != expanded:
				h.pressed.emit()


func _collect_headers(node: Node, out: Array[Button]) -> void:
	for child in node.get_children():
		if child is Button and (child.text.begins_with("▼") or child.text.begins_with("▶")):
			out.append(child)
		_collect_headers(child, out)


## Points the camera at a spot from the current yaw/pitch.
func _frame(center: Vector3, distance: float) -> void:
	_ed._focus = center
	_ed._distance = distance
	_ed._update_camera()


# --- Model building ---

func _build_castle() -> Dictionary:
	var g: Dictionary = {}
	# Ground
	VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(26, 1, 26), C_GRASS)
	for i in range(26):
		g[Vector3i(i, 0, 0)] = C_DIRT
		g[Vector3i(i, 0, 25)] = C_DIRT
		g[Vector3i(0, 0, i)] = C_DIRT
		g[Vector3i(25, 0, i)] = C_DIRT
	# Cobblestone path from the gate to the keep
	for i in range(26):
		g[Vector3i(12, 0, i)] = C_STONE_DARK if i % 2 == 0 else C_STONE
		g[Vector3i(13, 0, i)] = C_STONE
	# Curtain walls with crenellations
	for i in range(26):
		var h: int = 5
		VoxelMeshBuilder.fill_box(g, Vector3i(i, 1, 0), Vector3i(1, h, 1), C_STONE)
		VoxelMeshBuilder.fill_box(g, Vector3i(i, 1, 25), Vector3i(1, h, 1), C_STONE)
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, i), Vector3i(1, h, 1), C_STONE)
		VoxelMeshBuilder.fill_box(g, Vector3i(25, 1, i), Vector3i(1, h, 1), C_STONE)
		if i % 2 == 0:
			VoxelMeshBuilder.fill_box(g, Vector3i(i, 1 + h, 0), Vector3i(1, 1, 1), C_STONE_LIGHT)
			VoxelMeshBuilder.fill_box(g, Vector3i(i, 1 + h, 25), Vector3i(1, 1, 1), C_STONE_LIGHT)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 1 + h, i), Vector3i(1, 1, 1), C_STONE_LIGHT)
			VoxelMeshBuilder.fill_box(g, Vector3i(25, 1 + h, i), Vector3i(1, 1, 1), C_STONE_LIGHT)
	# Gate on the south wall
	VoxelMeshBuilder.fill_box(g, Vector3i(11, 1, 25), Vector3i(4, 4, 1), C_WOOD_DARK)
	VoxelMeshBuilder.fill_box(g, Vector3i(12, 1, 25), Vector3i(2, 3, 1), C_WOOD)
	VoxelMeshBuilder.fill_box(g, Vector3i(11, 5, 25), Vector3i(4, 1, 1), C_STONE_LIGHT)
	for x in range(11, 15):
		g[Vector3i(x, 1, 25)] = C_STONE_DARK
		g[Vector3i(x, 2, 25)] = C_STONE_DARK
		g[Vector3i(x, 3, 25)] = C_WOOD
		g[Vector3i(x, 4, 25)] = C_WOOD
	# Corner towers with conical roofs
	for corner: Vector2i in [Vector2i(0, 0), Vector2i(23, 0), Vector2i(0, 23), Vector2i(23, 23)]:
		_tower(g, corner)
	# Keep in the middle
	VoxelMeshBuilder.fill_box(g, Vector3i(8, 1, 8), Vector3i(10, 9, 10), C_STONE)
	VoxelMeshBuilder.fill_box(g, Vector3i(9, 1, 9), Vector3i(8, 9, 8), C_STONE_LIGHT)
	VoxelMeshBuilder.fill_box(g, Vector3i(8, 10, 8), Vector3i(10, 1, 10), C_STONE_DARK)
	# Pitched roof: each course is two voxels smaller and one higher
	for i in range(5):
		var size: int = 10 - i * 2
		var off: int = 8 + i
		VoxelMeshBuilder.fill_box(g, Vector3i(off, 11 + i, off), Vector3i(size, 1, size), C_ROOF if i % 2 == 0 else C_ROOF_DARK)
	VoxelMeshBuilder.fill_box(g, Vector3i(12, 16, 12), Vector3i(1, 2, 1), C_GOLD)
	# Keep windows: recolour the wall face so they sit flush
	for y in [4, 7]:
		for dx in [12, 13]:
			g[Vector3i(dx, y, 7)] = C_GLASS
			g[Vector3i(dx, y + 1, 7)] = C_GLASS
			g[Vector3i(dx, y, 18)] = C_GLASS
			g[Vector3i(dx, y + 1, 18)] = C_GLASS
		for dz in [12, 13]:
			g[Vector3i(7, y, dz)] = C_GLASS
			g[Vector3i(7, y + 1, dz)] = C_GLASS
			g[Vector3i(18, y, dz)] = C_GLASS
			g[Vector3i(18, y + 1, dz)] = C_GLASS
	# Banners on the west and east walls
	for z: int in [6, 19]:
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, z), Vector3i(1, 4, 2), C_BANNER)
		VoxelMeshBuilder.fill_box(g, Vector3i(25, 2, z), Vector3i(1, 4, 2), C_BANNER)
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 6, z), Vector3i(1, 1, 2), C_GOLD)
		VoxelMeshBuilder.fill_box(g, Vector3i(25, 6, z), Vector3i(1, 1, 2), C_GOLD)
	# Braziers beside the gate
	for x: int in [9, 16]:
		VoxelMeshBuilder.fill_box(g, Vector3i(x, 1, 22), Vector3i(1, 2, 1), C_WOOD)
		g[Vector3i(x, 3, 22)] = C_FIRE
	# Mossy patches on the walls
	g[Vector3i(4, 3, 0)] = C_MOSS
	g[Vector3i(21, 2, 25)] = C_MOSS
	return g


func _tower(g: Dictionary, corner: Vector2i) -> void:
	var x0: int = corner.x
	var z0: int = corner.y
	VoxelMeshBuilder.fill_box(g, Vector3i(x0, 1, z0), Vector3i(3, 8, 3), C_STONE)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0 + 1, 1, z0 + 1), Vector3i(1, 8, 1), C_STONE_LIGHT)
	# Battlement
	VoxelMeshBuilder.fill_box(g, Vector3i(x0, 9, z0), Vector3i(3, 1, 3), C_STONE_DARK)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0, 10, z0), Vector3i(1, 1, 1), C_STONE_LIGHT)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0 + 2, 10, z0), Vector3i(1, 1, 1), C_STONE_LIGHT)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0, 10, z0 + 2), Vector3i(1, 1, 1), C_STONE_LIGHT)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0 + 2, 10, z0 + 2), Vector3i(1, 1, 1), C_STONE_LIGHT)
	# Stepped conical roof, overhanging the tower by one voxel
	VoxelMeshBuilder.fill_box(g, Vector3i(x0 - 1, 10, z0 - 1), Vector3i(5, 1, 5), C_ROOF)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0, 11, z0), Vector3i(3, 1, 3), C_ROOF_DARK)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0 + 1, 12, z0 + 1), Vector3i(1, 1, 1), C_ROOF)
	VoxelMeshBuilder.fill_box(g, Vector3i(x0 + 1, 13, z0 + 1), Vector3i(1, 1, 1), C_GOLD)
	# Arrow slits, flush with the tower wall
	g[Vector3i(x0 + 1, 5, z0)] = C_GLASS
	g[Vector3i(x0 + 1, 6, z0)] = C_GLASS
	g[Vector3i(x0 + 1, 5, z0 + 2)] = C_GLASS
	g[Vector3i(x0 + 1, 6, z0 + 2)] = C_GLASS


## A tower under construction with a floor plate being laid at layer 9:
## used for the height-lock shot.
func _build_construction() -> Dictionary:
	var g: Dictionary = {}
	VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(24, 1, 24), C_STONE_DARK)
	# Foundation
	VoxelMeshBuilder.fill_box(g, Vector3i(9, 1, 9), Vector3i(6, 2, 6), C_STONE)
	VoxelMeshBuilder.fill_box(g, Vector3i(10, 1, 10), Vector3i(4, 2, 4), C_STONE_LIGHT)
	# Tower shaft rising through the work plane at layer 9
	VoxelMeshBuilder.fill_box(g, Vector3i(10, 3, 10), Vector3i(4, 11, 4), C_STONE)
	VoxelMeshBuilder.fill_box(g, Vector3i(11, 3, 11), Vector3i(2, 11, 2), C_STONE_LIGHT)
	# Battlement at the top
	VoxelMeshBuilder.fill_box(g, Vector3i(9, 14, 9), Vector3i(6, 1, 6), C_STONE_DARK)
	for p: Vector3i in [Vector3i(9, 15, 9), Vector3i(14, 15, 9), Vector3i(9, 15, 14), Vector3i(14, 15, 14)]:
		VoxelMeshBuilder.fill_box(g, p, Vector3i(1, 1, 1), C_STONE_LIGHT)
	# A walkway being laid at exactly layer 9, out over the courtyard
	VoxelMeshBuilder.fill_box(g, Vector3i(4, 9, 10), Vector3i(6, 1, 3), C_STONE_LIGHT)
	VoxelMeshBuilder.fill_box(g, Vector3i(15, 9, 11), Vector3i(5, 1, 2), C_STONE_LIGHT)
	# A banner hanging under the walkway
	VoxelMeshBuilder.fill_box(g, Vector3i(6, 6, 10), Vector3i(2, 3, 1), C_BANNER)
	VoxelMeshBuilder.fill_box(g, Vector3i(6, 9, 10), Vector3i(2, 1, 1), C_GOLD)
	return g
