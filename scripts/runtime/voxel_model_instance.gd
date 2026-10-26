@tool
class_name VoxelModelInstance
extends Node3D

## Drops a VoxelModel saved by the voxel editor into any scene. The mesh is
## scaled to the model's real-world `voxel_size`; optionally adds trimesh
## collision (skipped inside the Godot editor, like VoxelArenaBuilder).
##
## Linked prefab instances are composed into the same mesh and light set. The
## parent model owns the voxel size: source voxel sizes are ignored, so one
## instance transform applies to the whole composition.

@export var model: VoxelModel:
	set(v):
		model = v
		if _built:
			rebuild()

@export var with_collision: bool = false:
	set(v):
		with_collision = v
		if _built:
			rebuild()

## Debug aid for missing/incompatible prefab sources. Off by default: a shipped
## game skips unresolved instances instead of drawing editor-style wireframes.
@export var show_missing_prefabs: bool = false:
	set(v):
		show_missing_prefabs = v
		if _built:
			rebuild()

## Flipbooks animate visual cells only. Collision/material queries stay on
## frame zero, so a decorative flame cannot rebuild physics every frame.
@export var autoplay: bool = true
@export var animate_in_editor: bool = false
var current_frame: int = 0
var playing: bool = false
var _elapsed: float = 0.0
var _direction: int = 1
var _frame_render: Dictionary = {}
var _hidden_occluding_groups: Dictionary = {}
var _occluding_group_nodes: Dictionary = {}
## Current frame's occluding groups, keyed by
## Vector2i(prefab_instance_id, occluding_group_id). Each value contains the
## MeshInstance3D, its model-space cells and their broad-phase AABB.
var occluding_groups: Dictionary = {}

var _built: bool = false
var _cell_data: Dictionary = {}
var _walkable: Array[Vector3i] = []
var _walkable_built: bool = false


func _ready() -> void:
	_built = true
	rebuild()


func rebuild() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	playing = false
	current_frame = 0
	_elapsed = 0.0
	_direction = 1
	_frame_render.clear()
	_hidden_occluding_groups.clear()
	_occluding_group_nodes.clear()
	occluding_groups.clear()
	_cell_data = {}
	_walkable.clear()
	_walkable_built = false
	if model == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	add_child(mi)
	_apply_render_frame(0)
	playing = autoplay and model.frame_count() > 1
	model.build_lights(self)
	_add_missing_debug()
	if not with_collision or Engine.is_editor_hint():
		return
	var collision_mesh: ArrayMesh = model.build_collision_mesh()
	if collision_mesh == null or collision_mesh.get_surface_count() == 0:
		return
	var body := StaticBody3D.new()
	body.name = "Collision"
	var shape := CollisionShape3D.new()
	shape.shape = collision_mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)


## Cached composed colors/materials/overrides for runtime queries.
func cell_data() -> Dictionary:
	if _cell_data.is_empty() and model != null:
		_cell_data = model.build_composed_data()
	return _cell_data


func material_kind_at(cell: Vector3i) -> int:
	if model == null:
		return VoxelMaterial.Kind.DEFAULT
	return model.material_kind_at(cell, cell_data())


func material_override_at(cell: Vector3i) -> int:
	if model == null:
		return 0
	return model.material_override_at(cell, cell_data())


func is_solid_cell(cell: Vector3i) -> bool:
	return model != null and model.is_solid_cell(cell, cell_data())


func is_walkable_cell(cell: Vector3i) -> bool:
	return model != null and model.is_walkable_cell(cell, cell_data())


## Top-surface cells a walker can stand on. Cached until the next rebuild().
func walkable_cells() -> Array[Vector3i]:
	if not _walkable_built:
		if model != null:
			_walkable = model.walkable_cells()
		else:
			_walkable = []
		_walkable_built = true
	return _walkable


## Warns once per unresolved instance and optionally draws its snapshot AABB.
## The AABB is transformed around the saved pivot/anchor, so a debug build can
## show where the missing prefab would have been without its source.
func _add_missing_debug() -> void:
	var group: Node3D = null
	for inst: VoxelPrefabInstance in model.prefab_instances:
		if inst == null:
			continue
		var reason: String = ""
		if inst.source == null:
			reason = "missing prefab source " + (inst.source_path if inst.source_path != "" else "(no path)")
		elif not inst.source.prefab_instances.is_empty():
			reason = "prefab source contains prefabs (nesting is not supported)"
		if reason == "":
			continue
		push_warning("VoxelModelInstance: %s (instance %d)" % [reason, inst.instance_id])
		if not show_missing_prefabs:
			continue
		if group == null:
			group = Node3D.new()
			group.name = "MissingPrefabs"
			add_child(group)
		group.add_child(_missing_box(inst))


