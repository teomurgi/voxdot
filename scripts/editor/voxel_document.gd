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
## Emitted when linked prefab instances are added, removed, moved, relinked,
## refreshed or unpacked. `changed` also fires so the renderer can rebuild.
signal prefabs_changed

## Last cells written by an edit (cell -> true). Lets the renderer mark just
## the affected chunks dirty instead of scanning the whole grid.
var last_touched: Array[Vector3i] = []
var last_touched_lights: Dictionary = {} # id -> true for add/remove, ID for property edits
## Column keys (Vector2i, 64-cell columns) whose composed prefab cells changed.
var last_touched_prefab_chunks: Dictionary = {} # Vector2i -> true
## Instance IDs whose placement changed, for selection/UI refresh.
var last_touched_prefabs: Dictionary = {} # instance_id -> true

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

## Linked prefab placements, in composition order. This list is authoritative;
## `prefab_composition` is a derived spatial index kept in sync by every
## mutating method below.
var prefab_instances: Array[VoxelPrefabInstance] = []
## Soft editor warning threshold for instance lights, saved with the parent.
var prefab_light_budget: int = 64
var prefab_composition: VoxelPrefabComposition = VoxelPrefabComposition.new()

var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _stroke: Dictionary = {}
var _light_history: Dictionary = {}
var _prefab_history: Dictionary = {} # id -> [before, after, before_index]
var _stroke_depth: int = 0
var _next_light_id: int = 1
var _next_prefab_id: int = 1
## Set while unpacking: lets `_write` replace cells owned by the instance
## being unpacked, which is the one deliberate overlap.
var _allow_owned_writes: bool = false


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
	var net_prefabs: Dictionary = {}
	for id: int in _prefab_history:
		var record: Array = _prefab_history[id]
		var before: VoxelPrefabInstance = record[0]
		var after: VoxelPrefabInstance = record[1]
		if not _same_prefab_snapshot(before, after):
			net_prefabs[id] = record
	_prefab_history = {}
	if net.is_empty() and net_lights.is_empty() and net_prefabs.is_empty():
		return
	# Namespaced keys keep voxel, light and prefab history in the same undo
	# step without making Vector3i and integer IDs collide.
	_undo_stack.append({"voxels": net, "lights": net_lights, "prefabs": net_prefabs})
	if _undo_stack.size() > MAX_HISTORY:
		_undo_stack.pop_front()
	_redo_stack.clear()
	dirty = true
	history_changed.emit()
	meta_changed.emit()


func _is_legacy_history(entry: Dictionary) -> bool:
	return not entry.has("voxels") and not entry.has("lights") and not entry.has("prefabs")


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
		# Voxels first: an unpacked instance is restored only after the
		# content it produced has been removed.
		for p: Vector3i in entry.get("voxels", {}):
			_apply_raw(p, (entry["voxels"][p] as Array)[0])
		_apply_light_history(entry, 0)
		_apply_prefab_history(entry, 0)
	_redo_stack.append(entry)
	dirty = true
	changed.emit()
	prefabs_changed.emit()
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
		# Prefabs first: unpacking removes the instance before its content
		# is written back.
		_apply_prefab_history(entry, 1)
		for p: Vector3i in entry.get("voxels", {}):
			_apply_raw(p, (entry["voxels"][p] as Array)[1])
		_apply_light_history(entry, 1)
	_undo_stack.append(entry)
	dirty = true
	changed.emit()
	prefabs_changed.emit()
	history_changed.emit()
	meta_changed.emit()
	return true


## True when two history snapshots describe the same authored placement.
## `source` is compared by reference: relinking is a real change, a refresh
## (which is not undoable) is not.
func _same_prefab_snapshot(a: VoxelPrefabInstance, b: VoxelPrefabInstance) -> bool:
	if a == null or b == null:
		return a == b
	return a.instance_id == b.instance_id and a.asset_id == b.asset_id \
			and a.source == b.source and a.source_path == b.source_path \
			and a.source_uid == b.source_uid and a.source_bounds == b.source_bounds \
			and a.pivot == b.pivot and a.anchor == b.anchor \
			and a.yaw_quarters == b.yaw_quarters


