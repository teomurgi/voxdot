@tool
class_name VoxelModelInstance
extends Node3D

## Drops a VoxelModel saved by the voxel editor into any scene. The mesh is
## scaled to the model's real-world `voxel_size`; optionally adds trimesh
## collision (skipped inside the Godot editor, like VoxelArenaBuilder).

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
