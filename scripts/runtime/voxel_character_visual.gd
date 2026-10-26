@tool
class_name VoxelCharacterVisual
extends Node3D

## Builds and drives the 13-bone blocky "Diablo voxel" humanoid rig.
## All body segments are rigid voxel meshes attached to bones via
## BoneAttachment3D. Equipment slots are additional BoneAttachment3D nodes.
##
## Animations are procedural: a tiny state machine drives bone poses via
## Skeleton3D.set_bone_pose_* every frame (see AGENTS.md learning #6 for why
## we don't use AnimationPlayer bone tracks). States: Idle, Walk, Run, Attack.

signal attack_finished
signal attack_hit_window  ## Emitted once per swing when the cleave connects (frame-perfect hit timing).

const V := VoxelCharacterParts.VOXEL_SIZE

const BONES: Array[StringName] = [
	&"hips", &"chest", &"head",
	&"arm_upper_l", &"arm_lower_l", &"hand_l",
	&"arm_upper_r", &"arm_lower_r", &"hand_r",
	&"leg_upper_l", &"leg_lower_l",
	&"leg_upper_r", &"leg_lower_r",
]

const PARENT: Dictionary = {
	&"hips": -1,
	&"chest": &"hips",
	&"head": &"chest",
	&"arm_upper_l": &"chest",
	&"arm_lower_l": &"arm_upper_l",
	&"hand_l": &"arm_lower_l",
	&"arm_upper_r": &"chest",
	&"arm_lower_r": &"arm_upper_r",
	&"hand_r": &"arm_lower_r",
	&"leg_upper_l": &"hips",
	&"leg_lower_l": &"leg_upper_l",
	&"leg_upper_r": &"hips",
	&"leg_lower_r": &"leg_upper_r",
}

## World-space rest position (pivot) of each bone (1 voxel = 1/16 = 0.0625m).
const REST: Dictionary = {
	&"hips": Vector3(0.0, 0.75, 0.0),
	&"chest": Vector3(0.0, 0.75, 0.0),
	&"head": Vector3(0.0, 1.375, 0.0),
	&"arm_upper_l": Vector3(0.4375, 1.3125, 0.0),
	&"arm_lower_l": Vector3(0.4375, 1.0, 0.0),
	&"hand_l": Vector3(0.4375, 0.75, 0.0),
	&"arm_upper_r": Vector3(-0.4375, 1.3125, 0.0),
	&"arm_lower_r": Vector3(-0.4375, 1.0, 0.0),
	&"hand_r": Vector3(-0.4375, 0.75, 0.0),
	&"leg_upper_l": Vector3(0.1875, 0.75, 0.0),
	&"leg_lower_l": Vector3(0.1875, 0.375, 0.0),
	&"leg_upper_r": Vector3(-0.1875, 0.75, 0.0),
	&"leg_lower_r": Vector3(-0.1875, 0.375, 0.0),
}

## Each entry: bone, body-space min corner (world units), size in voxels, segment id.
const BODY_SEGMENTS: Array[Array] = [
	[&"chest", Vector3(-0.3125, 0.75, -0.1875), Vector3i(10, 10, 6), &"chest"],
	[&"head", Vector3(-0.25, 1.375, -0.25), Vector3i(8, 8, 8), &"head"],
	[&"arm_upper_l", Vector3(0.3125, 1.0, -0.125), Vector3i(4, 5, 4), &"arm_upper_l"],
	[&"arm_lower_l", Vector3(0.3125, 0.6875, -0.125), Vector3i(4, 5, 4), &"arm_lower_l"],
	[&"arm_upper_r", Vector3(-0.5625, 1.0, -0.125), Vector3i(4, 5, 4), &"arm_upper_r"],
	[&"arm_lower_r", Vector3(-0.5625, 0.6875, -0.125), Vector3i(4, 5, 4), &"arm_lower_r"],
	[&"leg_upper_l", Vector3(0.0625, 0.375, -0.125), Vector3i(4, 6, 4), &"leg_upper_l"],
	[&"leg_lower_l", Vector3(0.0625, 0.0, -0.1875), Vector3i(4, 6, 5), &"leg_lower_l"],
	[&"leg_upper_r", Vector3(-0.3125, 0.375, -0.125), Vector3i(4, 6, 4), &"leg_upper_r"],
	[&"leg_lower_r", Vector3(-0.3125, 0.0, -0.1875), Vector3i(4, 6, 5), &"leg_lower_r"],
]