func _apply_prefab_history(entry: Dictionary, side: int) -> void:
	var records: Dictionary = entry.get("prefabs", {})
	if records.is_empty():
		return
	for id: int in records:
		var record: Array = records[id]
		var snapshot: VoxelPrefabInstance = record[side]
		var index: int = int(record[2]) if record.size() > 2 else prefab_instances.size()
		var old_cells: Array[Vector3i] = prefab_composition.world_cells(id)
		_remove_prefab_from_list(id)
		if snapshot != null:
			var inst: VoxelPrefabInstance = snapshot.copy_for_save()
			var at: int = clampi(index, 0, prefab_instances.size())
			prefab_instances.insert(at, inst)
			prefab_composition.insert_instance(inst, grid, bounds)
			_mark_prefab_chunks(old_cells)
			_mark_prefab_chunks(prefab_composition.world_cells(id))
		else:
			_mark_prefab_chunks(old_cells)
		last_touched_prefabs[id] = true
	_recompute_next_prefab_id()


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
	# Valid linked content is solid: resizing must never clip it. Placeholders
	# are not part of the composition and do not block a resize.
	if prefab_composition.valid_cells_outside(nb) or prefab_composition.valid_lights_outside(nb):
		return false
	if nb == bounds:
		return true
	bounds = nb
	dirty = true
	changed.emit()
	meta_changed.emit()
	return true


## Smallest bounds with the origin fixed at 0 that contain every solid piece of
## content: local voxels, valid linked prefab cells and point lights. Returns
## Vector3i.ZERO when the document has no content. Missing/conflicted prefab
## placeholders are not solid and do not contribute, matching resize_bounds().
func content_extent() -> Vector3i:
	var extent := Vector3i.ZERO
	for p: Vector3i in grid:
		extent = Vector3i(
			maxi(extent.x, p.x + 1),
			maxi(extent.y, p.y + 1),
			maxi(extent.z, p.z + 1))
	for inst: VoxelPrefabInstance in prefab_instances:
		if str(prefab_composition.status_for(inst.instance_id).get("state", "ok")) != "ok":
			continue
		var box: AABB = prefab_composition.bounds_for(inst.instance_id)
		if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
			continue
		extent = Vector3i(
			maxi(extent.x, ceili(box.end.x)),
			maxi(extent.y, ceili(box.end.y)),
			maxi(extent.z, ceili(box.end.z)))
	for id: int in lights:
		var p: Vector3 = lights[id]["position"]
		extent = Vector3i(
			maxi(extent.x, floori(p.x) + 1),
			maxi(extent.y, floori(p.y) + 1),
			maxi(extent.z, floori(p.z) + 1))
	if extent == Vector3i.ZERO:
		return Vector3i.ZERO
	return Vector3i(
		clampi(extent.x, MIN_BOUND, MAX_BOUND),
		clampi(extent.y, MIN_BOUND, MAX_BOUND),
		clampi(extent.z, MIN_BOUND, MAX_BOUND))


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


# --- Prefabs ---

## Sets the soft instance-light budget (not a hard cap). Saved with the model.
func set_prefab_light_budget(value: int) -> bool:
	var b: int = clampi(value, 0, 4096)
	if b == prefab_light_budget:
		return false
	prefab_light_budget = b
	dirty = true
	meta_changed.emit()
	return true


func prefab_instance(id: int) -> VoxelPrefabInstance:
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst != null and inst.instance_id == id:
			return inst
	return null


func prefab_at(cell: Vector3i) -> int:
	return prefab_composition.owner_at(cell)


func prefab_world_cells(id: int) -> Array[Vector3i]:
	return prefab_composition.world_cells(id)


func prefab_world_lights(id: int) -> Array[Dictionary]:
	return prefab_composition.world_lights(id)


func prefab_bounds(id: int) -> AABB:
	return prefab_composition.bounds_for(id)


func prefab_status(id: int) -> Dictionary:
	return prefab_composition.status_for(id)


func prefab_light_count() -> int:
	return prefab_composition.light_count()


func prefab_cell_count() -> int:
	return prefab_composition.total_cells()


func prefab_status_counts() -> Dictionary:
	return prefab_composition.status_counts()


func has_prefab_problems() -> bool:
	var counts: Dictionary = prefab_status_counts()
	return int(counts.get("missing", 0)) > 0 or int(counts.get("conflict", 0)) > 0 \
			or int(counts.get("incompatible", 0)) > 0


func prefab_light_budget_exceeded() -> bool:
	return prefab_light_count() > prefab_light_budget


