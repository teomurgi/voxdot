class_name VoxelModel
extends Resource

## Saved voxel asset produced by the in-engine voxel editor. Stores a sparse
## voxel grid in the same convention as VoxelMeshBuilder: voxel at grid
## position p occupies [p * voxel_size, (p + 1) * voxel_size].
##
## Voxels are packed as `cells = [x, y, z, palette_index, ...]` with a shared
## `palette`, which keeps .tres files compact. Optional `material_ids` and
## `material_overrides` byte arrays are aligned with that cell order; leaving
## them empty means every voxel uses the default solid/walkable material, so
## old files load unchanged. `swatches` is the editor's user-facing quick
## palette and does not affect rendering.

## Voxels are packed as `cells = [x, y, z, palette_index, ...]` with a shared
## `palette`, which keeps .tres files compact. Point lights use the optional
## packed `lights` array below; old resources without it still load unchanged.
@export var voxel_size: float = 0.0625
@export var bounds: Vector3i = Vector3i(32, 32, 32)
@export var swatches: PackedColorArray = PackedColorArray()
@export var palette: PackedColorArray = PackedColorArray()
@export var cells: PackedInt32Array = PackedInt32Array()
## Optional per-voxel material IDs (VoxelMaterial.Kind), aligned with `cells`.
## Empty means every voxel uses the default material, so old files load unchanged.
@export var material_ids: PackedByteArray = PackedByteArray()
## Optional per-voxel solid/walkable overrides aligned with `cells`. Empty means
## every voxel inherits its material's flags. See VoxelMaterial.make_overrides().
@export var material_overrides: PackedByteArray = PackedByteArray()
## Flipbook animation: extra frames beyond the base `cells`. Each entry of
## `anim_frame_cells` uses the same packed xyz+palette-index layout as `cells`
## with its own palette in `anim_frame_palettes`; materials/overrides align
## per frame (empty = default/inherit). `anim_frame_times` holds one duration
## per frame, index-aligned (frame 0 first); older files stored only the extra
## frames, which the editor still accepts (see VoxelDocument.load_model).
## `anim_mode` is 0=once, 1=loop, 2=ping-pong. All empty/zero = static model,
## so old files load unchanged and static models pay nothing.
@export var anim_frame_cells: Array[PackedInt32Array] = []
@export var anim_frame_palettes: Array[PackedColorArray] = []
@export var anim_frame_materials: Array[PackedByteArray] = []
@export var anim_frame_overrides: Array[PackedByteArray] = []
@export var anim_frame_times: PackedFloat32Array = PackedFloat32Array()
@export var anim_mode: int = 0
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
## Character part slot overrides (slot name -> saved-model path). Same
## external-reference pattern as prefab sources: paths only, never embedded
## geometry. Empty means the procedural part grid is used.
@export var character_slots: Dictionary = {}
## Optional procedural appearance (preset and slot indices); empty preserves defaults.
@export var character_style: Dictionary = {}


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
	set_cells(grid)


## Replaces the stored voxels with `grid` plus sparse material/override maps.
## Material arrays are only written when at least one voxel differs from the
## defaults, keeping old-style files compact.
func set_cells(grid: Dictionary, material_grid: Dictionary = {}, override_grid: Dictionary = {}) -> void:
	var keys: Array = grid.keys()
	keys.sort_custom(_cell_less)
	var new_palette := PackedColorArray()
	var lookup: Dictionary = {}
	var out := PackedInt32Array()
	out.resize(keys.size() * 4)
	# Fast path: all-default metadata writes no arrays, so big color-only
	# models never pay for transient per-voxel byte buffers.
	var sparse_mats: Dictionary = {}
	var sparse_ovs: Dictionary = {}
	for p: Vector3i in material_grid:
		var k: int = clampi(int(material_grid[p]), 0, VoxelMaterial.count() - 1)
		if k != VoxelMaterial.Kind.DEFAULT:
			sparse_mats[p] = k
	for p: Vector3i in override_grid:
		var b: int = int(override_grid[p]) & 0xFF
		if b != 0:
			sparse_ovs[p] = b
	var any_material: bool = not sparse_mats.is_empty()
	var any_override: bool = not sparse_ovs.is_empty()
	var mats := PackedByteArray()
	var ovs := PackedByteArray()
	if any_material:
		mats.resize(keys.size())
	if any_override:
		ovs.resize(keys.size())
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
		var idx: int = o >> 2
		if any_material:
			mats[idx] = int(sparse_mats.get(p, VoxelMaterial.Kind.DEFAULT))
		if any_override:
			ovs[idx] = int(sparse_ovs.get(p, 0))
		o += 4
	palette = new_palette
	cells = out
	material_ids = mats if any_material else PackedByteArray()
	material_overrides = ovs if any_override else PackedByteArray()