## Equipment slot definitions: attachment name, parent bone, local offset and rotation.
const EQUIP_SLOTS: Dictionary = {
	&"helmet": {&"bone": &"head", &"offset": Vector3(-0.25, 0.0, -0.25), &"rot": Vector3.ZERO},
	&"pauldron_l": {&"bone": &"arm_upper_l", &"offset": Vector3(-0.125, -0.3125, -0.125), &"rot": Vector3.ZERO},
	&"pauldron_r": {&"bone": &"arm_upper_r", &"offset": Vector3(-0.125, -0.3125, -0.125), &"rot": Vector3.ZERO},
	# main_hand: grip the weapon so the blade (its -Z) lies in the swing plane
	# and the edge leads the arc — without this the blade stays perpendicular
	# to the motion the whole swing ("sword doesn't follow the movement").
	&"main_hand": {&"bone": &"hand_r", &"offset": Vector3(-0.0625, -0.0625, -0.0625), &"rot": Vector3(8.0, 20.0, 18.0)},
	&"off_hand": {&"bone": &"hand_l", &"offset": Vector3(0.0, 0.0, 0.0), &"rot": Vector3(-18.0, -20.0, 0.0)},
}

const PRESETS: Array[Dictionary] = [
	{&"name": "Warrior", &"chest": 1, &"helmet": 1, &"main_hand": 1, &"off_hand": 1},
	{&"name": "Barbarian", &"chest": 2, &"helmet": 2, &"main_hand": 2, &"off_hand": 0},
	{&"name": "Cultist", &"chest": 3, &"helmet": 3, &"main_hand": 3, &"off_hand": 3},
	{&"name": "Brigand", &"chest": 4, &"helmet": 0, &"main_hand": 1, &"off_hand": 2},
	{&"name": "Villager", &"chest": 0, &"helmet": 0, &"main_hand": 0, &"off_hand": 0},
]

const SWAP_COUNTS: Dictionary = {&"helmet": 4, &"chest": 5, &"main_hand": 4, &"off_hand": 4}

enum AnimState { IDLE, WALK, RUN, ATTACK }

## Pose blending rates (higher = snappier). Attacks blend in fast so the
## swing stays crisp; idle settles slowly for a natural recovery.
const BLEND_IDLE: float = 8.0
const BLEND_WALK: float = 14.0
const BLEND_RUN: float = 16.0
const BLEND_ATTACK: float = 30.0

var skeleton: Skeleton3D
var bone_idx: Dictionary = {}
var equipment: Dictionary = {}  # slot_name -> Node3D holder
var current: Dictionary = {&"helmet": 0, &"chest": 0, &"main_hand": 0, &"off_hand": 0}
var current_preset: int = -1
var state: AnimState = AnimState.IDLE

## Editor-editable loadout (visible when this @tool rig is placed in a scene,
## e.g. scenes/character/character_editor.tscn). Changing a value in the
## Inspector rebuilds the corresponding part immediately. Defaults match the
## Warrior preset so a freshly dropped rig looks like preset 0.
@export_enum("Warrior", "Barbarian", "Cultist", "Brigand", "Villager") var preset: int = 0:
	set(value):
		preset = value
		if _built and not _syncing_exports:
			apply_preset(value)
@export_range(0, 3) var helmet: int = 1:
	set(value):
		helmet = value
		if _built and not _syncing_exports:
			set_equipment(&"helmet", value)