## Places a linked instance. The caller resolves `source` (the catalogue has
## already loaded it); the document re-validates bounds, overlap and budget.
func place_prefab(source: VoxelModel, source_path: String, asset_id: String,
		pivot: Vector3, anchor: Vector3i, yaw: int,
		allow_over_budget: bool = false) -> Dictionary:
	if source == null:
		return _prefab_error("missing", "source is missing")
	if not VoxelPrefabInstance.pivot_is_valid(pivot):
		return _prefab_error("invalid", "pivot must be a multiple of 0.5")
	if not source.prefab_instances.is_empty():
		return _prefab_error("incompatible", "source contains prefab instances")
	if source.voxel_count() == 0 and source.lights.is_empty():
		return _prefab_error("incompatible", "source is empty")
	var inst := VoxelPrefabInstance.new()
	inst.instance_id = _next_prefab_id
	inst.asset_id = asset_id
	inst.source = source
	inst.source_path = source_path
	inst.source_uid = _uid_text_for(source)
	inst.source_bounds = VoxelPrefabInstance.occupied_bounds(source)
	inst.pivot = VoxelPrefabInstance.snap_pivot(pivot)
	inst.anchor = anchor
	inst.yaw_quarters = VoxelPrefabInstance.normalize_yaw(yaw)
	var candidate: Dictionary = prefab_composition.validate_candidate(inst, grid, bounds)
	if not candidate["ok"]:
		return _prefab_result(candidate, inst.instance_id)
	var added_lights: int = (candidate["lights"] as Array).size()
	if not allow_over_budget and prefab_light_count() + added_lights > prefab_light_budget:
		return _prefab_budget_error(added_lights)
	begin_stroke()
	_prefab_record_before(inst.instance_id, null, prefab_instances.size())
	prefab_instances.append(inst)
	prefab_composition.insert_candidate(inst, candidate)
	_next_prefab_id += 1
	_prefab_record_after(inst.instance_id)
	_mark_prefab_chunks(prefab_composition.world_cells(inst.instance_id))
	last_touched_prefabs[inst.instance_id] = true
	end_stroke()
	changed.emit()
	prefabs_changed.emit()
	return _prefab_result(candidate, inst.instance_id)


func move_prefab(id: int, anchor: Vector3i) -> Dictionary:
	return _transform_prefab(id, anchor, -1)


func rotate_prefab(id: int, delta: int = 1) -> Dictionary:
	var inst: VoxelPrefabInstance = prefab_instance(id)
	if inst == null:
		return _prefab_error("missing", "unknown instance")
	return _transform_prefab(id, inst.anchor, VoxelPrefabInstance.normalize_yaw(inst.yaw_quarters + delta))


func _transform_prefab(id: int, anchor: Vector3i, yaw: int) -> Dictionary:
	var inst: VoxelPrefabInstance = prefab_instance(id)
	if inst == null:
		return _prefab_error("missing", "unknown instance")
	var before: VoxelPrefabInstance = inst.copy_for_save()
	var index: int = prefab_instances.find(inst)
	var old_cells: Array[Vector3i] = prefab_composition.world_cells(id)
	var result: Dictionary = prefab_composition.set_instance_transform(id, anchor, yaw, grid, bounds)
	if not result.get("ok", false):
		return _prefab_result(result, id)
	begin_stroke()
	_prefab_record_before(id, before, index)
	_prefab_record_after(id)
	_mark_prefab_chunks(old_cells)
	_mark_prefab_chunks(prefab_composition.world_cells(id))
	last_touched_prefabs[id] = true
	end_stroke()
	changed.emit()
	prefabs_changed.emit()
	return _prefab_result(result, id)


func duplicate_prefab(id: int, anchor: Vector3i, allow_over_budget: bool = false) -> Dictionary:
	var source_inst: VoxelPrefabInstance = prefab_instance(id)
	if source_inst == null:
		return _prefab_error("missing", "unknown instance")
	if source_inst.source == null:
		return _prefab_error("missing", "source is missing")
	if not source_inst.source.prefab_instances.is_empty():
		return _prefab_error("incompatible", "source contains prefab instances")
	var inst: VoxelPrefabInstance = source_inst.duplicate_with_id(_next_prefab_id)
	inst.anchor = anchor
	var candidate: Dictionary = prefab_composition.validate_candidate(inst, grid, bounds)
	if not candidate["ok"]:
		return _prefab_result(candidate, inst.instance_id)
	var added_lights: int = (candidate["lights"] as Array).size()
	if not allow_over_budget and prefab_light_count() + added_lights > prefab_light_budget:
		return _prefab_budget_error(added_lights)
	begin_stroke()
	_prefab_record_before(inst.instance_id, null, prefab_instances.size())
	prefab_instances.append(inst)
	prefab_composition.insert_candidate(inst, candidate)
	_next_prefab_id += 1
	_prefab_record_after(inst.instance_id)
	_mark_prefab_chunks(prefab_composition.world_cells(inst.instance_id))
	last_touched_prefabs[inst.instance_id] = true
	end_stroke()
	changed.emit()
	prefabs_changed.emit()
	return _prefab_result(candidate, inst.instance_id)