## Sparse { Vector3i: material Kind } for voxels that do not use the default.
func to_material_grid() -> Dictionary:
	var out: Dictionary = {}
	var n: int = voxel_count()
	if material_ids.size() != n:
		return out
	for i in n:
		var kind: int = int(material_ids[i])
		if kind != VoxelMaterial.Kind.DEFAULT:
			out[Vector3i(cells[i * 4], cells[i * 4 + 1], cells[i * 4 + 2])] = kind
	return out


## Sparse { Vector3i: override bits } for voxels with explicit solid/walkable
## overrides.
func to_override_grid() -> Dictionary:
	var out: Dictionary = {}
	var n: int = voxel_count()
	if material_overrides.size() != n:
		return out
	for i in n:
		var bits: int = int(material_overrides[i])
		if bits != 0:
			out[Vector3i(cells[i * 4], cells[i * 4 + 1], cells[i * 4 + 2])] = bits
	return out


## Number of flipbook frames including the base `cells` (1 = static model).
func frame_count() -> int:
	return 1 + anim_frame_cells.size()


## Frame `i` as { Vector3i: Color }. Frame 0 is the base grid.
func frame_grid(i: int) -> Dictionary:
	if i <= 0:
		return to_grid()
	var j: int = i - 1
	if j >= anim_frame_cells.size() or j >= anim_frame_palettes.size():
		return {}
	var out: Dictionary = {}
	var packed: PackedInt32Array = anim_frame_cells[j]
	var pal: PackedColorArray = anim_frame_palettes[j]
	for k in range(0, packed.size() - 3, 4):
		var idx: int = packed[k + 3]
		if idx < 0 or idx >= pal.size():
			continue
		out[Vector3i(packed[k], packed[k + 1], packed[k + 2])] = pal[idx]
	return out


## Frame `i` sparse material/override maps (same shape as the base getters).
func frame_material_grid(i: int) -> Dictionary:
	return _frame_byte_grid(i, true)


func frame_override_grid(i: int) -> Dictionary:
	return _frame_byte_grid(i, false)


func _frame_byte_grid(i: int, want_material: bool) -> Dictionary:
	var out: Dictionary = {}
	if i <= 0:
		return to_material_grid() if want_material else to_override_grid()
	var j: int = i - 1
	var arr: PackedByteArray = (anim_frame_materials[j] if want_material else anim_frame_overrides[j]) \
		if j < (anim_frame_materials if want_material else anim_frame_overrides).size() else PackedByteArray()
	var packed: PackedInt32Array = anim_frame_cells[j] if j < anim_frame_cells.size() else PackedInt32Array()
	if arr.size() != packed.size() >> 2:
		return out
	for k in arr.size():
		var v: int = int(arr[k])
		var keep: bool = v != VoxelMaterial.Kind.DEFAULT if want_material else v != 0
		if keep:
			out[Vector3i(packed[k * 4], packed[k * 4 + 1], packed[k * 4 + 2])] = v
	return out


