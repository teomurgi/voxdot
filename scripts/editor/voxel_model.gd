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
## Atmospheric/ambient fill light saved with the model. Defaults match the
## editor's old hard-coded ambient floor, so pre-atmosphere files look the same.
## Disabled means the ambient contribution is zero.
@export var atmosphere_enabled: bool = true
@export var atmosphere_energy: float = 0.08
@export var atmosphere_color: Color = Color(0.55, 0.57, 0.65)
## Legacy field from an earlier ambient-fill design; no longer applied but kept
## so older files load and resave without churn.
@export var ambient_energy: float = 0.75
## Linked prefab placements. Old files have an empty array and load unchanged.
## Sources are external resources; this resource never embeds their geometry.
@export var prefab_instances: Array[VoxelPrefabInstance] = []
## Soft editor warning threshold for instance lights (not a hard cap). The
## parent's own point lights keep their separate hard limit of 32.
@export var prefab_light_budget: int = 64


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


## Builds a render mesh at this model's real-world voxel size. Prefab
## instances are composed in; a model without instances produces exactly the
## same mesh as before.
func build_mesh() -> ArrayMesh:
	return VoxelMeshBuilder.build_mesh(build_composed_grid(), voxel_size)


## Local voxels plus the transformed cells of every resolved instance. The
## editor forbids overlap; runtime is defensive and lets the first owner win
## (local cells win over instances, earlier instances win over later ones).
func build_composed_grid() -> Dictionary:
	var grid: Dictionary = to_grid()
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null or inst.source == null or not inst.source.prefab_instances.is_empty():
			continue
		var src: Dictionary = inst.source.to_grid()
		for c: Vector3i in src:
			var world: Vector3i = inst.anchor + VoxelPrefabInstance.cell_offset(
					c, inst.pivot, inst.yaw_quarters)
			if not grid.has(world):
				grid[world] = src[c]
	return grid


## Local lights plus transformed instance lights. Local IDs are kept; instance
## lights get a synthetic ID for debugging only.
func build_composed_lights() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var packed: PackedFloat32Array = lights
	for i in range(0, packed.size() - LIGHT_STRIDE + 1, LIGHT_STRIDE):
		out.append({
			"id": int(packed[i]),
			"position": Vector3(packed[i + 1], packed[i + 2], packed[i + 3]),
			"color": Color(packed[i + 4], packed[i + 5], packed[i + 6]),
			"energy": packed[i + 7],
			"range": packed[i + 8],
			"shadows": packed[i + 9] > 0.5,
			"prefab_id": 0,
		})
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null or inst.source == null or not inst.source.prefab_instances.is_empty():
			continue
		var src: PackedFloat32Array = inst.source.lights
		for i in range(0, src.size() - LIGHT_STRIDE + 1, LIGHT_STRIDE):
			var pos := Vector3(src[i + 1], src[i + 2], src[i + 3])
			var index: int = i / LIGHT_STRIDE
			out.append({
				"id": inst.instance_id * 100000 + index,
				"position": VoxelPrefabInstance.transform_light(
						pos, inst.pivot, inst.anchor, inst.yaw_quarters),
				"color": Color(src[i + 4], src[i + 5], src[i + 6]),
				"energy": src[i + 7],
				"range": src[i + 8],
				"shadows": src[i + 9] > 0.5,
				"prefab_id": inst.instance_id,
				"source_index": index,
			})
	return out


func has_unresolved_prefabs() -> bool:
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null or inst.source == null:
			return true
		if not inst.source.prefab_instances.is_empty():
			return true
	return false


func prefab_summary() -> Dictionary:
	var resolved: int = 0
	var unresolved: int = 0
	var nested: int = 0
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null or inst.source == null:
			unresolved += 1
		elif not inst.source.prefab_instances.is_empty():
			nested += 1
		else:
			resolved += 1
	return {
		"instances": prefab_instances.size(),
		"resolved": resolved,
		"unresolved": unresolved,
		"nested": nested,
		"light_budget": prefab_light_budget,
	}


## Fills null sources from `source_path` relative to `base_dir`. Useful after
## loading a parent whose native external paths no longer exist (moved folder)
## and for the runtime's `load_with_prefabs` helper.
func resolve_prefab_sources(base_dir: String) -> int:
	var resolved: int = 0
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null or inst.source != null:
			continue
		var path: String = ""
		if inst.source_uid != "":
			var uid: int = ResourceUID.text_to_id(inst.source_uid)
			if uid != -1:
				path = ResourceUID.get_id_path(uid)
		if path == "" and inst.source_path != "":
			path = inst.source_path
			if not path.is_absolute_path() and not path.begins_with("res://") \
					and not path.begins_with("user://"):
				path = base_dir.path_join(path)
		if path != "" and _path_exists(path):
			var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
			if res is VoxelModel:
				inst.source = res as VoxelModel
				resolved += 1
	return resolved


static func _path_exists(path: String) -> bool:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ResourceLoader.exists(path)
	return FileAccess.file_exists(path)


## Loads a parent with missing prefab sources tolerated, then resolves the
## fallbacks. Use this in a game when the parent and its Prefabs folder were
## moved together; `preload()` cannot recover missing dependencies.
static func load_with_prefabs(path: String) -> VoxelModel:
	ResourceLoader.set_abort_on_missing_resources(false)
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	ResourceLoader.set_abort_on_missing_resources(true)
	var model := res as VoxelModel
	if model == null:
		return null
	model.resolve_prefab_sources(path.get_base_dir())
	return model


## Rebuilds the stored point lights, preserving any other child nodes.
func build_lights(parent: Node3D) -> void:
	var old := parent.get_node_or_null("Lights")
	if old != null:
		parent.remove_child(old)
		old.queue_free()
	var composed: Array[Dictionary] = build_composed_lights()
	if composed.is_empty():
		return
	var group := Node3D.new()
	group.name = "Lights"
	parent.add_child(group)
	for l: Dictionary in composed:
		var light := OmniLight3D.new()
		light.name = "PointLight%d" % int(l["id"])
		light.position = (l["position"] as Vector3) * voxel_size
		light.light_color = l["color"]
		light.light_energy = l["energy"]
		light.omni_range = float(l["range"]) * voxel_size
		light.shadow_enabled = bool(l["shadows"])
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