func delete_prefab(id: int) -> Dictionary:
	var inst: VoxelPrefabInstance = prefab_instance(id)
	if inst == null:
		return _prefab_error("missing", "unknown instance")
	var before: VoxelPrefabInstance = inst.copy_for_save()
	var index: int = prefab_instances.find(inst)
	var old_cells: Array[Vector3i] = prefab_composition.world_cells(id)
	begin_stroke()
	_remove_prefab_from_list(id)
	_prefab_record_before(id, before, index)
	_prefab_record_after(id)
	_mark_prefab_chunks(old_cells)
	last_touched_prefabs[id] = true
	end_stroke()
	changed.emit()
	prefabs_changed.emit()
	return {"ok": true, "instance_id": id, "state": "deleted", "reason": "",
		"cells": old_cells.size(), "lights": 0, "bounds": AABB()}


## Converts a linked instance into ordinary voxels and lights in one undo
## step. Refuses atomically if the parent's hard 32-light limit would be
## exceeded. Missing/conflicted/incompatible instances cannot be unpacked.
func unpack_prefab(id: int) -> Dictionary:
	var inst: VoxelPrefabInstance = prefab_instance(id)
	if inst == null:
		return _prefab_error("missing", "unknown instance")
	var state: Dictionary = prefab_status(id)
	if str(state.get("state", "ok")) != "ok":
		return _prefab_error(str(state.get("state", "conflict")),
			"cannot unpack: " + str(state.get("reason", "instance is not valid")))
	var cells: Array[Vector3i] = prefab_composition.world_cells(id)
	var instance_lights: Array[Dictionary] = prefab_composition.world_lights(id)
	for p: Vector3i in cells:
		if grid.has(p):
			return _prefab_error("conflict", "overlaps local voxel at (%d, %d, %d)" % [p.x, p.y, p.z])
	if lights.size() + instance_lights.size() > MAX_LIGHTS:
		return _prefab_error("light_limit",
			"parent light limit would be exceeded (%d + %d > %d)" % [
				lights.size(), instance_lights.size(), MAX_LIGHTS])
	var before: VoxelPrefabInstance = inst.copy_for_save()
	var index: int = prefab_instances.find(inst)
	begin_stroke()
	_allow_owned_writes = true
	for p: Vector3i in cells:
		_write(p, prefab_composition.color_at(p))
	_allow_owned_writes = false
	for l: Dictionary in instance_lights:
		_add_light_raw(l)
	_remove_prefab_from_list(id)
	_prefab_record_before(id, before, index)
	_prefab_record_after(id)
	_mark_prefab_chunks(cells)
	last_touched_prefabs[id] = true
	end_stroke()
	changed.emit()
	prefabs_changed.emit()
	meta_changed.emit()
	return {"ok": true, "instance_id": id, "state": "unpacked", "reason": "",
		"cells": cells.size(), "lights": instance_lights.size(), "bounds": AABB()}


func relink_prefab(id: int, source: VoxelModel, source_path: String,
		asset_id: String = "") -> Dictionary:
	var inst: VoxelPrefabInstance = prefab_instance(id)
	if inst == null:
		return _prefab_error("missing", "unknown instance")
	if source == null:
		return _prefab_error("missing", "source is missing")
	if not source.prefab_instances.is_empty():
		return _prefab_error("incompatible", "source contains prefab instances")
	if source.voxel_count() == 0 and source.lights.is_empty():
		return _prefab_error("incompatible", "source is empty")
	var before: VoxelPrefabInstance = inst.copy_for_save()
	var index: int = prefab_instances.find(inst)
	var old_cells: Array[Vector3i] = prefab_composition.world_cells(id)
	begin_stroke()
	var result: Dictionary = prefab_composition.relink_instance(
			id, source, source_path, asset_id, grid, bounds)
	_prefab_record_before(id, before, index)
	_prefab_record_after(id)
	_mark_prefab_chunks(old_cells)
	_mark_prefab_chunks(prefab_composition.world_cells(id))
	last_touched_prefabs[id] = true
	end_stroke()
	changed.emit()
	prefabs_changed.emit()
	return _prefab_result(result, id)


