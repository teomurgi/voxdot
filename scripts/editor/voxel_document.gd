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

## Last cells written by an edit (cell -> true). Lets the renderer mark just
## the affected chunks dirty instead of scanning the whole grid.
var last_touched: Array[Vector3i] = []
var last_touched_lights: Dictionary = {} # id -> true for add/remove, ID for property edits

const MIN_BOUND: int = 4
const MAX_BOUND: int = 1024
const MAX_HISTORY: int = 200

const NEIGHBORS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

const LIGHT_DEFAULT_ENERGY: float = 1.0
const LIGHT_DEFAULT_RANGE: float = 8.0
const LIGHT_MIN_RANGE: float = 0.25
const LIGHT_MAX_RANGE: float = 512.0
const LIGHT_MAX_ENERGY: float = 16.0
const MAX_LIGHTS: int = 32
const DEFAULT_SUN_ENERGY: float = 1.0
const DEFAULT_SUN_YAW: float = 35.0
const DEFAULT_SUN_PITCH: float = -50.0
const MAX_SUN_ENERGY: float = 16.0
const SUN_YAW_RANGE: float = 360.0
const SUN_PITCH_MIN: float = -89.9
const SUN_PITCH_MAX: float = 89.9

var grid: Dictionary = {}
## Point lights: integer ID -> {position: Vector3, color: Color,
## energy: float, range: float, shadows: bool}. All IDs are positive.
var lights: Dictionary = {}
var bounds: Vector3i = Vector3i(32, 32, 32)
var voxel_size: float = 0.0625
var swatches: PackedColorArray = default_swatches()
var mirror_x: bool = false
var mirror_z: bool = false
## Directional sun saved with the model (see VoxelModel). Not undoable, like
## the mirror flags.
var sun_energy: float = DEFAULT_SUN_ENERGY
var sun_yaw: float = DEFAULT_SUN_YAW
var sun_pitch: float = DEFAULT_SUN_PITCH
var sun_color: Color = Color(1, 1, 1)
var sun_shadows: bool = true
var path: String = ""
var dirty: bool = false

var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _stroke: Dictionary = {}
var _light_history: Dictionary = {}
var _stroke_depth: int = 0
var _next_light_id: int = 1


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
	var net_lights: Dictionary = {}
	for id: int in _light_history:
		var pair: Array = _light_history[id]
		if pair[0] != pair[1]:
			net_lights[id] = pair
	_light_history = {}
	if net.is_empty() and net_lights.is_empty():
		return
	# Namespaced keys keep voxel and light history in the same undo step
	# without making Vector3i and integer IDs collide.
	_undo_stack.append({"voxels": net, "lights": net_lights})
	if _undo_stack.size() > MAX_HISTORY:
		_undo_stack.pop_front()
	_redo_stack.clear()
	dirty = true
	history_changed.emit()
	meta_changed.emit()


func _is_legacy_history(entry: Dictionary) -> bool:
	return not entry.has("voxels") and not entry.has("lights")


func _apply_light_history(entry: Dictionary, side: int) -> void:
	last_touched_lights.clear()
	for id: int in entry.get("lights", {}):
		var value: Variant = entry["lights"][id][side]
		if value == null:
			lights.erase(id)
		else:
			lights[id] = (value as Dictionary).duplicate(true)
		last_touched_lights[id] = true
	_recompute_next_light_id()


func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	var entry: Dictionary = _undo_stack.pop_back()
	if _is_legacy_history(entry):
		for p: Vector3i in entry:
			_apply_raw(p, (entry[p] as Array)[0])
	else:
		for p: Vector3i in entry.get("voxels", {}):
			_apply_raw(p, (entry["voxels"][p] as Array)[0])
		_apply_light_history(entry, 0)
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
	if _is_legacy_history(entry):
		for p: Vector3i in entry:
			_apply_raw(p, (entry[p] as Array)[1])
	else:
		for p: Vector3i in entry.get("voxels", {}):
			_apply_raw(p, (entry["voxels"][p] as Array)[1])
		_apply_light_history(entry, 1)
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


## Writes many cells of different colors as one stroke (one undo step).
## `cells` maps Vector3i -> Color; mirror applies like place_cells.
## Returns the number of cells whose value actually changed.
func write_cells(cells: Dictionary) -> int:
	begin_stroke()
	var written: int = 0
	for p: Vector3i in cells:
		for q in mirrored(p):
			if _write(q, cells[p]):
				written += 1
	end_stroke()
	changed.emit()
	return written


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


## Changes the editable volume. Refuses if voxels or lights would fall outside.
func resize_bounds(new_bounds: Vector3i) -> bool:
	var nb := Vector3i(
		clampi(new_bounds.x, MIN_BOUND, MAX_BOUND),
		clampi(new_bounds.y, MIN_BOUND, MAX_BOUND),
		clampi(new_bounds.z, MIN_BOUND, MAX_BOUND))
	for p: Vector3i in grid:
		if p.x >= nb.x or p.y >= nb.y or p.z >= nb.z:
			return false
	for id: int in lights:
		var p: Vector3 = lights[id]["position"]
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


## Sets the directional sun saved with the model. Values are clamped to the
## same ranges the editor and MCP accept. Like set_mirror, not undoable.
func set_sun(properties: Dictionary) -> bool:
	var e: float = clampf(float(properties.get("energy", sun_energy)), 0.0, MAX_SUN_ENERGY)
	var y: float = wrapf(clampf(float(properties.get("yaw", sun_yaw)), -SUN_YAW_RANGE, SUN_YAW_RANGE), -180.0, 180.0)
	var p: float = clampf(float(properties.get("pitch", sun_pitch)), SUN_PITCH_MIN, SUN_PITCH_MAX)
	var c: Color = Color(properties.get("color", sun_color))
	var s: bool = bool(properties.get("shadows", sun_shadows))
	if is_equal_approx(e, sun_energy) and is_equal_approx(y, sun_yaw) and is_equal_approx(p, sun_pitch) \
			and c.is_equal_approx(sun_color) and s == sun_shadows:
		return false
	sun_energy = e
	sun_yaw = y
	sun_pitch = p
	sun_color = c
	sun_shadows = s
	dirty = true
	meta_changed.emit()
	return true


# --- Point lights ---

func light_in_bounds(position: Vector3) -> bool:
	return position.x >= 0 and position.y >= 0 and position.z >= 0 \
			and position.x < bounds.x and position.y < bounds.y and position.z < bounds.z


static func normalized_light(light: Dictionary) -> Dictionary:
	var p: Variant = light.get("position", Vector3.ZERO)
	var position := Vector3(p) if p is Vector3 else Vector3.ZERO
	return {
		"position": position,
		"color": Color(light.get("color", Color("ffd9a0"))),
		"energy": clampf(float(light.get("energy", LIGHT_DEFAULT_ENERGY)), 0.0, LIGHT_MAX_ENERGY),
		"range": clampf(float(light.get("range", LIGHT_DEFAULT_RANGE)), LIGHT_MIN_RANGE, LIGHT_MAX_RANGE),
		"shadows": bool(light.get("shadows", true)),
	}


func add_light(light: Dictionary) -> int:
	if lights.size() >= MAX_LIGHTS:
		return -1
	var l: Dictionary = normalized_light(light)
	if not light_in_bounds(l["position"]):
		return -1
	var id: int = _next_light_id
	_next_light_id += 1
	begin_stroke()
	_light_before(id)
	lights[id] = l
	_light_after(id)
	last_touched_lights[id] = true
	end_stroke() # Nested calls are grouped by an enclosing light drag.
	changed.emit()
	meta_changed.emit()
	return id


func update_light(id: int, properties: Dictionary) -> bool:
	if not lights.has(id):
		return false
	var l: Dictionary = (lights[id] as Dictionary).duplicate(true)
	if properties.has("position"):
		l["position"] = properties["position"]
	if properties.has("color"):
		l["color"] = properties["color"]
	for key: String in ["energy", "range", "shadows"]:
		if properties.has(key):
			l[key] = properties[key]
	l = normalized_light(l)
	if not light_in_bounds(l["position"]) or l == lights[id]:
		return false
	begin_stroke() # No-op while a drag already holds the stroke open.
	_light_before(id)
	lights[id] = l
	_light_after(id)
	last_touched_lights[id] = id
	end_stroke()
	changed.emit()
	meta_changed.emit()
	return true


func remove_light(id: int) -> bool:
	if not lights.has(id):
		return false
	begin_stroke()
	_light_before(id)
	lights.erase(id)
	_light_after(id)
	last_touched_lights[id] = true
	end_stroke()
	changed.emit()
	meta_changed.emit()
	return true


func _light_before(id: int) -> void:
	if not _light_history.has(id):
		_light_history[id] = [(lights[id] as Dictionary).duplicate(true) if lights.has(id) else null, null]