@export_range(0, 4) var chest: int = 1:
	set(value):
		chest = value
		if _built and not _syncing_exports:
			set_armor_style(value)
@export_range(0, 3) var main_hand: int = 1:
	set(value):
		main_hand = value
		if _built and not _syncing_exports:
			set_equipment(&"main_hand", value)
@export_range(0, 3) var off_hand: int = 1:
	set(value):
		off_hand = value
		if _built and not _syncing_exports:
			set_equipment(&"off_hand", value)
## Optional Voxdot-authored loadout. Paths resolve relative to this resource.
@export var appearance: VoxelModel:
	set(value):
		appearance = value
		if _built:
			apply_model_loadout(value)

## When true, the idle animation plays live in the editor viewport.
@export var animate_in_editor: bool = false

var _built: bool = false
var _syncing_exports: bool = false

var _body_instances: Dictionary = {}  # segment id -> MeshInstance3D
var _time: float = 0.0
var _attack_t: float = -1.0  # <0 = not attacking, else 0..ATTACK_DURATION
const ATTACK_DURATION: float = 0.5
## Cleave phase boundaries of _pose_attack (see below). The hit window opens
## right at the cleave start so damage lands as the weapon sweeps through.
const ATTACK_WINDUP_END: float = 0.22
const ATTACK_CLEAVE_END: float = 0.55
## Fraction through the cleave where the blade crosses the target space
## (ease-in means the sweep is fastest past its midpoint).
const ATTACK_HIT_FRACTION: float = 0.4
var _pose_target: Dictionary = {}  # bone -> Quaternion (this frame's goal)
var _pose_current: Dictionary = {}  # bone -> Quaternion (smoothly applied)
var _hips_bob_target: Vector3 = Vector3.ZERO
var _hips_bob_current: Vector3 = Vector3.ZERO
var _blend_rate: float = BLEND_IDLE


func _ready() -> void:
	_build_skeleton()
	_build_body()
	_build_equipment_slots()
	_built = true
	# Apply the exported loadout. Picking a preset in the Inspector rewrites
	# the slot exports to match, so the saved slot values alone reproduce the
	# exact appearance on load (editor and game).
	current_preset = preset
	set_armor_style(chest)
	set_equipment(&"helmet", helmet)
	set_equipment(&"main_hand", main_hand)
	set_equipment(&"off_hand", off_hand)
	if appearance != null:
		apply_model_loadout(appearance)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() and not animate_in_editor:
		return  # static rest pose while editing unless preview is enabled
	_time += delta
	_pose_target.clear()
	_hips_bob_target = Vector3.ZERO
	if _attack_t >= 0.0:
		var prev_t: float = _attack_t
		_attack_t += delta
		var p := minf(_attack_t / ATTACK_DURATION, 1.0)
		_pose_attack(p)
		# Emit the hit window exactly once per swing, when the blade sweeps
		# through the target space (part-way into the accelerating cleave).
		var hit_p := ATTACK_WINDUP_END + (ATTACK_CLEAVE_END - ATTACK_WINDUP_END) * ATTACK_HIT_FRACTION
		if prev_t / ATTACK_DURATION < hit_p and _attack_t / ATTACK_DURATION >= hit_p:
			attack_hit_window.emit()
		if _attack_t >= ATTACK_DURATION:
			_attack_t = -1.0
			attack_finished.emit()
	else:
		match state:
			AnimState.IDLE:
				_pose_idle()
			AnimState.WALK:
				_pose_locomotion(0.7, 32.0, 0.02, 4.0, BLEND_WALK)
			AnimState.RUN:
				_pose_locomotion(0.45, 48.0, 0.04, 12.0, BLEND_RUN)
	_apply_pose(delta)


func set_anim_state(s: AnimState) -> void:
	state = s


