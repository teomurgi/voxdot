class_name VoxelLightRig
extends Node3D

## View-only counterpart of VoxelDocument.lights. Actual OmniLight3D nodes are
## separate from editing handles, so clean screenshots can hide only the latter.

var lights_root: Node3D
var handles_root: Node3D
var nodes: Dictionary = {} # id -> {light, handle}
var handles_visible: bool = true:
	set(value):
		handles_visible = value
		if handles_root != null:
			handles_root.visible = value
var selected_id: int = -1


func _ready() -> void:
	lights_root = Node3D.new()
	lights_root.name = "Lights"
	add_child(lights_root)
	handles_root = Node3D.new()
	handles_root.name = "Handles"
	add_child(handles_root)
	handles_root.visible = handles_visible


func sync(specs: Dictionary, selected: int = -1) -> void:
	selected_id = selected
	for id: int in nodes.keys():
		if not specs.has(id):
			(nodes[id]["light"] as OmniLight3D).queue_free()
			(nodes[id]["handle"] as MeshInstance3D).queue_free()
			nodes.erase(id)
	for id: int in specs:
		var spec: Dictionary = specs[id]
		if not nodes.has(id):
			var light := OmniLight3D.new()
			light.name = "PointLight%d" % id
			lights_root.add_child(light)
			var mesh := SphereMesh.new()
			mesh.radius = 0.5
			mesh.height = 1.0
			mesh.radial_segments = 12
			mesh.rings = 6
			var handle := MeshInstance3D.new()
			handle.name = "Handle%d" % id
			handle.mesh = mesh
			handle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			handles_root.add_child(handle)
			nodes[id] = {"light": light, "handle": handle}
		var light: OmniLight3D = nodes[id]["light"]
		var handle: MeshInstance3D = nodes[id]["handle"]
		light.position = spec["position"]
		light.light_color = spec["color"]
		light.light_energy = spec["energy"]
		light.omni_range = spec["range"]
		light.shadow_enabled = spec["shadows"]
		handle.position = spec["position"]
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color.WHITE if id == selected else spec["color"]
		handle.mesh.material = mat
		handle.scale = Vector3.ONE * (1.5 if id == selected else 1.0)


func update_handle_scales(camera: Camera3D) -> void:
	for id: int in nodes:
		var handle: MeshInstance3D = nodes[id]["handle"]
		var size: float = clampf(camera.global_position.distance_to(handle.position) * 0.014, 0.4, 4.0)
		handle.scale = Vector3.ONE * size * (1.5 if id == selected_id else 1.0)


func pick(origin: Vector3, dir: Vector3) -> int:
	if not handles_visible:
		return -1
	var nearest: float = INF
	var result: int = -1
	for id: int in nodes:
		var handle: MeshInstance3D = nodes[id]["handle"]
		var radius: float = handle.global_basis.get_scale().x * 0.8
		var oc: Vector3 = origin - handle.global_position
		var b: float = 2.0 * oc.dot(dir)
		var c: float = oc.length_squared() - radius * radius
		var discriminant: float = b * b - 4.0 * c
		if discriminant < 0.0:
			continue
		var distance: float = (-b - sqrt(discriminant)) * 0.5
		if distance < 0.0:
			distance = (-b + sqrt(discriminant)) * 0.5
		if distance >= 0.0 and distance < nearest:
			nearest = distance
			result = id
	return result