## Reloads every source from disk (or from explicit `sources` overrides) and
## revalidates the whole composition. Not undoable and does not dirty the
## document: it changes derived content, not authored placements.
func refresh_prefabs(sources: Dictionary = {}) -> Dictionary:
	var old_columns: Array = prefab_composition.column_keys()
	var base_dir: String = path.get_base_dir()
	var reloaded: Dictionary = {}
	var loaded: Dictionary = {} # absolute path -> VoxelModel or null
	var updated: int = 0
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null:
			continue
		var override: Dictionary = _prefab_source_override(sources, inst)
		var src: VoxelModel = null
		if override["found"]:
			src = override["source"] as VoxelModel
		else:
			var p: String = _source_file_path(inst, base_dir)
			if p != "":
				if loaded.has(p):
					src = loaded[p]
				elif _path_exists(p):
					src = load_model_tolerant(p, ResourceLoader.CACHE_MODE_IGNORE_DEEP)
					reloaded[p] = true
					# Many instances usually share one source: read it once.
					loaded[p] = src
			else:
				# No path to refresh from: keep an in-memory source, but drop a
				# source whose file hint no longer resolves.
				src = null if _has_file_hint(inst) else inst.source
		if src != inst.source:
			updated += 1
		inst.source = src
		if src != null:
			inst.source_bounds = VoxelPrefabInstance.occupied_bounds(src)
	prefab_composition.rebuild(prefab_instances, grid, bounds)
	for key: Vector2i in old_columns:
		last_touched_prefab_chunks[key] = true
	for key: Vector2i in prefab_composition.column_keys():
		last_touched_prefab_chunks[key] = true
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst != null:
			last_touched_prefabs[inst.instance_id] = true
	var counts: Dictionary = prefab_status_counts()
	changed.emit()
	prefabs_changed.emit()
	return {
		"ok": true,
		"reloaded": reloaded.size(),
		"updated": updated,
		"instances": prefab_instances.size(),
		"missing": int(counts.get("missing", 0)),
		"conflicted": int(counts.get("conflict", 0)),
		"incompatible": int(counts.get("incompatible", 0)),
		"light_count": prefab_light_count(),
		"light_budget": prefab_light_budget,
	}


## Fills null sources from `base_dir`-relative fallbacks and forces a fresh
## disk read of every source, so opening a parent sees current source files.
func _reload_instance_sources(base_dir: String) -> void:
	var loaded: Dictionary = {} # absolute path -> VoxelModel or null
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null:
			continue
		var p: String = _source_file_path(inst, base_dir)
		if p == "":
			# A path hint that no longer resolves means the source file is
			# gone; do not keep stale cached geometry from the parent load.
			if inst.source != null and _has_file_hint(inst):
				inst.source = null
			continue
		if not _path_exists(p):
			inst.source = null
			continue
		if not loaded.has(p):
			var res: Resource = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
			if res is VoxelModel:
				loaded[p] = res as VoxelModel
			else:
				loaded[p] = null
		var src: VoxelModel = loaded[p]
		inst.source = src
		if src != null:
			inst.source_bounds = VoxelPrefabInstance.occupied_bounds(src)


func _has_file_hint(inst: VoxelPrefabInstance) -> bool:
	if inst.source_path != "" or inst.source_uid != "":
		return true
	if inst.source == null:
		return false
	return inst.source.resource_path != ""


func _prefab_source_override(sources: Dictionary, inst: VoxelPrefabInstance) -> Dictionary:
	if sources.has(inst.asset_id):
		return {"found": true, "source": sources[inst.asset_id]}
	if inst.source_path != "" and sources.has(inst.source_path):
		return {"found": true, "source": sources[inst.source_path]}
	if inst.source != null and inst.source.resource_path != "" \
			and sources.has(inst.source.resource_path):
		return {"found": true, "source": sources[inst.source.resource_path]}
	return {"found": false, "source": null}


