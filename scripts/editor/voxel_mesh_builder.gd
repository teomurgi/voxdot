class_name VoxelMeshBuilder
extends RefCounted

## Builds crisp, vertex-colored blocky voxel meshes from voxel grids.
## A grid is a Dictionary of { Vector3i: Color }. Voxel at grid position p
## occupies the space [p * voxel_size, (p + 1) * voxel_size].
## Internal faces between two solid voxels are culled.

const FACES: Array[Dictionary] = [
	{"n": Vector3i(1, 0, 0), "c": [Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)], "s": 0.80},
	{"n": Vector3i(-1, 0, 0), "c": [Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1)], "s": 0.75},
	{"n": Vector3i(0, 1, 0), "c": [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)], "s": 1.00},
	{"n": Vector3i(0, -1, 0), "c": [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0)], "s": 0.55},
	{"n": Vector3i(0, 0, 1), "c": [Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)], "s": 0.90},
	{"n": Vector3i(0, 0, -1), "c": [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)], "s": 0.70},
]

static var _shared_material: StandardMaterial3D


## Shared vertex-color material used by every voxel mesh in the framework.
static func get_material() -> StandardMaterial3D:
	if _shared_material == null:
		_shared_material = StandardMaterial3D.new()
		_shared_material.resource_name = "VoxelMaterial"
		_shared_material.vertex_color_use_as_albedo = true
		_shared_material.roughness = 0.92
		_shared_material.metallic = 0.0
	return _shared_material


## Deterministic per-voxel shade jitter in [0.90, 1.00] for texture feel.
static func _jitter(p: Vector3i) -> float:
	var h: int = int(p.x * 73856093) ^ int(p.y * 19349663) ^ int(p.z * 83492791)
	return 0.90 + 0.10 * (float(abs(h) % 1000) / 1000.0)


## Fills a solid box of voxels into the grid. Returns the grid for chaining.
static func fill_box(grid: Dictionary, origin: Vector3i, size: Vector3i, color: Color) -> Dictionary:
	for x in range(origin.x, origin.x + size.x):
		for y in range(origin.y, origin.y + size.y):
			for z in range(origin.z, origin.z + size.z):
				grid[Vector3i(x, y, z)] = color
	return grid


## Convenience: create a new grid containing one solid box.
static func box(origin: Vector3i, size: Vector3i, color: Color) -> Dictionary:
	var grid: Dictionary = {}
	return fill_box(grid, origin, size, color)


## Merges src grid into dst (src overwrites on overlap). Returns dst.
static func merge(dst: Dictionary, src: Dictionary) -> Dictionary:
	for k in src:
		dst[k] = src[k]
	return dst


## Builds an ArrayMesh from the grid. Faces between solid voxels are culled.
## Applies per-face directional shading plus deterministic per-voxel jitter.
static func build_mesh(grid: Dictionary, voxel_size: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for pos: Vector3i in grid.keys():
		var base: Color = grid[pos]
		var j: float = _jitter(pos)
		for face: Dictionary in FACES:
			var n: Vector3i = face["n"]
			if grid.has(pos + n):
				continue
			var shade: float = float(face["s"]) * j
			var col := Color(base.r * shade, base.g * shade, base.b * shade, base.a)
			var start: int = verts.size()
			for c: Vector3 in face["c"]:
				verts.append((Vector3(pos) + c) * voxel_size)
				normals.append(Vector3(n))
				colors.append(col)
			indices.append_array(PackedInt32Array([start, start + 1, start + 2, start, start + 2, start + 3]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	if not verts.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, get_material())
	return mesh


## Creates a MeshInstance3D for the given grid using the shared material.
static func make_instance(grid: Dictionary, voxel_size: float, name: String = "VoxelPart") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = build_mesh(grid, voxel_size)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi
