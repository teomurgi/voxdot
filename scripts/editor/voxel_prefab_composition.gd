class_name VoxelPrefabComposition
extends RefCounted

## Derived spatial view of a parent document: local voxels plus every valid
## prefab instance. It owns the column-bucketed cell index, the transform
## cache, overlap validation, and the per-instance status (ok/missing/conflict/
## incompatible).
##
## `VoxelDocument.prefab_instances` is the authoritative authored list. The
## `instances` dictionary here is a lookup/cache kept in sync by the document.
## The local voxel grid and bounds are passed into validation instead of being
## stored, because the document replaces its grid on load.

const CHUNK_SIZE: int = 64

var instances: Dictionary = {}          # instance_id -> VoxelPrefabInstance
var status: Dictionary = {}             # instance_id -> {state, reason}
var changed_columns: Dictionary = {}    # Vector2i -> true since the last drain
var bounds: Vector3i = Vector3i(32, 32, 32)

# Vector2i column -> Dictionary(Vector3i -> instance_id)
var _columns: Dictionary = {}
# Vector2i column -> Dictionary(Vector3i -> Color)
var _colors: Dictionary = {}
var _instance_cells: Dictionary = {}    # id -> Array[Vector3i] (valid only)
var _instance_lights: Dictionary = {}   # id -> Array[Dictionary] (valid only)
var _instance_bounds: Dictionary = {}   # id -> AABB (valid, missing, conflict)
var _offsets: Dictionary = {}           # id -> cached transform data


func clear() -> void:
	instances.clear()
	status.clear()
	changed_columns.clear()
	_columns.clear()
	_colors.clear()
	_instance_cells.clear()
	_instance_lights.clear()
	_instance_bounds.clear()
	_offsets.clear()


## Rebuilds the whole composition. Instances are processed in list order;
## when an external edit makes two instances overlap, the later one becomes
## conflicted and contributes nothing solid.
func rebuild(list: Array, local_grid: Dictionary, new_bounds: Vector3i) -> void:
	clear()
	bounds = new_bounds
	for inst: VoxelPrefabInstance in list:
		instances[inst.instance_id] = inst
		_insert(inst, local_grid)


func validate_candidate(inst: VoxelPrefabInstance, local_grid: Dictionary,
		new_bounds: Vector3i, ignore_id: int = 0) -> Dictionary:
	var result: Dictionary = {
		"ok": false, "state": "ok", "reason": "",
		"cells": [], "colors": [], "lights": [], "bounds": AABB(),
	}
	if inst == null:
		result["state"] = "missing"
		result["reason"] = "source is missing"
		result["bounds"] = AABB(Vector3(inst.anchor), Vector3.ONE) if inst != null else AABB()
		return result
	if inst.source == null:
		result["state"] = "missing"
		result["reason"] = "source is missing"
		result["bounds"] = inst.placeholder_bounds()
		return result
	if not inst.source.prefab_instances.is_empty():
		result["state"] = "incompatible"
		result["reason"] = "source contains prefab instances"
		result["bounds"] = _transformed_aabb(
				VoxelPrefabInstance.occupied_bounds(inst.source), inst)
		return result
	var cached: Dictionary = _compute_offsets(inst)
	var cells: Array = cached["cells"]
	var colors: Array = cached["colors"]
	var lights: Array = cached["lights"]
	if cells.is_empty() and lights.is_empty():
		result["state"] = "incompatible"
		result["reason"] = "source is empty"
		result["bounds"] = inst.placeholder_bounds()
		return result

	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var anchor := Vector3(inst.anchor)
	for i in cells.size():
		var p: Vector3i = inst.anchor + (cells[i] as Vector3i)
		if not _in_bounds(p, new_bounds):
			result["state"] = "conflict"
			result["reason"] = "cell (%d, %d, %d) is outside bounds" % [p.x, p.y, p.z]
			result["bounds"] = AABB(lo, (hi - lo).max(Vector3.ONE)) if lo.x != INF else AABB(anchor, Vector3.ONE)
			return result
		if local_grid.has(p):
			result["state"] = "conflict"
			result["reason"] = "overlaps local voxel at (%d, %d, %d)" % [p.x, p.y, p.z]
			result["bounds"] = AABB(lo, (hi - lo).max(Vector3.ONE)) if lo.x != INF else AABB(anchor, Vector3.ONE)
			return result
		var owner: int = owner_at(p)
		if owner != 0 and owner != ignore_id:
			result["state"] = "conflict"
			result["reason"] = "overlaps prefab #%d" % owner
			result["bounds"] = AABB(lo, (hi - lo).max(Vector3.ONE)) if lo.x != INF else AABB(anchor, Vector3.ONE)
			return result
		lo = lo.min(Vector3(p))
		hi = hi.max(Vector3(p) + Vector3.ONE)

	for light: Dictionary in lights:
		var pos: Vector3 = anchor + (light["offset"] as Vector3)
		if not _light_in_bounds(pos, new_bounds):
			result["state"] = "conflict"
			result["reason"] = "light at (%.1f, %.1f, %.1f) is outside bounds" % [pos.x, pos.y, pos.z]
			result["bounds"] = AABB(lo, (hi - lo).max(Vector3.ONE)) if lo.x != INF else AABB(anchor, Vector3.ONE)
			return result
		lo = lo.min(pos)
		hi = hi.max(pos + Vector3.ONE)

	if lo.x == INF:
		lo = anchor
		hi = anchor + Vector3.ONE
	result["ok"] = true
	result["state"] = "ok"
	result["reason"] = ""
	result["cells"] = cells
	result["colors"] = colors
	result["lights"] = lights
	result["bounds"] = AABB(lo, (hi - lo).max(Vector3.ONE))
	return result