## Absolute/res:// path used to reload an instance's source. Prefers the
## resolved resource, then the UID hint, then the parent-relative fallback.
func _source_file_path(inst: VoxelPrefabInstance, base_dir: String) -> String:
	if inst.source != null and inst.source.resource_path != "":
		if _path_exists(inst.source.resource_path):
			return inst.source.resource_path
	if inst.source_uid != "":
		var uid: int = ResourceUID.text_to_id(inst.source_uid)
		if uid != -1:
			var uid_path: String = ResourceUID.get_id_path(uid)
			if uid_path != "" and _path_exists(uid_path):
				return uid_path
	if inst.source_path != "":
		var p: String = inst.source_path
		if not p.is_absolute_path() and not p.begins_with("res://") and not p.begins_with("user://"):
			if base_dir != "":
				p = base_dir.path_join(p)
		if _path_exists(p):
			return p
	return ""


func _mark_prefab_chunks(cells: Array[Vector3i]) -> void:
	for p: Vector3i in cells:
		last_touched_prefab_chunks[Vector2i(p.x / VoxelPrefabComposition.CHUNK_SIZE,
			p.z / VoxelPrefabComposition.CHUNK_SIZE)] = true


func _remove_prefab_from_list(id: int) -> bool:
	var inst: VoxelPrefabInstance = prefab_instance(id)
	if inst == null:
		return false
	prefab_instances.erase(inst)
	prefab_composition.remove_instance(id)
	return true


func _prefab_record_before(id: int, snapshot: VoxelPrefabInstance, index: int) -> void:
	if not _prefab_history.has(id):
		_prefab_history[id] = [snapshot, null, index]


func _prefab_record_after(id: int) -> void:
	var inst: VoxelPrefabInstance = prefab_instance(id)
	if not _prefab_history.has(id):
		_prefab_history[id] = [null, null, prefab_instances.size()]
	_prefab_history[id][1] = inst.copy_for_save() if inst != null else null


func _recompute_next_prefab_id() -> void:
	_next_prefab_id = 1
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst != null:
			_next_prefab_id = maxi(_next_prefab_id, inst.instance_id + 1)


func _add_light_raw(light: Dictionary) -> int:
	var l: Dictionary = normalized_light(light)
	var id: int = _next_light_id
	_next_light_id += 1
	_light_before(id)
	lights[id] = l
	_light_after(id)
	last_touched_lights[id] = true
	return id


func _prefab_result(result: Dictionary, id: int) -> Dictionary:
	var out: Dictionary = result.duplicate(true)
	out["instance_id"] = id
	out["id"] = id
	return out


func _prefab_error(state: String, reason: String) -> Dictionary:
	return {"ok": false, "state": state, "reason": reason, "instance_id": 0, "id": 0,
		"cells": [], "lights": [], "bounds": AABB()}


func _prefab_budget_error(added_lights: int) -> Dictionary:
	return {
		"ok": false, "state": "budget", "reason":
			"soft light budget exceeded (%d + %d > %d)" % [
				prefab_light_count(), added_lights, prefab_light_budget],
		"budget_exceeded": true, "added_lights": added_lights,
		"instance_id": 0, "id": 0, "cells": [], "lights": [], "bounds": AABB(),
	}


## File existence that does not trust the resource cache. `ResourceLoader.exists`
## returns true for a cached resource even after its file is deleted, which
## would keep stale prefab geometry after a source disappears.
static func _path_exists(p: String) -> bool:
	if p.begins_with("res://") or p.begins_with("user://"):
		return ResourceLoader.exists(p)
	return FileAccess.file_exists(p)


## Relative path from `from_dir` to `to_path`. Godot has no
## String.path_relative_to, and FLAG_RELATIVE_PATHS only handles res:// paths,
## so external sources rely on this fallback. Returns `to_path` unchanged when
## the paths share no root.
static func relative_path(from_dir: String, to_path: String) -> String:
	if to_path.begins_with("res://") or to_path.begins_with("user://"):
		return to_path
	if from_dir == "" or to_path == "":
		return to_path
	var from: String = from_dir.simplify_path().trim_suffix("/")
	var to: String = to_path.simplify_path()
	var from_parts: PackedStringArray = from.split("/", false)
	var to_parts: PackedStringArray = to.split("/", false)
	var common: int = 0
	while common < from_parts.size() and common < to_parts.size() \
			and from_parts[common] == to_parts[common]:
		common += 1
	if common == 0:
		return to_path
	var out: String = ""
	for i in range(common, from_parts.size()):
		out += "../"
	for i in range(common, to_parts.size()):
		out += to_parts[i]
		if i < to_parts.size() - 1:
			out += "/"
	return out