func play_attack() -> void:
	# Start a new swing when idle, or during the recovery phase (last 40%) of
	# the current swing for responsive combos instead of locking full duration.
	if _attack_t < 0.0 or _attack_t >= ATTACK_DURATION * 0.6:
		_attack_t = 0.0


func is_attacking() -> bool:
	return _attack_t >= 0.0


func cancel_attack() -> void:
	if _attack_t >= 0.0:
		_attack_t = -1.0
		attack_finished.emit()


func attack_progress() -> float:
	## Normalized 0..1 progress of the current swing, or 1.0 when idle.
	return clampf(_attack_t / ATTACK_DURATION, 0.0, 1.0) if _attack_t >= 0.0 else 1.0


# --- Rig construction ---

func _build_skeleton() -> void:
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	add_child(skeleton)
	for bone in BONES:
		var p: Variant = PARENT[bone]
		var parent_idx: int = -1 if p is int else bone_idx[p]
		var idx: int = skeleton.add_bone(String(bone))
		bone_idx[bone] = idx
		skeleton.set_bone_parent(idx, parent_idx)
		var world := Transform3D(Basis(), REST[bone])
		var parent_world := Transform3D.IDENTITY if parent_idx == -1 else Transform3D(Basis(), REST[p])
		var local: Transform3D = world if parent_idx == -1 else parent_world.inverse() * world
		skeleton.set_bone_rest(idx, local)
		skeleton.set_bone_pose(idx, local)


func _bone_world_rest(bone: StringName) -> Transform3D:
	var chain: Array[StringName] = []
	var b: Variant = bone
	while b is StringName:
		chain.push_front(b)
		b = PARENT[b]
	var t := Transform3D.IDENTITY
	for c in chain:
		t = t * skeleton.get_bone_rest(bone_idx[c])
	return t


func _build_body() -> void:
	for seg: Array in BODY_SEGMENTS:
		var bone: StringName = seg[0]
		var body_min: Vector3 = seg[1]
		var seg_id: StringName = seg[3]
		var attach := BoneAttachment3D.new()
		attach.name = "Attach_%s" % String(seg_id)
		attach.bone_idx = bone_idx[bone]
		skeleton.add_child(attach)
		var grid: Dictionary = VoxelCharacterParts.segment_grid(seg_id)
		var mi := VoxelMeshBuilder.make_instance(grid, V, "Part_%s" % String(seg_id))
		mi.transform = Transform3D(Basis(), _bone_world_rest(bone).inverse() * Transform3D(Basis(), body_min).origin)
		attach.add_child(mi)
		_body_instances[seg_id] = mi


func _build_equipment_slots() -> void:
	for slot: StringName in EQUIP_SLOTS:
		var def: Dictionary = EQUIP_SLOTS[slot]
		var attach := BoneAttachment3D.new()
		attach.name = "Equip_%s" % String(slot)
		attach.bone_idx = bone_idx[def[&"bone"]]
		skeleton.add_child(attach)
		var holder := Node3D.new()
		holder.name = "Holder"
		holder.position = def[&"offset"]
		holder.rotation_degrees = def[&"rot"]
		attach.add_child(holder)
		equipment[slot] = holder


# --- Equipment & armor ---

var slot_models: Dictionary = {}
var slot_model_paths: Dictionary = {}


## Replace the whole authored loadout; invalid/missing slots revert to procedural.
func apply_model_loadout(model: VoxelModel, source_path: String = "") -> PackedStringArray:
	var errors := PackedStringArray()
	if model != null:
		apply_character_style(model.character_style)
	var base: String = source_path if source_path != "" else (model.resource_path if model != null else "")
	for slot: StringName in [&"helmet", &"chest", &"main_hand", &"off_hand"]:
		set_slot_model(slot, "")
		var path: String = str(model.character_slots.get(str(slot), "")) if model != null else ""
		if path.is_empty():
			continue
		path = VoxelModel.resolve_asset_path(path, base.get_base_dir())
		var error: String = set_slot_model(slot, path)
		if error != "":
			errors.append(error)
	return errors