func insert_instance(inst: VoxelPrefabInstance, local_grid: Dictionary,
		new_bounds: Vector3i) -> Dictionary:
	bounds = new_bounds
	instances[inst.instance_id] = inst
	return _insert(inst, local_grid)


## Adds a candidate that has already passed validate_candidate. The caller is
## responsible for the validation; this avoids re-walking a large instance.
func insert_candidate(inst: VoxelPrefabInstance, candidate: Dictionary) -> void:
	instances[inst.instance_id] = inst
	_add_candidate(inst, candidate)
	_instance_bounds[inst.instance_id] = candidate["bounds"]
	status[inst.instance_id] = {"state": "ok", "reason": ""}


func remove_instance(id: int) -> bool:
	if not instances.has(id):
		return false
	_remove_instance_data(id)
	instances.erase(id)
	status.erase(id)
	_offsets.erase(id)
	return true


func move_instance(id: int, anchor: Vector3i, local_grid: Dictionary,
		new_bounds: Vector3i) -> Dictionary:
	return set_instance_transform(id, anchor, -1, local_grid, new_bounds)


func rotate_instance(id: int, delta: int, local_grid: Dictionary,
		new_bounds: Vector3i) -> Dictionary:
	if not instances.has(id):
		return {"ok": false, "state": "missing", "reason": "unknown instance"}
	var inst: VoxelPrefabInstance = instances[id]
	var yaw: int = VoxelPrefabInstance.normalize_yaw(inst.yaw_quarters + delta)
	return set_instance_transform(id, inst.anchor, yaw, local_grid, new_bounds)


func set_instance_transform(id: int, anchor: Vector3i, yaw: int,
		local_grid: Dictionary, new_bounds: Vector3i) -> Dictionary:
	if not instances.has(id):
		return {"ok": false, "state": "missing", "reason": "unknown instance"}
	bounds = new_bounds
	var inst: VoxelPrefabInstance = instances[id]
	var old_anchor := inst.anchor
	var old_yaw := inst.yaw_quarters
	var new_yaw: int = VoxelPrefabInstance.normalize_yaw(yaw if yaw >= 0 else old_yaw)
	# An instance that is already a placeholder (missing, conflicted or
	# incompatible) may be repositioned even if the new spot is also invalid;
	# that is how the user slides it out of a conflict. A valid instance is
	# all-or-nothing.
	var was_solid: bool = str(status_for(id).get("state", "ok")) == "ok"
	inst.anchor = anchor
	inst.yaw_quarters = new_yaw
	var candidate: Dictionary = validate_candidate(inst, local_grid, new_bounds, id)
	if not candidate["ok"] and was_solid:
		inst.anchor = old_anchor
		inst.yaw_quarters = old_yaw
		return candidate
	# Remove the old cells before inserting the new ones so a transform that
	# reuses a cell cannot delete its own fresh ownership.
	_remove_instance_data(id)
	if candidate["ok"]:
		_add_candidate(inst, candidate)
		status[id] = {"state": "ok", "reason": ""}
		_instance_bounds[id] = candidate["bounds"]
	else:
		_instance_cells[id] = []
		_instance_lights[id] = []
		_instance_bounds[id] = candidate["bounds"]
		status[id] = {"state": candidate["state"], "reason": candidate["reason"]}
	return {"ok": true, "state": candidate["state"], "reason": candidate["reason"],
		"cells": candidate["cells"], "lights": candidate["lights"], "bounds": candidate["bounds"]}