static func _uid_text_for(res: Resource) -> String:
	if res == null or res.resource_path == "":
		return ""
	var uid: int = ResourceLoader.get_resource_uid(res.resource_path)
	if uid == ResourceUID.INVALID_ID:
		return ""
	return ResourceUID.id_to_text(uid)


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
	prefab_instances.clear()
	prefab_composition.clear()
	prefab_light_budget = 64
	_undo_stack.clear()
	_redo_stack.clear()
	_stroke = {}
	_light_history = {}
	_prefab_history = {}
	_stroke_depth = 0
	_next_light_id = 1
	_next_prefab_id = 1
	last_touched.clear()
	last_touched_lights.clear()
	last_touched_prefab_chunks.clear()
	last_touched_prefabs.clear()
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
	m.prefab_light_budget = prefab_light_budget
	var saved: Array[VoxelPrefabInstance] = []
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst != null:
			saved.append(inst.copy_for_save())
	m.prefab_instances = saved
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
	prefab_instances.clear()
	for inst: VoxelPrefabInstance in m.prefab_instances:
		if inst != null:
			prefab_instances.append(inst.copy_for_save())
	prefab_light_budget = clampi(m.prefab_light_budget, 0, 4096)
	_next_prefab_id = 1
	_recompute_next_prefab_id()
	_reload_instance_sources(source_path.get_base_dir())
	prefab_composition.rebuild(prefab_instances, grid, bounds)
	path = source_path
	dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	_stroke = {}
	_light_history = {}
	_prefab_history = {}
	_stroke_depth = 0
	last_touched.clear()
	last_touched_lights.clear()
	last_touched_prefab_chunks.clear()
	last_touched_prefabs.clear()
	changed.emit()
	history_changed.emit()
	meta_changed.emit()
	return dropped


func save_file(target: String) -> Error:
	var model: VoxelModel = to_model()
	var base_dir: String = target.get_base_dir()
	if base_dir != "":
		for inst: VoxelPrefabInstance in model.prefab_instances:
			if inst.source == null or inst.source.resource_path == "":
				continue
			inst.source_path = relative_path(base_dir, inst.source.resource_path)
			inst.source_uid = _uid_text_for(inst.source)
	var err: Error = ResourceSaver.save(model, target, ResourceSaver.FLAG_RELATIVE_PATHS)
	if err == OK:
		# Keep the authored instances in sync with the fallback paths written
		# to disk, so Save As can recompute them against the new folder.
		if base_dir != "" and model.prefab_instances.size() == prefab_instances.size():
			for i in prefab_instances.size():
				prefab_instances[i].source_path = model.prefab_instances[i].source_path
				prefab_instances[i].source_uid = model.prefab_instances[i].source_uid
		path = target
		dirty = false
		meta_changed.emit()
	return err


func load_file(source: String) -> Error:
	if not ResourceLoader.exists(source):
		return ERR_FILE_NOT_FOUND
	# Missing prefab sources must not abort the whole load: the instances
	# survive with source == null and can be relinked. There is no getter for
	# this flag, so restore the default unconditionally.
	ResourceLoader.set_abort_on_missing_resources(false)
	var res: Resource = ResourceLoader.load(source, "", ResourceLoader.CACHE_MODE_IGNORE)
	ResourceLoader.set_abort_on_missing_resources(true)
	var m := res as VoxelModel
	if m == null:
		return ERR_FILE_UNRECOGNIZED
	load_model(m, source)
	return OK


## Loads one VoxelModel file with missing dependencies tolerated. Relink and
## the catalogue use this so a source with a temporarily broken external
## reference can still be adopted instead of failing outright.
static func load_model_tolerant(source: String,
		cache_mode: ResourceLoader.CacheMode = ResourceLoader.CACHE_MODE_IGNORE_DEEP) -> VoxelModel:
	if source == "" or not _path_exists(source):
		return null
	ResourceLoader.set_abort_on_missing_resources(false)
	var res: Resource = ResourceLoader.load(source, "", cache_mode)
	ResourceLoader.set_abort_on_missing_resources(true)
	return res as VoxelModel


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
	# Linked instance cells are not editable until unpacked. Unpack itself
	# sets the escape hatch because it replaces the instance in one stroke.
	if not _allow_owned_writes and prefab_composition.has_cell(p):
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
