class_name VoxelPrefabRig
extends Node3D

## Editor-side visuals for linked prefabs: placement/drag ghost, selection
## outline, red placeholder boxes for missing/conflicted instances, and the
## transformed instance lights. It never edits the document.

const LARGE_CELLS: int = 50000

var _ghost: MeshInstance3D
var _ghost_box: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _ghost_key: String = ""
var _selection: MeshInstance3D
var _selection_box: MeshInstance3D
var _pivot: MeshInstance3D
var _lights: Node3D
var _light_nodes: Dictionary = {} # id -> Array[OmniLight3D]
var _light_sigs: Dictionary = {} # id -> String (world light payload signature)
var _placeholders: Dictionary = {} # id -> MeshInstance3D
var _selection_key: String = ""
var _built: bool = false


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.vertex_color_use_as_albedo = true
	_ghost_mat.albedo_color = Color(1, 1, 1, 0.45)
	_ghost = MeshInstance3D.new()
	_ghost.name = "PrefabGhost"
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost)
	_ghost_box = _line_mesh_instance("PrefabGhostBox", Color(1, 1, 1, 0.6))
	_selection = _line_mesh_instance("PrefabSelection", Color(1.0, 0.85, 0.3, 0.95))
	_selection_box = _line_mesh_instance("PrefabSelectionBox", Color(1.0, 0.85, 0.3, 0.55))
	_pivot = _line_mesh_instance("PrefabPivot", Color(0.4, 1.0, 1.0, 0.95))
	_pivot.mesh = _cross_mesh(Vector3.ZERO, 1.25, Color(0.4, 1.0, 1.0, 0.95))
	_lights = Node3D.new()
	_lights.name = "PrefabLights"
	add_child(_lights)


