class_name VoxelDocument
extends RefCounted

## Editable voxel grid plus undo/redo, mirroring and file IO. All editor
## tools write through this class, so it is fully testable without a UI.
##
## Edits are grouped into "strokes" (begin_stroke / end_stroke): one stroke is
## one undo step. Strokes may nest; only the outermost end commits.

signal changed
signal history_changed
signal meta_changed

const MIN_BOUND: int = 4
const MAX_BOUND: int = 64
const MAX_HISTORY: int = 200

const NEIGHBORS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

var grid: Dictionary = {}
var bounds: Vector3i = Vector3i(32, 32, 32)
var voxel_size: float = 0.0625
var swatches: PackedColorArray = default_swatches()
var mirror_x: bool = false
var mirror_z: bool = false
var path: String = ""
var dirty: bool = false

var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _stroke: Dictionary = {}
var _stroke_depth: int = 0


static func default_swatches() -> PackedColorArray:
	var out := PackedColorArray()
	for hex: String in [
		"e0a872", "c48852", "4a3222", "78512d", "8a5a2e", "633e1d", "dfb134", "a87e1a",
		"c2c7d1", "9498a1", "686b75", "2f313d", "6e6a63", "565249", "857f75", "5c6e46",
		"3f7d3a", "8fbf4a", "3b3a4f", "3f4559", "9e2a2b", "eb7d22", "ffcf40", "45e3eb",
	]:
		out.append(Color(hex))
	return out


