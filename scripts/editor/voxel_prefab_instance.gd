class_name VoxelPrefabInstance
extends Resource

## One linked placement of a saved VoxelModel inside a parent model. The
## instance stores a reference to the source resource plus a transform; the
## transformed cells are derived by VoxelPrefabComposition and are never saved.
##
## The pivot is in source cell space and must be a multiple of 0.5, so a 90°
## yaw maps cell centres to cell centres. `anchor` is the parent cell whose
## minimum corner coincides with the transformed pivot.

@export var instance_id: int = 0
@export var asset_id: String = ""
## Native Godot external reference. This is what makes the parent a real
## dependency and what the runtime composes.
@export var source: VoxelModel = null
## Fallback locator, relative to the parent file when possible.
@export var source_path: String = ""
## Optional uid:// hint captured when the source has one.
@export var source_uid: String = ""
## Snapshot of the source's occupied AABB in source cell space. Only used to
## draw a correctly sized placeholder when the source cannot be resolved.
@export var source_bounds: AABB = AABB()
@export var pivot: Vector3 = Vector3.ZERO
@export var anchor: Vector3i = Vector3i.ZERO
@export var yaw_quarters: int = 0


static func normalize_yaw(yaw: int) -> int:
	return posmod(yaw, 4)


## Rounds a pivot to the nearest 0.5. The UI and MCP both snap input through
## this helper so the cell grid never receives quarter-cell offsets.
static func snap_pivot(p: Vector3) -> Vector3:
	return Vector3(
		roundf(p.x * 2.0) * 0.5,
		roundf(p.y * 2.0) * 0.5,
		roundf(p.z * 2.0) * 0.5)


static func pivot_is_valid(p: Vector3) -> bool:
	if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
		return false
	return is_equal_approx(p.x * 2.0, roundf(p.x * 2.0)) \
			and is_equal_approx(p.y * 2.0, roundf(p.y * 2.0)) \
			and is_equal_approx(p.z * 2.0, roundf(p.z * 2.0))


## +90° yaw about Y, matching Godot's R_y(+90°). Integer/fixed-point friendly:
## callers pass half-integer vectors and get half-integer results.
static func rotate_vector(d: Vector3, yaw: int) -> Vector3:
	match normalize_yaw(yaw):
		1:
			return Vector3(d.z, d.y, -d.x)
		2:
			return Vector3(-d.x, d.y, -d.z)
		3:
			return Vector3(-d.z, d.y, d.x)
		_:
			return d


## Offset of a source cell relative to the anchor. `c + 0.5` is the cell centre;
## the result is floored back onto the parent grid. Because the pivot is a
## multiple of 0.5, this floor is exact and two cells never collapse.
static func cell_offset(cell: Vector3i, pivot: Vector3, yaw: int) -> Vector3i:
	var d: Vector3 = Vector3(cell) + Vector3.ONE * 0.5 - pivot
	var r: Vector3 = rotate_vector(d, yaw)
	return Vector3i(floori(r.x), floori(r.y), floori(r.z))


static func light_offset(position: Vector3, pivot: Vector3, yaw: int) -> Vector3:
	return rotate_vector(position - pivot, yaw)


static func transform_light(position: Vector3, pivot: Vector3, anchor: Vector3i, yaw: int) -> Vector3:
	return Vector3(anchor) + light_offset(position, pivot, yaw)


## Occupied AABB of a source in source cell space: cells plus point lights.
## Light-only assets use the light-position AABB, padded to a visible size.
static func occupied_bounds(model: VoxelModel) -> AABB:
	if model == null:
		return AABB(Vector3.ZERO, Vector3.ONE)
	var grid: Dictionary = model.to_grid()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for p: Vector3i in grid:
		lo = lo.min(Vector3(p))
		hi = hi.max(Vector3(p) + Vector3.ONE)
	if grid.is_empty():
		var packed: PackedFloat32Array = model.lights
		for i in range(0, packed.size() - VoxelModel.LIGHT_STRIDE + 1, VoxelModel.LIGHT_STRIDE):
			var p := Vector3(packed[i + 1], packed[i + 2], packed[i + 3])
			lo = lo.min(p)
			hi = hi.max(p)
		if lo.x == INF:
			return AABB(Vector3.ZERO, Vector3.ONE)
		# A point has no area; give the placeholder a one-cell-ish box.
		lo -= Vector3(0.5, 0.5, 0.5)
		hi += Vector3(0.5, 0.5, 0.5)
	return AABB(lo, (hi - lo).max(Vector3.ONE))


static func source_light_count(model: VoxelModel) -> int:
	if model == null:
		return 0
	return model.lights.size() / VoxelModel.LIGHT_STRIDE


## Copy used for saving and undo snapshots: scalars by value, source by
## reference. Never deep-duplicate `source`, which would copy geometry and
## break the external dependency.
func copy_for_save() -> VoxelPrefabInstance:
	var c := VoxelPrefabInstance.new()
	c.instance_id = instance_id
	c.asset_id = asset_id
	c.source = source
	c.source_path = source_path
	c.source_uid = source_uid
	c.source_bounds = source_bounds
	c.pivot = pivot
	c.anchor = anchor
	c.yaw_quarters = normalize_yaw(yaw_quarters)
	return c


func duplicate_with_id(new_id: int) -> VoxelPrefabInstance:
	var c := copy_for_save()
	c.instance_id = new_id
	return c


## World AABB of the placeholder when the source is missing. The 8 corners of
## the saved source AABB are rotated around the pivot and translated by anchor.
func placeholder_bounds() -> AABB:
	var b: AABB = source_bounds
	if b.size.is_zero_approx():
		return AABB(Vector3(anchor), Vector3.ONE)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in 8:
		var corner := b.position + Vector3(
			b.size.x * float(i & 1),
			b.size.y * float((i >> 1) & 1),
			b.size.z * float((i >> 2) & 1))
		var p := Vector3(anchor) + light_offset(corner, pivot, yaw_quarters)
		lo = lo.min(p)
		hi = hi.max(p)
	return AABB(lo, hi - lo)