func _missing_box(inst: VoxelPrefabInstance) -> MeshInstance3D:
	var box: AABB = inst.placeholder_bounds()
	if box.size.is_zero_approx():
		box = AABB(Vector3(inst.anchor), Vector3.ONE)
	var size: Vector3 = box.size * model.voxel_size
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.15, 0.9, 0.35)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Missing%d" % inst.instance_id
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = (box.position + box.size * 0.5) * model.voxel_size
	return mi


func _render_frame(frame: int) -> Dictionary:
	if not _frame_render.has(frame):
		var grids: Dictionary = model.build_render_grids(frame)
		var groups: Dictionary = {}
		for key: Vector2i in grids["groups"]:
			var grid: Dictionary = grids["groups"][key]
			var cells: Array[Vector3i] = []
			cells.assign(grid.keys())
			var vs: float = model.voxel_size
			var bounds := AABB()
			for i in cells.size():
				var box := AABB(Vector3(cells[i]) * vs, Vector3.ONE * vs)
				bounds = box if i == 0 else bounds.merge(box)
			groups[key] = {
				"mesh": VoxelMeshBuilder.build_mesh(grid, model.voxel_size),
				"cells": cells,
				"bounds": bounds,
			}
		_frame_render[frame] = {
			"mesh": VoxelMeshBuilder.build_mesh(grids["base"], model.voxel_size),
			"groups": groups,
		}
	return _frame_render[frame]


func _apply_render_frame(frame: int) -> void:
	var render: Dictionary = _render_frame(frame)
	(get_node("Mesh") as MeshInstance3D).mesh = render["mesh"]
	occluding_groups.clear()
	for key: Vector2i in render["groups"]:
		var info: Dictionary = render["groups"][key]
		var node := _occluding_group_nodes.get(key) as MeshInstance3D
		if node == null:
			node = MeshInstance3D.new()
			node.name = "OccludingGroup_%d_%d" % [key.x, key.y]
			add_child(node)
			_occluding_group_nodes[key] = node
		node.mesh = info["mesh"]
		node.visible = not _hidden_occluding_groups.has(key)
		info["node"] = node
		occluding_groups[key] = info
	for key: Vector2i in _occluding_group_nodes:
		if not occluding_groups.has(key):
			(_occluding_group_nodes[key] as MeshInstance3D).visible = false


func set_occluding_group_hidden(key: Vector2i, hidden: bool) -> void:
	if hidden:
		_hidden_occluding_groups[key] = true
	else:
		_hidden_occluding_groups.erase(key)
	var node := _occluding_group_nodes.get(key) as MeshInstance3D
	if node != null:
		node.visible = not hidden and occluding_groups.has(key)


func play() -> void:
	set_frame(0)
	_elapsed = 0.0
	_direction = 1
	playing = model != null and model.frame_count() > 1


func stop() -> void:
	playing = false


func frame_duration(frame: int) -> float:
	if model == null:
		return 0.5
	var times: PackedFloat32Array = model.anim_frame_times
	# Accept legacy extra-frame-only timings, like VoxelDocument.
	var index: int = frame if times.size() >= model.frame_count() else frame - 1
	if index < 0 or index >= times.size() or not is_finite(times[index]):
		return 0.5
	return clampf(times[index], 0.05, 10.0)


func set_frame(frame: int) -> void:
	if model == null or frame < 0 or frame >= model.frame_count():
		return
	if get_node_or_null("Mesh") == null:
		return
	_apply_render_frame(frame)
	current_frame = frame


func _process(delta: float) -> void:
	if not playing or model == null or (Engine.is_editor_hint() and not animate_in_editor):
		return
	_elapsed += delta
	while playing and _elapsed >= frame_duration(current_frame):
		_elapsed -= frame_duration(current_frame)
		var next: int = current_frame + _direction
		if model.anim_mode == 2:
			if next >= model.frame_count() or next < 0:
				_direction = -_direction
				next = current_frame + _direction
		elif next >= model.frame_count():
			if model.anim_mode == 1:
				next = 0
			else:
				playing = false
				break
		set_frame(next)