func relink_instance(id: int, source: VoxelModel, source_path: String, asset_id: String,
		local_grid: Dictionary, new_bounds: Vector3i) -> Dictionary:
	if not instances.has(id):
		return {"ok": false, "reason": "unknown instance"}
	bounds = new_bounds
	var inst: VoxelPrefabInstance = instances[id]
	_remove_instance_data(id)
	inst.source = source
	inst.source_path = source_path
	if asset_id != "":
		inst.asset_id = asset_id
	inst.source_bounds = VoxelPrefabInstance.occupied_bounds(source)
	_offsets.erase(id)
	_insert(inst, local_grid)
	return {"ok": true, "state": (status[id] as Dictionary).get("state", "ok"),
		"reason": (status[id] as Dictionary).get("reason", ""),
		"cells": _instance_cells.get(id, []), "lights": _instance_lights.get(id, []),
		"bounds": _instance_bounds.get(id, AABB())}


func owner_at(cell: Vector3i) -> int:
	var col: Dictionary = _columns.get(_column_key(cell), {})
	return int(col.get(cell, 0))


func has_cell(cell: Vector3i) -> bool:
	return owner_at(cell) != 0


func color_at(cell: Vector3i) -> Color:
	var col: Dictionary = _colors.get(_column_key(cell), {})
	return col.get(cell, Color(1, 1, 1, 1))


func colors_in_column(key: Vector2i) -> Dictionary:
	return _colors.get(key, {})


func cells_in_column(key: Vector2i) -> Dictionary:
	return _columns.get(key, {})


func column_keys() -> Array:
	return _columns.keys()


func world_cells(id: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for p: Vector3i in _instance_cells.get(id, []):
		out.append(p)
	return out


func world_lights(id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var anchor := Vector3.ZERO
	if instances.has(id):
		anchor = Vector3((instances[id] as VoxelPrefabInstance).anchor)
	for light: Dictionary in _instance_lights.get(id, []):
		var copy: Dictionary = (light as Dictionary).duplicate(true)
		copy["position"] = anchor + (light["offset"] as Vector3)
		out.append(copy)
	return out


func bounds_for(id: int) -> AABB:
	return _instance_bounds.get(id, AABB())


func status_for(id: int) -> Dictionary:
	return status.get(id, {"state": "ok", "reason": ""})


func light_count() -> int:
	var n: int = 0
	for id: int in _instance_lights:
		n += (_instance_lights[id] as Array).size()
	return n


func total_cells() -> int:
	var n: int = 0
	for id: int in _instance_cells:
		n += (_instance_cells[id] as Array).size()
	return n


func status_counts() -> Dictionary:
	var counts: Dictionary = {"ok": 0, "missing": 0, "conflict": 0, "incompatible": 0}
	for id: int in instances:
		var s: String = str(status_for(id).get("state", "ok"))
		if not counts.has(s):
			counts[s] = 0
		counts[s] += 1
	return counts


## True when a valid instance cell would fall outside `new_bounds`. Missing and
## conflicted placeholders are not part of the solid composition and do not
## block a resize.
func valid_cells_outside(new_bounds: Vector3i) -> bool:
	for id: int in _instance_cells:
		for p: Vector3i in _instance_cells[id]:
			if p.x >= new_bounds.x or p.y >= new_bounds.y or p.z >= new_bounds.z:
				return true
	return false


func valid_lights_outside(new_bounds: Vector3i) -> bool:
	for id: int in _instance_lights:
		var anchor := Vector3.ZERO
		if instances.has(id):
			anchor = Vector3((instances[id] as VoxelPrefabInstance).anchor)
		for light: Dictionary in _instance_lights[id]:
			var p: Vector3 = anchor + (light["offset"] as Vector3)
			if p.x >= new_bounds.x or p.y >= new_bounds.y or p.z >= new_bounds.z:
				return true
	return false


# --- Internals ---

func _insert(inst: VoxelPrefabInstance, local_grid: Dictionary) -> Dictionary:
	var candidate: Dictionary = validate_candidate(inst, local_grid, bounds, inst.instance_id)
	_instance_bounds[inst.instance_id] = candidate["bounds"]
	if candidate["ok"]:
		_add_candidate(inst, candidate)
		status[inst.instance_id] = {"state": "ok", "reason": ""}
	else:
		_instance_cells[inst.instance_id] = []
		_instance_lights[inst.instance_id] = []
		status[inst.instance_id] = {
			"state": candidate["state"],
			"reason": candidate["reason"],
		}
	return candidate


func _add_candidate(inst: VoxelPrefabInstance, candidate: Dictionary) -> void:
	var id: int = inst.instance_id
	var offsets: Array = candidate["cells"]
	var colors: Array = candidate["colors"]
	var lights: Array = candidate["lights"]
	var world: Array[Vector3i] = []
	world.resize(offsets.size())
	for i in offsets.size():
		world[i] = inst.anchor + (offsets[i] as Vector3i)
	_instance_cells[id] = world
	_instance_lights[id] = lights
	for i in world.size():
		var p: Vector3i = world[i]
		var col_key := _column_key(p)
		var col: Dictionary = _columns.get_or_add(col_key, {})
		var color_col: Dictionary = _colors.get_or_add(col_key, {})
		col[p] = id
		color_col[p] = colors[i]
		changed_columns[col_key] = true


func _remove_instance_data(id: int) -> void:
	var cells: Array = _instance_cells.get(id, [])
	for p: Vector3i in cells:
		var col_key := _column_key(p)
		var col: Dictionary = _columns.get(col_key, {})
		if int(col.get(p, 0)) == id:
			col.erase(p)
			(_colors.get(col_key, {}) as Dictionary).erase(p)
			changed_columns[col_key] = true
		if col.is_empty():
			_columns.erase(col_key)
			_colors.erase(col_key)
	_instance_cells.erase(id)
	_instance_lights.erase(id)
	_instance_bounds.erase(id)


## Offsets relative to the anchor, cached per instance for its current source
## object, pivot, and yaw. Moving only changes the anchor; rotating recomputes.
func _compute_offsets(inst: VoxelPrefabInstance) -> Dictionary:
	var yaw: int = VoxelPrefabInstance.normalize_yaw(inst.yaw_quarters)
	var cached: Dictionary = _offsets.get(inst.instance_id, {})
	if not cached.is_empty() and cached.get("source") == inst.source \
			and (cached.get("pivot") as Vector3) == inst.pivot \
			and int(cached.get("yaw", -1)) == yaw:
		return cached
	var cells: Array = []
	var colors: Array = []
	var lights: Array = []
	if inst.source != null:
		var grid: Dictionary = inst.source.to_grid()
		for c: Vector3i in grid:
			cells.append(VoxelPrefabInstance.cell_offset(c, inst.pivot, yaw))
			colors.append(grid[c])
		var packed: PackedFloat32Array = inst.source.lights
		for i in range(0, packed.size() - VoxelModel.LIGHT_STRIDE + 1, VoxelModel.LIGHT_STRIDE):
			var pos := Vector3(packed[i + 1], packed[i + 2], packed[i + 3])
			lights.append({
				"offset": VoxelPrefabInstance.light_offset(pos, inst.pivot, yaw),
				"position": pos,
				"color": Color(packed[i + 4], packed[i + 5], packed[i + 6]),
				"energy": packed[i + 7],
				"range": packed[i + 8],
				"shadows": packed[i + 9] > 0.5,
				"source_index": i / VoxelModel.LIGHT_STRIDE,
			})
	var data: Dictionary = {
		"source": inst.source,
		"pivot": inst.pivot,
		"yaw": yaw,
		"cells": cells,
		"colors": colors,
		"lights": lights,
	}
	_offsets[inst.instance_id] = data
	return data


func _transformed_aabb(source_aabb: AABB, inst: VoxelPrefabInstance) -> AABB:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in 8:
		var corner := source_aabb.position + Vector3(
			source_aabb.size.x * float(i & 1),
			source_aabb.size.y * float((i >> 1) & 1),
			source_aabb.size.z * float((i >> 2) & 1))
		var p := Vector3(inst.anchor) + VoxelPrefabInstance.light_offset(
				corner, inst.pivot, inst.yaw_quarters)
		lo = lo.min(p)
		hi = hi.max(p)
	if lo.x == INF:
		return AABB(Vector3(inst.anchor), Vector3.ONE)
	return AABB(lo, (hi - lo).max(Vector3.ONE))


static func _column_key(p: Vector3i) -> Vector2i:
	return Vector2i(p.x / CHUNK_SIZE, p.z / CHUNK_SIZE)


static func _in_bounds(p: Vector3i, b: Vector3i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x < b.x and p.y < b.y and p.z < b.z


static func _light_in_bounds(p: Vector3, b: Vector3i) -> bool:
	return p.x >= 0.0 and p.y >= 0.0 and p.z >= 0.0 \
			and p.x < float(b.x) and p.y < float(b.y) and p.z < float(b.z)