## Invalid individual assignments preserve the previous valid slot.
func set_slot_model(slot: StringName, path: String) -> String:
	if slot not in [&"helmet", &"chest", &"main_hand", &"off_hand"]:
		return "Unknown character slot: %s" % slot
	path = path.strip_edges()
	if path == "":
		slot_models.erase(slot)
		slot_model_paths.erase(slot)
	else:
		if not FileAccess.file_exists(path):
			return "Character part not found: %s" % path
		var model: VoxelModel = VoxelModel.load_with_prefabs(path)
		if model == null or not model.prefab_instances.is_empty():
			return "Character part must be a VoxelModel without prefabs: %s" % path
		slot_models[slot] = model
		slot_model_paths[slot] = path
	if _built:
		if slot == &"chest":
			set_armor_style(int(current.get(slot, 0)))
		else:
			set_equipment(slot, int(current.get(slot, 0)))
	return ""


func _clear_holder(holder: Node3D) -> void:
	for child: Node in holder.get_children():
		holder.remove_child(child)
		child.queue_free()


func _add_authored_part(holder: Node3D, model: VoxelModel) -> void:
	var part := VoxelModelInstance.new()
	part.name = "AuthoredPart"
	part.model = model
	holder.add_child(part)


func set_equipment(slot: StringName, index: int) -> void:
	if not equipment.has(slot):
		return
	current[slot] = index
	if slot == &"pauldron_l" or slot == &"pauldron_r":
		return
	var holder: Node3D = equipment[slot]
	_clear_holder(holder)
	var custom: VoxelModel = slot_models.get(slot) as VoxelModel
	if slot == &"helmet":
		# Keep procedural overlays merged to avoid coplanar faces. Authored
		# helmets use the documented head-local holder and a bare head.
		var head_grid: Dictionary = VoxelCharacterParts.segment_grid(&"head", int(current[&"chest"]), index if custom == null else 0)
		(_body_instances[&"head"] as MeshInstance3D).mesh = VoxelMeshBuilder.build_mesh(head_grid, V)
		if custom != null:
			_add_authored_part(holder, custom)
		return
	if custom != null:
		_add_authored_part(holder, custom)
		return
	var grid: Dictionary = VoxelCharacterParts.equipment_grid(slot, index)
	if not grid.is_empty():
		holder.add_child(VoxelMeshBuilder.make_instance(grid, VoxelCharacterParts.EQUIP_VOXEL_SIZE, "Mesh"))


func set_armor_style(style: int) -> void:
	_rebuild_chest_style(style)
	set_equipment(&"pauldron_l", 1 if style == 1 else (4 if style == 4 else 0))
	set_equipment(&"pauldron_r", 1 if style == 1 else (4 if style == 4 else 0))
	current[&"chest"] = style


func _rebuild_chest_style(style: int) -> void:
	for seg: StringName in [&"chest", &"arm_upper_l", &"arm_upper_r", &"arm_lower_l", &"arm_lower_r", &"leg_upper_l", &"leg_upper_r", &"leg_lower_l", &"leg_lower_r"]:
		var grid: Dictionary = VoxelCharacterParts.segment_grid(seg, style)
		var body: MeshInstance3D = _body_instances[seg]
		if seg == &"chest":
			_clear_holder(body)
			var custom: VoxelModel = slot_models.get(&"chest") as VoxelModel
			if custom != null:
				body.mesh = null
				_add_authored_part(body, custom)
				continue
		body.mesh = VoxelMeshBuilder.build_mesh(grid, V)