func _line_mesh_instance(node_name: String, _color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return mi


func _ready() -> void:
	_ensure_built()


## Rebuilds instance lights, placeholder boxes and the current selection.
func sync(doc: VoxelDocument, selected_id: int = -1) -> void:
	_ensure_built()
	_sync_lights(doc)
	_sync_placeholders(doc)
	_show_selection(doc, selected_id)


func clear() -> void:
	_ensure_built()
	hide_ghost()
	_selection.visible = false
	_selection_box.visible = false
	_pivot.visible = false
	_selection_key = ""
	for id: int in _placeholders:
		var ph: MeshInstance3D = _placeholders[id]
		remove_child(ph)
		ph.queue_free()
	_placeholders.clear()
	for id: int in _light_nodes.keys():
		_free_light_nodes(id)
	for child: Node in _lights.get_children():
		_lights.remove_child(child)
		child.queue_free()


func hide_ghost() -> void:
	if not _built:
		return
	_ghost.visible = false
	_ghost_box.visible = false


## Shows a translucent preview of `source` with its transformed pivot at
## `anchor`. `valid=false` tints it red. Large sources and missing sources use
## an AABB wireframe instead of a mesh.
func show_ghost(source: VoxelModel, pivot: Vector3, anchor: Vector3i, yaw: int,
		valid: bool, source_bounds: AABB = AABB()) -> void:
	_ensure_built()
	var tint: Color = Color(0.35, 1.0, 0.45, 0.42) if valid else Color(1.0, 0.25, 0.25, 0.5)
	_ghost_mat.albedo_color = tint
	var cells: int = source.voxel_count() if source != null else 0
	if source == null or cells > LARGE_CELLS:
		_ghost.visible = false
		_ghost_box.visible = true
		_ghost_box.mesh = _transformed_box_mesh(source_bounds, pivot, anchor, yaw, tint)
		return
	_ghost_box.visible = false
	_ghost.visible = true
	_ghost.position = Vector3(anchor)
	var key: String = "%d|%s|%s|%d|%d|%d" % [
		source.get_instance_id(), source.resource_path, pivot, yaw,
		source.cells.size(), source.palette.size()]
	if key != _ghost_key:
		_ghost_key = key
		var grid: Dictionary = {}
		var src: Dictionary = source.to_grid()
		for c: Vector3i in src:
			grid[VoxelPrefabInstance.cell_offset(c, pivot, yaw)] = src[c]
		var mesh: ArrayMesh = VoxelMeshBuilder.build_mesh(grid, 1.0)
		if mesh.get_surface_count() > 0:
			mesh.surface_set_material(0, _ghost_mat)
		_ghost.mesh = mesh


## Returns the nearest non-ok instance whose placeholder AABB the ray hits.
func pick_placeholder(doc: VoxelDocument, origin: Vector3, dir: Vector3) -> int:
	_ensure_built()
	var best: int = -1
	var best_t: float = INF
	for inst: VoxelPrefabInstance in doc.prefab_instances:
		if inst == null:
			continue
		var st: Dictionary = doc.prefab_status(inst.instance_id)
		if str(st.get("state", "ok")) == "ok":
			continue
		var box: AABB = inst.placeholder_bounds() if inst.source == null else doc.prefab_bounds(inst.instance_id)
		if box.size.is_zero_approx():
			continue
		var hit: Variant = box.intersects_ray(origin, dir)
		if hit == null:
			continue
		var t: float = (hit as Vector3).distance_to(origin)
		if t < best_t:
			best_t = t
			best = inst.instance_id
	return best


func _sync_lights(doc: VoxelDocument) -> void:
	var live: Dictionary = {}
	for inst: VoxelPrefabInstance in doc.prefab_instances:
		if inst == null:
			continue
		var st: Dictionary = doc.prefab_status(inst.instance_id)
		if str(st.get("state", "ok")) != "ok":
			continue
		live[inst.instance_id] = true
		var lights: Array[Dictionary] = doc.prefab_world_lights(inst.instance_id)
		var sig: String = _lights_signature(lights)
		var nodes: Array = _light_nodes.get(inst.instance_id, [])
		if _light_sigs.get(inst.instance_id, "") == sig and nodes.size() == lights.size():
			continue
		# Recreate only when the count changes; otherwise retune in place so a
		# moved instance does not churn hundreds of nodes per drag step.
		if nodes.size() != lights.size():
			_free_light_nodes(inst.instance_id)
			nodes = []
			for i in lights.size():
				var omni := OmniLight3D.new()
				omni.name = "Prefab%d_Light%d" % [inst.instance_id, i]
				_lights.add_child(omni)
				nodes.append(omni)
			_light_nodes[inst.instance_id] = nodes
		for i in lights.size():
			var l: Dictionary = lights[i]
			var node: OmniLight3D = nodes[i]
			node.position = l["position"]
			node.light_color = l["color"]
			node.light_energy = float(l["energy"])
			node.omni_range = float(l["range"])
			node.shadow_enabled = bool(l["shadows"])
		_light_sigs[inst.instance_id] = sig
	for id: int in _light_nodes.keys():
		if not live.has(id):
			_free_light_nodes(id)


func _free_light_nodes(id: int) -> void:
	for node: OmniLight3D in _light_nodes.get(id, []):
		_lights.remove_child(node)
		node.queue_free()
	_light_nodes.erase(id)
	_light_sigs.erase(id)


static func _lights_signature(lights: Array[Dictionary]) -> String:
	var parts := PackedStringArray()
	for l: Dictionary in lights:
		parts.append("%s|%s|%s|%s|%s" % [l["position"], l["color"], l["energy"],
			l["range"], l["shadows"]])
	return ";".join(parts)


func _sync_placeholders(doc: VoxelDocument) -> void:
	var seen: Dictionary = {}
	for inst: VoxelPrefabInstance in doc.prefab_instances:
		if inst == null:
			continue
		var st: Dictionary = doc.prefab_status(inst.instance_id)
		if str(st.get("state", "ok")) == "ok":
			continue
		seen[inst.instance_id] = true
		var mi: MeshInstance3D = _placeholders.get(inst.instance_id)
		if mi == null:
			mi = _line_mesh_instance("PrefabProblem%d" % inst.instance_id,
				Color(1.0, 0.25, 0.25, 0.9))
			_placeholders[inst.instance_id] = mi
		var box: AABB = inst.placeholder_bounds() if inst.source == null else doc.prefab_bounds(inst.instance_id)
		mi.mesh = _box_mesh(box, Color(1.0, 0.25, 0.25, 0.9))
		mi.visible = true
	for id: int in _placeholders.keys():
		if not seen.has(id):
			var ph: MeshInstance3D = _placeholders[id]
			remove_child(ph)
			ph.queue_free()
			_placeholders.erase(id)


func _show_selection(doc: VoxelDocument, id: int) -> void:
	if id < 0 or doc.prefab_instance(id) == null:
		_selection.visible = false
		_selection_box.visible = false
		_pivot.visible = false
		_selection_key = ""
		return
	var inst: VoxelPrefabInstance = doc.prefab_instance(id)
	var box: AABB = doc.prefab_bounds(id)
	if box.size.is_zero_approx():
		box = inst.placeholder_bounds()
	var cells: Array[Vector3i] = doc.prefab_world_cells(id)
	if cells.is_empty() or cells.size() > LARGE_CELLS:
		_selection.visible = false
		_selection_box.visible = true
		_selection_box.mesh = _box_mesh(box, Color(1.0, 0.85, 0.3, 0.7))
		_selection_key = ""
	else:
		_selection_box.visible = false
		_selection.visible = true
		# Outline geometry only depends on the instance's world cells. `hash`
		# covers the contents, so a source edit that keeps the same count still
		# refreshes the outline.
		var key := "%d|%d|%d" % [id, hash(cells),
			inst.source.get_instance_id() if inst.source != null else 0]
		if key != _selection_key:
			_selection_key = key
			_selection.mesh = _cells_mesh(cells, Color(1.0, 0.85, 0.3, 0.95))
	_pivot.visible = true
	_pivot.position = Vector3(inst.anchor)


func _cells_mesh(cells: Array[Vector3i], c: Color) -> ArrayMesh:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for p: Vector3i in cells:
		_append_box_edges(verts, cols, AABB(Vector3(p), Vector3.ONE), c)
	return _line_mesh(verts, cols)


func _box_mesh(box: AABB, c: Color) -> ArrayMesh:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	_append_box_edges(verts, cols, box, c)
	return _line_mesh(verts, cols)


func _transformed_box_mesh(source_bounds: AABB, pivot: Vector3, anchor: Vector3i,
		yaw: int, c: Color) -> ArrayMesh:
	var b: AABB = source_bounds
	if b.size.is_zero_approx():
		b = AABB(Vector3.ZERO, Vector3.ONE)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in 8:
		var corner: Vector3 = b.position + Vector3(
			b.size.x * float(i & 1),
			b.size.y * float((i >> 1) & 1),
			b.size.z * float((i >> 2) & 1))
		var p: Vector3 = Vector3(anchor) + VoxelPrefabInstance.light_offset(corner, pivot, yaw)
		lo = lo.min(p)
		hi = hi.max(p)
	var box := AABB(lo, (hi - lo).max(Vector3.ONE))
	return _box_mesh(box, c)


func _append_box_edges(verts: PackedVector3Array, cols: PackedColorArray,
		box: AABB, c: Color) -> void:
	var p: Vector3 = box.position
	var s: Vector3 = box.size
	var corners: Array[Vector3] = [
		p, p + Vector3(s.x, 0, 0), p + Vector3(s.x, 0, s.z), p + Vector3(0, 0, s.z),
		p + Vector3(0, s.y, 0), p + Vector3(s.x, s.y, 0),
		p + Vector3(s.x, s.y, s.z), p + Vector3(0, s.y, s.z),
	]
	for pair: Vector2i in [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]:
		verts.append(corners[pair.x])
		verts.append(corners[pair.y])
		cols.append(c)
		cols.append(c)


func _line_mesh(verts: PackedVector3Array, cols: PackedColorArray) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, mat)
	return mesh


func _cross_mesh(center: Vector3, size: float, c: Color) -> ArrayMesh:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		verts.append(center - axis * size)
		verts.append(center + axis * size)
		cols.append(c)
		cols.append(c)
	return _line_mesh(verts, cols)