## Appends the packed encoding of `grid` as a new frame. Mirrors `set_cells`
## (sorted keys, per-frame palette, sparse metadata) without touching the base.
func append_frame(grid: Dictionary, material_grid: Dictionary = {}, override_grid: Dictionary = {}) -> void:
	var keys: Array = grid.keys()
	keys.sort_custom(_cell_less)
	var new_palette := PackedColorArray()
	var lookup: Dictionary = {}
	var sparse_mats: Dictionary = {}
	var sparse_ovs: Dictionary = {}
	for p: Vector3i in material_grid:
		var k: int = clampi(int(material_grid[p]), 0, VoxelMaterial.count() - 1)
		if k != VoxelMaterial.Kind.DEFAULT:
			sparse_mats[p] = k
	for p: Vector3i in override_grid:
		var b: int = int(override_grid[p]) & 0xFF
		if b != 0:
			sparse_ovs[p] = b
	var any_material: bool = not sparse_mats.is_empty()
	var any_override: bool = not sparse_ovs.is_empty()
	var out := PackedInt32Array()
	out.resize(keys.size() * 4)
	var mats := PackedByteArray()
	var ovs := PackedByteArray()
	if any_material:
		mats.resize(keys.size())
	if any_override:
		ovs.resize(keys.size())
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
		var idx: int = o >> 2
		if any_material:
			mats[idx] = int(sparse_mats.get(p, VoxelMaterial.Kind.DEFAULT))
		if any_override:
			ovs[idx] = int(sparse_ovs.get(p, 0))
		o += 4
	anim_frame_cells.append(out)
	anim_frame_palettes.append(new_palette)
	anim_frame_materials.append(mats)
	anim_frame_overrides.append(ovs)
	# Times stay the document's job: _persist_frames appends one per frame.

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


## Composed colors, materials and overrides in one pass. Local cells win over
## instance cells, and earlier instances win over later ones, matching
## build_composed_grid(). The sparse material/override maps only contain
## non-default values.
func build_composed_data() -> Dictionary:
	var colors: Dictionary = to_grid()
	var materials: Dictionary = to_material_grid()
	var overrides: Dictionary = to_override_grid()
	for inst: VoxelPrefabInstance in prefab_instances:
		if inst == null or inst.source == null or not inst.source.prefab_instances.is_empty():
			continue
		var src_colors: Dictionary = inst.source.to_grid()
		var src_materials: Dictionary = inst.source.to_material_grid()
		var src_overrides: Dictionary = inst.source.to_override_grid()
		for c: Vector3i in src_colors:
			var world: Vector3i = inst.anchor + VoxelPrefabInstance.cell_offset(
					c, inst.pivot, inst.yaw_quarters)
			if colors.has(world):
				continue
			colors[world] = src_colors[c]
			if src_materials.has(c):
				materials[world] = src_materials[c]
			if src_overrides.has(c):
				overrides[world] = src_overrides[c]
	return {"colors": colors, "materials": materials, "overrides": overrides}


func material_kind_at(cell: Vector3i, data: Dictionary = {}) -> int:
	if data.is_empty():
		data = build_composed_data()
	if not (data.get("colors", {}) as Dictionary).has(cell):
		return VoxelMaterial.Kind.DEFAULT
	return int((data.get("materials", {}) as Dictionary).get(cell, VoxelMaterial.Kind.DEFAULT))


func material_override_at(cell: Vector3i, data: Dictionary = {}) -> int:
	if data.is_empty():
		data = build_composed_data()
	return int((data.get("overrides", {}) as Dictionary).get(cell, 0))


func is_solid_cell(cell: Vector3i, data: Dictionary = {}) -> bool:
	if data.is_empty():
		data = build_composed_data()
	if not (data.get("colors", {}) as Dictionary).has(cell):
		return false
	return VoxelMaterial.is_solid(material_kind_at(cell, data), material_override_at(cell, data))