func apply_preset(preset_index: int) -> Dictionary:
	var p: Dictionary = PRESETS[preset_index % PRESETS.size()]
	current_preset = preset_index % PRESETS.size()
	set_armor_style(p[&"chest"])
	set_equipment(&"helmet", p[&"helmet"])
	set_equipment(&"main_hand", p[&"main_hand"])
	set_equipment(&"off_hand", p[&"off_hand"])
	# Reflect the preset into the Inspector slot properties (flagged so the
	# property setters don't trigger a redundant second rebuild).
	_syncing_exports = true
	preset = current_preset
	helmet = int(p[&"helmet"])
	chest = int(p[&"chest"])
	main_hand = int(p[&"main_hand"])
	off_hand = int(p[&"off_hand"])
	_syncing_exports = false
	return p


func cycle(slot: StringName) -> int:
	var count: int = SWAP_COUNTS[slot]
	if slot == &"chest":
		current[&"chest"] = (int(current[&"chest"]) + 1) % count
		set_armor_style(current[&"chest"])
	else:
		set_equipment(slot, (int(current[slot]) + 1) % count)
	return int(current[slot])


# --- Procedural pose helpers ---
# Pose functions only *declare* target rotations via _rot()/_bob(); the actual
# skeleton poses are written once per frame by _apply_pose(), which smoothly
# blends from the previous frame. This gives free, natural transitions
# between any two states (attack -> walk, run -> idle, ...).

func _rot(bone: StringName, euler_deg: Vector3) -> void:
	_pose_target[bone] = Quaternion.from_euler(Vector3(
		deg_to_rad(euler_deg.x), deg_to_rad(euler_deg.y), deg_to_rad(euler_deg.z)))


func _bob(offset: Vector3) -> void:
	_hips_bob_target = offset


func _apply_pose(delta: float) -> void:
	# Exponential smoothing, frame-rate independent.
	var weight: float = 1.0 - exp(-_blend_rate * delta)
	for bone in BONES:
		var target: Quaternion = _pose_target.get(bone, Quaternion.IDENTITY)
		var current_q: Quaternion = _pose_current.get(bone, Quaternion.IDENTITY)
		current_q = current_q.slerp(target, weight)
		_pose_current[bone] = current_q
		skeleton.set_bone_pose_rotation(bone_idx[bone], current_q)
	_hips_bob_current = _hips_bob_current.lerp(_hips_bob_target, weight)
	skeleton.set_bone_pose_position(bone_idx[&"hips"], REST[&"hips"] + _hips_bob_current)


func _pose_legs(cycle_len: float, stride: float) -> void:
	# Lower-body poses shared by locomotion and attack-with-movement, so the
	# character keeps walking/running while swinging (upper/lower body split).
	var phase := fmod(_time, cycle_len) / cycle_len  # 0..1
	var swing := sin(phase * TAU)
	var swing_b := sin(phase * TAU + PI)  # opposite side
	_rot(&"leg_upper_l", Vector3(stride * swing, 0, 0))
	_rot(&"leg_upper_r", Vector3(stride * swing_b, 0, 0))
	# Knees bend backward (+Z, which is negative X rotation for a downward -Y limb).
	_rot(&"leg_lower_l", Vector3(-stride * 0.65 * maxf(-swing, 0.0) - stride * 0.2 * maxf(swing, 0.0), 0, 0))
	_rot(&"leg_lower_r", Vector3(-stride * 0.65 * maxf(-swing_b, 0.0) - stride * 0.2 * maxf(swing_b, 0.0), 0, 0))


func _pose_idle() -> void:
	_blend_rate = BLEND_IDLE
	var t := _time
	var breathe := sin(t * TAU / 2.4)
	_rot(&"chest", Vector3(-1.5 * breathe, 0, 0))
	_rot(&"arm_upper_l", Vector3(8.0 + 2.0 * breathe, 0, 4.0 + 1.5 * breathe))
	_rot(&"arm_lower_l", Vector3(18.0, 0, 0))
	_rot(&"arm_upper_r", Vector3(12.0 + 2.0 * breathe, 0, -4.0 - 1.5 * breathe))
	_rot(&"arm_lower_r", Vector3(22.0, 0, 0))
	var look := sin(t * TAU / 3.5)
	_rot(&"head", Vector3(0, 6.0 * look, 0))


