class_name VoxelRaycast
extends RefCounted

## Amanatides & Woo voxel traversal over a sparse { Vector3i: Color } grid
## confined to the box [0, bounds). Rays are in voxel units (1 voxel = 1 unit).
##
## Result keys:
##   hit    (bool)     a solid voxel was struck; `pos` is that voxel and
##                     `normal` the face it was entered through.
##   floor  (bool)     no voxel was struck but the ray reached the y = 0 floor
##                     inside the bounds; `pos` is that empty floor cell
##                     (y = 0) and `normal` is (0, 1, 0).


static func cast(grid: Dictionary, bounds: Vector3i, origin: Vector3, dir: Vector3) -> Dictionary:
	var result: Dictionary = {"hit": false, "floor": false, "pos": Vector3i.ZERO, "normal": Vector3i.ZERO}
	var bmax := Vector3(bounds)

	# Slab test against the bounds box; remember which axis we entered through.
	var t_enter: float = 0.0
	var t_exit: float = INF
	var enter_axis: int = -1
	for a in 3:
		var o: float = origin[a]
		var d: float = dir[a]
		if absf(d) < 1e-9:
			if o < 0.0 or o > bmax[a]:
				return result
			continue
		var t0: float = (0.0 - o) / d
		var t1: float = (bmax[a] - o) / d
		if t0 > t1:
			var tmp: float = t0
			t0 = t1
			t1 = tmp
		if t0 > t_enter:
			t_enter = t0
			enter_axis = a
		t_exit = minf(t_exit, t1)
		if t_enter > t_exit:
			return result

	var start: Vector3 = origin + dir * (t_enter + 1e-5)
	var cell := Vector3i(floori(start.x), floori(start.y), floori(start.z))
	cell = cell.clamp(Vector3i.ZERO, bounds - Vector3i.ONE)

	var normal := Vector3i.ZERO
	if enter_axis >= 0:
		normal[enter_axis] = -1 if dir[enter_axis] > 0.0 else 1

	var step := Vector3i.ZERO
	var t_max := Vector3(INF, INF, INF)
	var t_delta := Vector3(INF, INF, INF)
	for a in 3:
		var d: float = dir[a]
		if absf(d) < 1e-9:
			continue
		step[a] = 1 if d > 0.0 else -1
		var boundary: float = float(cell[a] + (1 if d > 0.0 else 0))
		t_max[a] = (boundary - origin[a]) / d
		t_delta[a] = absf(1.0 / d)

	var max_steps: int = bounds.x + bounds.y + bounds.z + 3
	for i in max_steps:
		if grid.has(cell):
			result["hit"] = true
			result["pos"] = cell
			result["normal"] = normal
			return result
		var axis: int = 0
		if t_max.y < t_max.x and t_max.y <= t_max.z:
			axis = 1
		elif t_max.z < t_max.x and t_max.z < t_max.y:
			axis = 2
		var prev: Vector3i = cell
		cell[axis] += step[axis]
		t_max[axis] += t_delta[axis]
		normal = Vector3i.ZERO
		normal[axis] = -step[axis]
		if axis == 1 and cell.y < 0:
			result["floor"] = true
			result["pos"] = prev
			result["normal"] = Vector3i.UP
			return result
		if cell.x < 0 or cell.y < 0 or cell.z < 0 \
				or cell.x >= bounds.x or cell.y >= bounds.y or cell.z >= bounds.z:
			return result
	return result
