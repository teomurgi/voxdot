class_name VoxelModel
extends Resource

## Saved voxel asset produced by the in-engine voxel editor. Stores a sparse
## voxel grid in the same convention as VoxelMeshBuilder: voxel at grid
## position p occupies [p * voxel_size, (p + 1) * voxel_size].
##
## Voxels are packed as `cells = [x, y, z, palette_index, ...]` with a shared
## `palette`, which keeps .tres files compact. `swatches` is the editor's
## user-facing quick palette and does not affect rendering.

@export var voxel_size: float = 0.0625
@export var bounds: Vector3i = Vector3i(32, 32, 32)
@export var swatches: PackedColorArray = PackedColorArray()
@export var palette: PackedColorArray = PackedColorArray()
@export var cells: PackedInt32Array = PackedInt32Array()


func voxel_count() -> int:
	return cells.size() >> 2


## Returns the model as a { Vector3i: Color } grid.
func to_grid() -> Dictionary:
	var grid: Dictionary = {}
	for i in range(0, cells.size() - 3, 4):
		var idx: int = cells[i + 3]
		if idx < 0 or idx >= palette.size():
			continue
		grid[Vector3i(cells[i], cells[i + 1], cells[i + 2])] = palette[idx]
	return grid


## Replaces the stored voxels with `grid`. Output is sorted (y, z, x) so
## saved files diff cleanly in version control.
func set_grid(grid: Dictionary) -> void:
	var keys: Array = grid.keys()
	keys.sort_custom(_cell_less)
	var new_palette := PackedColorArray()
	var lookup: Dictionary = {}
	var out := PackedInt32Array()
	out.resize(keys.size() * 4)
	var o: int = 0
	for p: Vector3i in keys:
		var c: Color = grid[p]
		if not lookup.has(c):
			lookup[c] = new_palette.size()
			new_palette.append(c)
		out[o] = p.x
		out[o + 1] = p.y
		out[o + 2] = p.z
		out[o + 3] = lookup[c]
		o += 4
	palette = new_palette
	cells = out


## Builds a render mesh at this model's real-world voxel size.
func build_mesh() -> ArrayMesh:
	return VoxelMeshBuilder.build_mesh(to_grid(), voxel_size)


static func from_grid(grid: Dictionary, size: float = 0.0625) -> VoxelModel:
	var m := VoxelModel.new()
	m.voxel_size = size
	m.set_grid(grid)
	return m


static func _cell_less(a: Vector3i, b: Vector3i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	if a.z != b.z:
		return a.z < b.z
	return a.x < b.x