func _pose_locomotion(cycle_len: float, stride: float, bob: float, lean: float, blend_rate: float) -> void:
	_blend_rate = blend_rate
	var phase := fmod(_time, cycle_len) / cycle_len  # 0..1
	var swing := sin(phase * TAU)
	_pose_legs(cycle_len, stride)
	_rot(&"arm_upper_l", Vector3(-stride * 0.8 * swing, 0, -6.0))
	_rot(&"arm_upper_r", Vector3(stride * 0.8 * swing, 0, 6.0))
	_bob(Vector3(0, bob * sin(phase * TAU * 2.0), 0))
	# Chest extends upward (+Y), so negative X rotation leans forward toward -Z.
	_rot(&"chest", Vector3(-lean, 6.0 * swing * (stride / 48.0), 0))


func _ease_out_cubic(k: float) -> float:
	return 1.0 - pow(1.0 - k, 3.0)


func _ease_in_cubic(k: float) -> float:
	return k * k * k


func _pose_attack(p: float) -> void:
	# Lower body keeps doing whatever locomotion was active (upper/lower body
	# split), so attacking while moving never freezes the legs mid-stride.
	match state:
		AnimState.WALK:
			_pose_legs(0.7, 32.0)
		AnimState.RUN:
			_pose_legs(0.45, 48.0)
		_:
			_pose_legs(0.7, 8.0)
	# Three-phase diagonal cleave (classic ARPG overhead slash):
	#   windup  0 .. ATTACK_WINDUP_END        coil — sword rises up and out to
	#         the right while the torso winds away; the head counter-rotates so
	#         the eyes stay locked on the target. Ease-out = settle into the
	#         raised pose with anticipation.
	#   cleave  ATTACK_WINDUP_END .. ATTACK_CLEAVE_END   uncoil — accelerating
	#         diagonal sweep down and across the body with full follow-through
	#         (the arm ends past vertical, blade rolled diagonal). Hips dip and
	#         rotate into the strike for weight transfer. Ease-in = smash.
	#   recover ATTACK_CLEAVE_END .. 1        ease back toward the idle carry
	#         pose rather than a hard zero, so the exit into idle/walk blends
	#         seamlessly.
	# Bone conventions: the arm hangs along -Y, so +X pitch raises the limb
	# forward (-Z) and overhead (+Y); +Y yaw swings it horizontally (negative
	# yaw = out to the character's right); +Z roll tips the blade diagonally.
	if p < ATTACK_WINDUP_END:
		var k := _ease_out_cubic(p / ATTACK_WINDUP_END)
		_blend_rate = 24.0  # snap into the coil, still readable
		# Raise to shoulder height and out to the right (not fully overhead),
		# so the blade's lever arm stays short and it leads instead of trailing.
		_rot(&"arm_upper_r", Vector3(lerpf(12.0, 118.0, k), lerpf(-4.0, -26.0, k), lerpf(6.0, 20.0, k)))
		_rot(&"arm_lower_r", Vector3(lerpf(4.0, 14.0, k), 0.0, 0.0))
		# Wrist cocks the blade back behind the arm — at the peak the tip
		# points up and slightly behind, ready to be whipped forward.
		_rot(&"hand_r", Vector3(lerpf(0.0, -32.0, k), lerpf(0.0, -10.0, k), lerpf(0.0, 20.0, k)))
		_rot(&"chest", Vector3(lerpf(0.0, -6.0, k), lerpf(0.0, -32.0, k), lerpf(0.0, 4.0, k)))
		_rot(&"hips", Vector3(0.0, lerpf(0.0, -8.0, k), 0.0))
		_rot(&"head", Vector3(0.0, lerpf(0.0, 20.0, k), 0.0))
		_rot(&"arm_upper_l", Vector3(lerpf(8.0, 38.0, k), lerpf(0.0, 14.0, k), lerpf(4.0, -8.0, k)))
		_bob(Vector3(0.0, lerpf(0.0, 0.03, k), 0.0))
	elif p < ATTACK_CLEAVE_END:
		var k := _ease_in_cubic((p - ATTACK_WINDUP_END) / (ATTACK_CLEAVE_END - ATTACK_WINDUP_END))
		_blend_rate = 50.0  # cleave must stay crisp — fast uncoil, no smear
		# Fast diagonal chop: from raised-right down across the body to the
		# lower left, with real follow-through past vertical.
		_rot(&"arm_upper_r", Vector3(lerpf(118.0, -6.0, k), lerpf(-26.0, 36.0, k), lerpf(20.0, -18.0, k)))
		_rot(&"arm_lower_r", Vector3(lerpf(14.0, 8.0, k), 0.0, 0.0))
		# Wrist snaps forward through the cut so the blade tips lead the arc
		# (edge-first) rather than dragging behind it.
		_rot(&"hand_r", Vector3(lerpf(-32.0, 10.0, k), lerpf(-10.0, 22.0, k), lerpf(20.0, -26.0, k)))
		_rot(&"chest", Vector3(lerpf(-6.0, 12.0, k), lerpf(-32.0, 26.0, k), lerpf(4.0, -3.0, k)))
		_rot(&"hips", Vector3(0.0, lerpf(-8.0, 12.0, k), 0.0))
		_rot(&"head", Vector3(0.0, lerpf(20.0, -10.0, k), 0.0))
		_rot(&"arm_upper_l", Vector3(lerpf(38.0, 14.0, k), lerpf(14.0, -6.0, k), lerpf(-8.0, -16.0, k)))
		_bob(Vector3(0.0, lerpf(0.03, -0.05, k), 0.0))
	else:
		var k := _ease_out_cubic((p - ATTACK_CLEAVE_END) / (1.0 - ATTACK_CLEAVE_END))
		_blend_rate = 12.0  # settle gently toward the carry pose
		_rot(&"arm_upper_r", Vector3(lerpf(-6.0, 12.0, k), lerpf(36.0, -4.0, k), lerpf(-18.0, 6.0, k)))
		_rot(&"arm_lower_r", Vector3(lerpf(8.0, 4.0, k), 0.0, 0.0))
		_rot(&"hand_r", Vector3(lerpf(10.0, 0.0, k), lerpf(22.0, 0.0, k), lerpf(-26.0, 0.0, k)))
		_rot(&"chest", Vector3(lerpf(12.0, 0.0, k), lerpf(26.0, 0.0, k), lerpf(-3.0, 0.0, k)))
		_rot(&"hips", Vector3(0.0, lerpf(12.0, 0.0, k), 0.0))
		_rot(&"head", Vector3(0.0, lerpf(-10.0, 0.0, k), 0.0))
		_rot(&"arm_upper_l", Vector3(lerpf(14.0, 8.0, k), lerpf(-6.0, 0.0, k), lerpf(-16.0, 4.0, k)))
		_bob(Vector3(0.0, lerpf(-0.05, 0.0, k), 0.0))


func character_style() -> Dictionary:
	var result: Dictionary = {}
	for slot: StringName in [&"helmet", &"chest", &"main_hand", &"off_hand"]:
		result[str(slot)] = int(current[slot])
	result["preset"] = current_preset
	return result


func apply_character_style(style: Dictionary) -> void:
	if style.has("preset"):
		apply_preset(clampi(int(style["preset"]), 0, PRESETS.size() - 1))
	for slot: StringName in [&"chest", &"helmet", &"main_hand", &"off_hand"]:
		if not style.has(str(slot)):
			continue
		var index: int = clampi(int(style[str(slot)]), 0, int(SWAP_COUNTS[slot]) - 1)
		if slot == &"chest":
			set_armor_style(index)
		else:
			set_equipment(slot, index)
