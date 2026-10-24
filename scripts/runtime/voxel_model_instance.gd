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

var _built: bool = false


func _ready() -> void:
	_built = true
	rebuild()


func rebuild() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	if model == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = model.build_mesh()
	add_child(mi)
	model.build_lights(self)
	_add_missing_debug()
	if not with_collision or Engine.is_editor_hint():
		return
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return
	var body := StaticBody3D.new()
	body.name = "Collision"
	var shape := CollisionShape3D.new()
	shape.shape = mi.mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)


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