## A walkable surface is a solid, walkable cell whose cell above is not solid.
## Steps/ramps are represented by adjacent surface cells; the caller's nav
## system decides whether the height change is traversable.
func is_walkable_cell(cell: Vector3i, data: Dictionary = {}) -> bool:
	if data.is_empty():
		data = build_composed_data()
	if not (data.get("colors", {}) as Dictionary).has(cell):
		return false
	var kind: int = material_kind_at(cell, data)
	var bits: int = material_override_at(cell, data)
	if not VoxelMaterial.is_solid(kind, bits) or not VoxelMaterial.is_walkable(kind, bits):
		return false
	var above: Vector3i = cell + Vector3i.UP
	if not (data.get("colors", {}) as Dictionary).has(above):
		return true
	return not is_solid_cell(above, data)


## Every top-surface cell that a walker can stand on. Returns cells, not world
## coordinates; multiply by voxel_size in the game.
func walkable_cells() -> Array[Vector3i]:
	var data: Dictionary = build_composed_data()
	var out: Array[Vector3i] = []
	for cell: Vector3i in data["colors"]:
		if is_walkable_cell(cell, data):
			out.append(cell)
	return out


## Cells that should contribute collision. Non-solid materials (water, etc.)
## are rendered but omitted here.
func build_solid_grid() -> Dictionary:
	var data: Dictionary = build_composed_data()
	var colors: Dictionary = data["colors"]
	var out: Dictionary = {}
	for cell: Vector3i in colors:
		if is_solid_cell(cell, data):
			out[cell] = colors[cell]
	return out


## Render mesh for collision only. Returns an empty ArrayMesh when the model
## has no solid cells.
func build_collision_mesh() -> ArrayMesh:
	var solid: Dictionary = build_solid_grid()
	if solid.is_empty():
		return ArrayMesh.new()
	return VoxelMeshBuilder.build_mesh(solid, voxel_size)


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
		if inst == null:
			continue
		var local_path: String = resolve_asset_path(inst.source_path, base_dir)
		if inst.source_path != "" and _path_exists(local_path):
			inst.source = ResourceLoader.load(local_path, "", ResourceLoader.CACHE_MODE_IGNORE) as VoxelModel
			if inst.source != null:
				resolved += 1
				continue
		if inst.source != null:
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


## Resolve an asset path against the containing model, not the editor project.
static func resolve_asset_path(path: String, base_dir: String) -> String:
	if path == "" or path.is_absolute_path():
		return path
	return base_dir.path_join(path).simplify_path()


static func relative_asset_path(base_dir: String, target: String) -> String:
	var base: String = ProjectSettings.globalize_path(base_dir).simplify_path()
	var dest: String = ProjectSettings.globalize_path(target).simplify_path()
	var a: PackedStringArray = base.split("/", false)
	var b: PackedStringArray = dest.split("/", false)
	if a.is_empty() or b.is_empty() or a[0] != b[0]:
		return target
	var common: int = 0
	while common < mini(a.size(), b.size()) and a[common] == b[common]:
		common += 1
	var parts := PackedStringArray()
	for i in range(common, a.size()):
		parts.append("..")
	for i in range(common, b.size()):
		parts.append(b[i])
	return "/".join(parts)


## ResourceSaver only relativizes resources inside its own res:// tree.
## Normalize native asset dependencies too, so an external game's assets
## remain portable. Script paths stay canonical res:// paths in both apps.
func save_portable(target: String) -> Error:
	var err: Error = ResourceSaver.save(self, target, ResourceSaver.FLAG_RELATIVE_PATHS)
	if err != OK or target.get_extension().to_lower() != "tres":
		return err
	var lines: PackedStringArray = FileAccess.get_file_as_string(target).split("\n")
	var pattern := RegEx.new()
	pattern.compile(r'path="([^"\\]*(?:\\.[^"\\]*)*)"')
	for i in lines.size():
		if not lines[i].begins_with('[ext_resource type="Resource"'):
			continue
		var found: RegExMatch = pattern.search(lines[i])
		if found == null:
			continue
		var original: String = found.get_string(1).c_unescape()
		if original.is_absolute_path():
			var relative: String = relative_asset_path(target.get_base_dir(), original)
			lines[i] = lines[i].substr(0, found.get_start(1)) + relative.c_escape() + lines[i].substr(found.get_end(1))
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string("\n".join(lines))
	return file.get_error()