static func box_cells(a: Vector3i, b: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				out.append(Vector3i(x, y, z))
	return out


func in_bounds(p: Vector3i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.z >= 0 \
			and p.x < bounds.x and p.y < bounds.y and p.z < bounds.z


func voxel_count() -> int:
	return grid.size()


func can_undo() -> bool:
	return not _undo_stack.is_empty()


func can_redo() -> bool:
	return not _redo_stack.is_empty()


## Cell plus its mirror images for the active symmetry axes.
func mirrored(p: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = [p]
	if mirror_x:
		out.append(Vector3i(bounds.x - 1 - p.x, p.y, p.z))
	if mirror_z:
		out.append(Vector3i(p.x, p.y, bounds.z - 1 - p.z))
	if mirror_x and mirror_z:
		out.append(Vector3i(bounds.x - 1 - p.x, p.y, bounds.z - 1 - p.z))
	return out


# --- Stroke / history ---

func begin_stroke() -> void:
	_stroke_depth += 1


func end_stroke() -> void:
	_stroke_depth = maxi(_stroke_depth - 1, 0)
	if _stroke_depth > 0:
		return
	var net: Dictionary = {}
	for p: Vector3i in _stroke:
		var pair: Array = _stroke[p]
		if pair[0] != pair[1]:
			net[p] = pair
	_stroke = {}
	if net.is_empty():
		return
	_undo_stack.append(net)
	if _undo_stack.size() > MAX_HISTORY:
		_undo_stack.pop_front()
	_redo_stack.clear()
	dirty = true
	history_changed.emit()
	meta_changed.emit()


func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	var entry: Dictionary = _undo_stack.pop_back()
	for p: Vector3i in entry:
		_apply_raw(p, (entry[p] as Array)[0])
	_redo_stack.append(entry)
	dirty = true
	changed.emit()
	history_changed.emit()
	meta_changed.emit()
	return true


func redo() -> bool:
	if _redo_stack.is_empty():
		return false
	var entry: Dictionary = _redo_stack.pop_back()
	for p: Vector3i in entry:
		_apply_raw(p, (entry[p] as Array)[1])
	_undo_stack.append(entry)
	dirty = true
	changed.emit()
	history_changed.emit()
	meta_changed.emit()
	return true


# --- Editing ---

func place_cells(cells: Array[Vector3i], color: Color) -> void:
	begin_stroke()
	for p in cells:
		for q in mirrored(p):
			_write(q, color)
	end_stroke()
	changed.emit()


func erase_cells(cells: Array[Vector3i]) -> void:
	begin_stroke()
	for p in cells:
		for q in mirrored(p):
			_write(q, null)
	end_stroke()
	changed.emit()


## Recolors only voxels that already exist.
func paint_cells(cells: Array[Vector3i], color: Color) -> void:
	begin_stroke()
	for p in cells:
		for q in mirrored(p):
			if grid.has(q):
				_write(q, color)
	end_stroke()
	changed.emit()


func clear() -> void:
	begin_stroke()
	for p: Vector3i in grid.keys():
		_write(p, null)
	end_stroke()
	changed.emit()


## Cells connected (6-neighbourhood) to `start` that share its color.
func flood_cells(start: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if not grid.has(start):
		return out
	var target: Color = grid[start]
	var seen: Dictionary = {start: true}
	var queue: Array[Vector3i] = [start]
	var head: int = 0
	while head < queue.size():
		var p: Vector3i = queue[head]
		head += 1
		out.append(p)
		for n in NEIGHBORS:
			var q: Vector3i = p + n
			if not seen.has(q) and grid.has(q) and grid[q] == target:
				seen[q] = true
				queue.append(q)
	return out


## Changes the editable volume. Refuses (returns false) if voxels would fall
## outside the new bounds, so resizing never destroys data.
func resize_bounds(new_bounds: Vector3i) -> bool:
	var nb := Vector3i(
		clampi(new_bounds.x, MIN_BOUND, MAX_BOUND),
		clampi(new_bounds.y, MIN_BOUND, MAX_BOUND),
		clampi(new_bounds.z, MIN_BOUND, MAX_BOUND))
	for p: Vector3i in grid:
		if p.x >= nb.x or p.y >= nb.y or p.z >= nb.z:
			return false
	if nb == bounds:
		return true
	bounds = nb
	dirty = true
	changed.emit()
	meta_changed.emit()
	return true


func set_voxel_size(v: float) -> void:
	voxel_size = clampf(v, 0.001, 8.0)
	dirty = true
	meta_changed.emit()


func add_swatch(c: Color) -> void:
	if swatches.has(c):
		return
	swatches.append(c)
	dirty = true
	meta_changed.emit()


func set_mirror(x: bool, z: bool) -> void:
	mirror_x = x
	mirror_z = z
	meta_changed.emit()


# --- Lifecycle / IO ---

func reset() -> void:
	grid = {}
	bounds = Vector3i(32, 32, 32)
	voxel_size = 0.0625
	swatches = default_swatches()
	path = ""
	dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	_stroke = {}
	_stroke_depth = 0
	changed.emit()
	history_changed.emit()
	meta_changed.emit()


func to_model() -> VoxelModel:
	var m := VoxelModel.new()
	m.voxel_size = voxel_size
	m.bounds = bounds
	m.swatches = swatches
	m.set_grid(grid)
	return m


## Loads `m` into this document. Bounds grow (up to MAX_BOUND) to fit its
## voxels. Returns how many voxels were dropped for lying outside the
## editable range (negative coordinates or beyond MAX_BOUND).
func load_model(m: VoxelModel, source_path: String = "") -> int:
	var src: Dictionary = m.to_grid()
	var nb := Vector3i(
		clampi(m.bounds.x, MIN_BOUND, MAX_BOUND),
		clampi(m.bounds.y, MIN_BOUND, MAX_BOUND),
		clampi(m.bounds.z, MIN_BOUND, MAX_BOUND))
	for p: Vector3i in src:
		nb = Vector3i(
			clampi(maxi(nb.x, p.x + 1), MIN_BOUND, MAX_BOUND),
			clampi(maxi(nb.y, p.y + 1), MIN_BOUND, MAX_BOUND),
			clampi(maxi(nb.z, p.z + 1), MIN_BOUND, MAX_BOUND))
	bounds = nb
	grid = {}
	var dropped: int = 0
	for p: Vector3i in src:
		if in_bounds(p):
			grid[p] = src[p]
		else:
			dropped += 1
	voxel_size = m.voxel_size
	swatches = m.swatches if not m.swatches.is_empty() else default_swatches()
	path = source_path
	dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	_stroke = {}
	_stroke_depth = 0
	changed.emit()
	history_changed.emit()
	meta_changed.emit()
	return dropped


func save_file(target: String) -> Error:
	var err: Error = ResourceSaver.save(to_model(), target)
	if err == OK:
		path = target
		dirty = false
		meta_changed.emit()
	return err


func load_file(source: String) -> Error:
	if not ResourceLoader.exists(source):
		return ERR_FILE_NOT_FOUND
	var res: Resource = ResourceLoader.load(source, "", ResourceLoader.CACHE_MODE_IGNORE)
	var m := res as VoxelModel
	if m == null:
		return ERR_FILE_UNRECOGNIZED
	load_model(m, source)
	return OK


# --- Internals ---

func _write(p: Vector3i, color: Variant) -> void:
	if not in_bounds(p):
		return
	var old: Variant = grid.get(p, null)
	if old == color:
		return
	if color == null:
		grid.erase(p)
	else:
		grid[p] = color
	if _stroke.has(p):
		(_stroke[p] as Array)[1] = color
	else:
		_stroke[p] = [old, color]


func _apply_raw(p: Vector3i, color: Variant) -> void:
	if not in_bounds(p):
		return
	if color == null:
		grid.erase(p)
	else:
		grid[p] = color
