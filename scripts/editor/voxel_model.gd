class_name VoxelModel
extends Resource

## Saved voxel asset produced by the in-engine voxel editor. Stores a sparse
## voxel grid in the same convention as VoxelMeshBuilder: voxel at grid
## position p occupies [p * voxel_size, (p + 1) * voxel_size].
##
## Voxels are packed as `cells = [x, y, z, palette_index, ...]` with a shared
## `palette`, which keeps .tres files compact. `swatches` is the editor's
## user-facing quick palette and does not affect rendering.

## Voxels are packed as `cells = [x, y, z, palette_index, ...]` with a shared
## `palette`, which keeps .tres files compact. Point lights use the optional
## packed `lights` array below; old resources without it still load unchanged.
@export var voxel_size: float = 0.0625
@export var bounds: Vector3i = Vector3i(32, 32, 32)
@export var swatches: PackedColorArray = PackedColorArray()
@export var palette: PackedColorArray = PackedColorArray()
@export var cells: PackedInt32Array = PackedInt32Array()
## id, x, y, z, red, green, blue, energy, range, shadows per point light.
## Positions and ranges are in voxel units, like the editor; runtime instances
## scale them by voxel_size. IDs are stable across save/open and undo/redo.
const LIGHT_STRIDE: int = 10
@export var lights: PackedFloat32Array = PackedFloat32Array()
## Directional sun saved with the model so a lit scene reopens as authored:
## energy 0 turns it off. Yaw/pitch are degrees (same orbit convention as the
## camera). Applied by the voxdot editor on open; runtime instances rebuild
## the point lights but leave the game's own lighting alone. Defaults match
## the editor's daylight look; old files load unchanged.
@export var sun_energy: float = 1.0
@export var sun_yaw: float = 35.0
@export var sun_pitch: float = -50.0
@export var sun_color: Color = Color(1, 1, 1)
@export var sun_shadows: bool = true
## Legacy field from an earlier ambient-fill design; no longer applied but kept
## so older files load and resave without churn.
@export var ambient_energy: float = 0.75


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


## Rebuilds only the stored point lights, preserving any other child nodes.
func build_lights(parent: Node3D) -> void:
	var old := parent.get_node_or_null("Lights")
	if old != null:
		parent.remove_child(old)
		old.queue_free()
	if lights.is_empty():
		return
	var group := Node3D.new()
	group.name = "Lights"
	parent.add_child(group)
	for i in range(0, lights.size() - LIGHT_STRIDE + 1, LIGHT_STRIDE):
		var light := OmniLight3D.new()
		light.name = "PointLight%d" % int(lights[i])
		light.position = Vector3(lights[i + 1], lights[i + 2], lights[i + 3]) * voxel_size
		light.light_color = Color(lights[i + 4], lights[i + 5], lights[i + 6])
		light.light_energy = lights[i + 7]
		light.omni_range = lights[i + 8] * voxel_size
		light.shadow_enabled = lights[i + 9] > 0.5
		group.add_child(light)


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