func _light_after(id: int) -> void:
	_light_history[id][1] = (lights[id] as Dictionary).duplicate(true) if lights.has(id) else null


func _recompute_next_light_id() -> void:
	_next_light_id = 1
	for id: int in lights:
		_next_light_id = maxi(_next_light_id, id + 1)


# --- Lifecycle / IO ---

func reset() -> void:
	grid = {}
	lights = {}
	bounds = Vector3i(32, 32, 32)
	voxel_size = 0.0625
	swatches = default_swatches()
	sun_energy = DEFAULT_SUN_ENERGY
	sun_yaw = DEFAULT_SUN_YAW
	sun_pitch = DEFAULT_SUN_PITCH
	sun_color = Color(1, 1, 1)
	sun_shadows = true
	path = ""
	dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	_stroke = {}
	_light_history = {}
	_stroke_depth = 0
	_next_light_id = 1
	last_touched.clear()
	last_touched_lights.clear()
	changed.emit()
	history_changed.emit()
	meta_changed.emit()


func to_model() -> VoxelModel:
	var m := VoxelModel.new()
	m.voxel_size = voxel_size
	m.bounds = bounds
	m.swatches = swatches
	m.lights = packed_lights()
	m.sun_energy = sun_energy
	m.sun_yaw = sun_yaw
	m.sun_pitch = sun_pitch
	m.sun_color = sun_color
	m.sun_shadows = sun_shadows
	m.set_grid(grid)
	return m


## Loads `m` into this document. Bounds grow (up to MAX_BOUND) to fit its
## voxels. Returns how many voxels were dropped for lying outside the
## editable range (negative coordinates or beyond MAX_BOUND, 1024).
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
	lights = {}
	var dropped_lights: int = 0
	var packed: PackedFloat32Array = m.lights
	if packed.size() % VoxelModel.LIGHT_STRIDE != 0:
		push_warning("Ignoring truncated light data in " + source_path)
	for i in range(0, packed.size() - VoxelModel.LIGHT_STRIDE + 1, VoxelModel.LIGHT_STRIDE):
		var l: Dictionary = normalized_light({
			"position": Vector3(packed[i + 1], packed[i + 2], packed[i + 3]),
			"color": Color(packed[i + 4], packed[i + 5], packed[i + 6]),
			"energy": packed[i + 7],
			"range": packed[i + 8],
			"shadows": packed[i + 9] > 0.5,
		})
		var id: int = int(packed[i])
		if id > 0 and not lights.has(id) and light_in_bounds(l["position"]):
			lights[id] = l
		else:
			dropped_lights += 1
	_recompute_next_light_id()
	grid = {}
	var dropped: int = 0
	for p: Vector3i in src:
		if in_bounds(p):
			grid[p] = src[p]
		else:
			dropped += 1
	voxel_size = m.voxel_size
	swatches = m.swatches if not m.swatches.is_empty() else default_swatches()
	sun_energy = clampf(m.sun_energy, 0.0, MAX_SUN_ENERGY)
	sun_yaw = wrapf(m.sun_yaw, -180.0, 180.0)
	sun_pitch = clampf(m.sun_pitch, SUN_PITCH_MIN, SUN_PITCH_MAX)
	sun_color = m.sun_color
	sun_shadows = m.sun_shadows
	path = source_path
	dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	_stroke = {}
	_light_history = {}
	_stroke_depth = 0
	last_touched.clear()
	last_touched_lights.clear()
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


func packed_lights() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var ids: Array = lights.keys()
	ids.sort()
	for id: int in ids:
		var l: Dictionary = lights[id]
		var p: Vector3 = l["position"]
		var c: Color = l["color"]
		out.append_array(PackedFloat32Array([id, p.x, p.y, p.z, c.r, c.g, c.b,
			l["energy"], l["range"], 1.0 if l["shadows"] else 0.0]))
	return out


# --- Internals ---

func _write(p: Vector3i, color: Variant) -> bool:
	if not in_bounds(p):
		return false
	var old: Variant = grid.get(p, null)
	if old == color:
		return false
	if color == null:
		grid.erase(p)
	else:
		grid[p] = color
	if _stroke.has(p):
		(_stroke[p] as Array)[1] = color
	else:
		_stroke[p] = [old, color]
	last_touched.append(p)
	return true


func _apply_raw(p: Vector3i, color: Variant) -> void:
	if not in_bounds(p):
		return
	if color == null:
		grid.erase(p)
	else:
		grid[p] = color
