class_name VoxelCharacterParts
extends RefCounted

## Static library of every swappable voxel part and body segment.
## Parts are defined as voxel grids (Dictionary of { Vector3i: Color }),
## in local voxel units (VOXEL_SIZE = 1/16 world unit = 0.0625m).

const VOXEL_SIZE: float = 1.0 / 16.0
const EQUIP_VOXEL_SIZE: float = 1.0 / 16.0

# --- Palette ---
const C_SKIN := Color("e0a872")
const C_SKIN_DARK := Color("c48852")
const C_HAIR := Color("4a3222")
const C_EYE_WHITE := Color("f0efe8")
const C_EYE_PUPIL := Color("1f2430")
const C_TUNIC := Color("6e5239")
const C_TUNIC_DARK := Color("4e3927")
const C_PANTS := Color("3b3a4f")
const C_PANTS_DARK := Color("2c2b3c")
const C_BOOTS := Color("36281e")
const C_BOOTS_LIGHT := Color("4d392b")
const C_LEATHER := Color("78512d")
const C_LEATHER_DARK := Color("54381e")
const C_IRON := Color("9498a1")
const C_IRON_DARK := Color("686b75")
const C_IRON_LIGHT := Color("c2c7d1")
const C_WOOD := Color("8a5a2e")
const C_WOOD_DARK := Color("633e1d")
const C_BLADE := Color("cdd4de")
const C_BLADE_EDGE := Color("f2f6fa")
const C_GOLD := Color("dfb134")
const C_GOLD_DARK := Color("a87e1a")
const C_HORN := Color("e3d6bc")
const C_HORN_TIP := Color("b8a686")
const C_HOOD := Color("3f4559")
const C_HOOD_DARK := Color("2b3040")
const C_HOOD_TRIM := Color("9e2a2b")
const C_BRIGAND := Color("2f313d")
const C_BRIGAND_LIGHT := Color("434657")
const C_STUD := Color("b8bcc7")
const C_SHIELD := Color("7a4f2b")
const C_SHIELD_RED := Color("8f2d2d")
const C_SHIELD_TRIM := Color("a6abb5")
const C_HAMMER_HEAD := Color("757885")
const C_RUNE := Color("45e3eb")
const C_TORCH := Color("eb7d22")
const C_EMBER := Color("ffcf40")


# --- Body segment grids (local voxels, origin at bottom-min corner) ---

static func segment_grid(segment: StringName, style: int = 0, helmet: int = 0) -> Dictionary:
	match segment:
		&"head":
			var g := _build_head(helmet)
			VoxelMeshBuilder.merge(g, _equip_helmet(helmet))
			return g
		&"chest":
			return _build_chest(style)
		&"arm_upper_l":
			var g := _build_arm_upper(style)
			VoxelMeshBuilder.merge(g, _equip_pauldron(1 if style == 1 else (4 if style == 4 else 0), true))
			return g
		&"arm_upper_r":
			var g := _build_arm_upper(style)
			VoxelMeshBuilder.merge(g, _equip_pauldron(1 if style == 1 else (4 if style == 4 else 0), false))
			return g
		&"arm_lower_l", &"arm_lower_r":
			return _build_arm_lower(style)
		&"leg_upper_l", &"leg_upper_r":
			return _build_leg_upper(style)
		&"leg_lower_l", &"leg_lower_r":
			return _build_leg_lower(style)
	push_error("VoxelCharacterParts: unknown segment %s" % segment)
	return {}


static func _build_head(helmet: int = 0) -> Dictionary:
	# 8x8x8 head block; front face is -Z (z = 0).
	var g := VoxelMeshBuilder.box(Vector3i(0, 0, 0), Vector3i(8, 7, 8), C_SKIN)
	# Chin / lower jaw shading
	VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(8, 1, 8), C_SKIN_DARK)
	VoxelMeshBuilder.fill_box(g, Vector3i(1, 0, 0), Vector3i(6, 1, 2), C_SKIN)
	# Eyes on -Z face (y = 2..3, z = 0)
	VoxelMeshBuilder.fill_box(g, Vector3i(1, 2, 0), Vector3i(1, 2, 1), C_EYE_WHITE)
	VoxelMeshBuilder.fill_box(g, Vector3i(2, 2, 0), Vector3i(1, 2, 1), C_EYE_PUPIL)
	VoxelMeshBuilder.fill_box(g, Vector3i(5, 2, 0), Vector3i(1, 2, 1), C_EYE_PUPIL)
	VoxelMeshBuilder.fill_box(g, Vector3i(6, 2, 0), Vector3i(1, 2, 1), C_EYE_WHITE)
	# Eyebrows (y = 4, z = 0)
	VoxelMeshBuilder.fill_box(g, Vector3i(1, 4, 0), Vector3i(2, 1, 1), C_HAIR)
	VoxelMeshBuilder.fill_box(g, Vector3i(5, 4, 0), Vector3i(2, 1, 1), C_HAIR)
	# Nose bridge
	VoxelMeshBuilder.fill_box(g, Vector3i(3, 1, 0), Vector3i(2, 2, 1), C_SKIN_DARK)
	if helmet == 0:
		# Full hair cap when bare-headed
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 6, 0), Vector3i(8, 2, 8), C_HAIR)
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, 0), Vector3i(8, 1, 2), C_HAIR)
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, 6), Vector3i(8, 6, 2), C_HAIR)
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 3, 1), Vector3i(1, 4, 6), C_HAIR)
		VoxelMeshBuilder.fill_box(g, Vector3i(7, 3, 1), Vector3i(1, 4, 6), C_HAIR)
	return g


static func _build_chest(armor: int) -> Dictionary:
	# 10x10x6 torso (x: 0..9, y: 0..9, z: 0..5). Front is -Z (z = 0).
	var g: Dictionary = {}
	match armor:
		0: # Villager tunic + leather belt
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 10, 6), C_TUNIC)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 2, 6), C_TUNIC_DARK)
			# Collar V-neck on front (-Z)
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 8, 0), Vector3i(4, 2, 2), C_SKIN_DARK)
			# Leather belt + gold buckle at y = 2
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(10, 2, 6), C_LEATHER_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(4, 2, 0), Vector3i(2, 2, 1), C_GOLD)
		1: # Warrior steel plate cuirass
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 10, 6), C_IRON)
			# Bright breastplate chest highlights
			VoxelMeshBuilder.fill_box(g, Vector3i(1, 5, 0), Vector3i(8, 4, 6), C_IRON_LIGHT)
			# Center sternum ridge & collar trim
			VoxelMeshBuilder.fill_box(g, Vector3i(4, 4, 0), Vector3i(2, 5, 1), C_GOLD)
			VoxelMeshBuilder.fill_box(g, Vector3i(2, 9, 0), Vector3i(6, 1, 6), C_GOLD_DARK)
			# Dark iron waist faulds & leather belt
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 2, 6), C_IRON_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(10, 2, 6), C_LEATHER_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(4, 2, 0), Vector3i(2, 2, 1), C_GOLD)
		2: # Barbarian bare chest + crossed leather harness + fur belt
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 10, 6), C_SKIN)
			# Pectoral / ab shading
			VoxelMeshBuilder.fill_box(g, Vector3i(4, 3, 0), Vector3i(2, 6, 1), C_SKIN_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(1, 5, 0), Vector3i(8, 1, 1), C_SKIN_DARK)
			# Crossed leather chest straps
			VoxelMeshBuilder.fill_box(g, Vector3i(1, 3, 0), Vector3i(2, 7, 6), C_LEATHER)
			VoxelMeshBuilder.fill_box(g, Vector3i(7, 3, 0), Vector3i(2, 7, 6), C_LEATHER)
			# Heavy studded war-belt
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 3, 6), C_LEATHER_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 1, 0), Vector3i(4, 2, 1), C_HORN)
		3: # Cultist dark robe + crimson stole
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 10, 6), C_HOOD)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 2, 6), C_HOOD_DARK)
			# Crimson front tabard / stole + gold sash
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 0, 0), Vector3i(4, 10, 1), C_HOOD_TRIM)
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 0, 5), Vector3i(4, 10, 1), C_HOOD_TRIM)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 3, 0), Vector3i(10, 1, 6), C_GOLD_DARK)
		4: # Brigand studded leather coat
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(10, 10, 6), C_BRIGAND)
			VoxelMeshBuilder.fill_box(g, Vector3i(1, 3, 0), Vector3i(8, 6, 1), C_BRIGAND_LIGHT)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(10, 2, 6), C_LEATHER_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(4, 2, 0), Vector3i(2, 2, 1), C_STUD)
			for sx in [2, 5, 7]:
				for sy in [4, 6, 8]:
					VoxelMeshBuilder.fill_box(g, Vector3i(sx, sy, 0), Vector3i(1, 1, 1), C_STUD)
					VoxelMeshBuilder.fill_box(g, Vector3i(sx, sy, 5), Vector3i(1, 1, 1), C_STUD)
	return g


static func _build_arm_upper(armor: int) -> Dictionary:
	# 4x5x4 upper arm
	var g: Dictionary = {}
	match armor:
		0:
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 5, 4), C_SKIN)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(4, 3, 4), C_TUNIC)
		1:
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 5, 4), C_IRON_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(4, 3, 4), C_IRON)
		2:
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 5, 4), C_SKIN)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 3, 0), Vector3i(4, 1, 4), C_LEATHER)
		3:
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 5, 4), C_HOOD)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 1, 4), C_HOOD_TRIM)
		4:
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 5, 4), C_BRIGAND)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 3, 0), Vector3i(4, 2, 4), C_LEATHER_DARK)
	return g


static func _build_arm_lower(armor: int) -> Dictionary:
	# 4x5x4 forearm + hand (hand at bottom y = 0..1, bracer at y = 2..4)
	var g := VoxelMeshBuilder.box(Vector3i(0, 0, 0), Vector3i(4, 5, 4), C_SKIN)
	match armor:
		0:
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(4, 1, 4), C_LEATHER)
		1: # steel gauntlets
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, 0), Vector3i(4, 4, 4), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 4, 0), Vector3i(4, 1, 4), C_GOLD_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 1, 4), C_IRON_DARK)
		2: # leather wrist wraps
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(4, 3, 4), C_LEATHER_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 4, 0), Vector3i(4, 1, 4), C_HORN)
		3: # robe cuffs
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(4, 3, 4), C_HOOD_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(4, 1, 4), C_GOLD_DARK)
		4: # brigand leather bracers
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(4, 3, 4), C_LEATHER_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, 0), Vector3i(4, 1, 4), C_BRIGAND)
	return g


static func _build_leg_upper(armor: int = 0) -> Dictionary:
	# 4x6x4 thigh
	var g := VoxelMeshBuilder.box(Vector3i(0, 0, 0), Vector3i(4, 6, 4), C_PANTS)
	if armor == 1:
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, 0), Vector3i(4, 5, 4), C_IRON_DARK)
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 4, 0), Vector3i(4, 2, 4), C_IRON)
	elif armor == 2:
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 5, 4), C_SKIN_DARK)
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 4, 0), Vector3i(4, 2, 4), C_LEATHER_DARK)
	elif armor == 3:
		VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 6, 4), C_HOOD_DARK)
	return g


static func _build_leg_lower(armor: int = 0) -> Dictionary:
	# 4x6x5 shin + boot (z = 0 is the forward -Z boot toe, z = 1..4 aligns with upper leg)
	var g := VoxelMeshBuilder.box(Vector3i(0, 3, 1), Vector3i(4, 3, 4), C_PANTS_DARK)
	# Boot shaft (y = 0..3, z = 1..4) + forward toe cap (y = 0..1, z = 0)
	var boot_col: Color = C_IRON if armor == 1 else C_BOOTS
	var trim_col: Color = C_IRON_LIGHT if armor == 1 else C_BOOTS_LIGHT
	VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 1), Vector3i(4, 3, 4), boot_col)
	VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(4, 2, 1), boot_col)
	VoxelMeshBuilder.fill_box(g, Vector3i(0, 3, 1), Vector3i(4, 1, 4), trim_col)
	return g


# --- Equipment attachment grids (local voxels, EQUIP_VOXEL_SIZE = 1/16) ---

static func equipment_grid(slot: StringName, index: int) -> Dictionary:
	match slot:
		&"helmet":
			return _equip_helmet(index)
		&"pauldron_l":
			return _equip_pauldron(index, true)
		&"pauldron_r":
			return _equip_pauldron(index, false)
		&"main_hand":
			return _equip_main_hand(index)
		&"off_hand":
			return _equip_off_hand(index)
	push_error("VoxelCharacterParts: unknown equipment slot %s" % slot)
	return {}


static func _equip_helmet(index: int) -> Dictionary:
	# Coordinates match _build_head (head occupies 0..7 in X, 0..7 in Y, 0..7 in Z; -Z is front).
	# Keep helmets sleek (wrapping y=4..7 + accents) so the character's eyes & face stay visible!
	match index:
		0: # none
			return {}
		1: # Knight Crowned Warhelm with gold brow & red plume (open face so eyes are visible)
			var g: Dictionary = {}
			# Steel helm dome over top of head (x: 0..7, y: 5..8, z: 0..7)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, 0), Vector3i(8, 3, 8), C_IRON_LIGHT)
			VoxelMeshBuilder.fill_box(g, Vector3i(1, 8, 1), Vector3i(6, 1, 6), C_IRON_LIGHT)
			# Cheek guards & back neck guard (leaving front x:1..6, y:1..4 open for eyes/face)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, 5), Vector3i(8, 4, 3), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 0), Vector3i(1, 3, 5), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(7, 2, 0), Vector3i(1, 3, 5), C_IRON)
			# Gold brow band & crest ridge
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, -1), Vector3i(8, 1, 1), C_GOLD)
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 5, -1), Vector3i(2, 3, 1), C_GOLD)
			# Red knight crest plume on top
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 9, 1), Vector3i(2, 2, 6), C_SHIELD_RED)
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 7, 7), Vector3i(2, 3, 2), C_SHIELD_RED)
			return g
		2: # Horned Barbarian Helm (open face + sweeping horns)
			var g: Dictionary = {}
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, 0), Vector3i(8, 3, 8), C_IRON_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, -1), Vector3i(8, 1, 1), C_LEATHER)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, 5), Vector3i(8, 3, 3), C_LEATHER_DARK)
			# Curved horns extending out (+X / -X) and up (+Y)
			VoxelMeshBuilder.fill_box(g, Vector3i(-2, 6, 2), Vector3i(2, 2, 3), C_HORN)
			VoxelMeshBuilder.fill_box(g, Vector3i(-3, 7, 2), Vector3i(2, 3, 2), C_HORN)
			VoxelMeshBuilder.fill_box(g, Vector3i(-3, 10, 1), Vector3i(1, 2, 2), C_HORN_TIP)
			VoxelMeshBuilder.fill_box(g, Vector3i(8, 6, 2), Vector3i(2, 2, 3), C_HORN)
			VoxelMeshBuilder.fill_box(g, Vector3i(9, 7, 2), Vector3i(2, 3, 2), C_HORN)
			VoxelMeshBuilder.fill_box(g, Vector3i(10, 10, 1), Vector3i(1, 2, 2), C_HORN_TIP)
			return g
		3: # Cultist Hooded Cowl (draped hood framing the eyes)
			var g: Dictionary = {}
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, 0), Vector3i(8, 3, 8), C_HOOD)
			VoxelMeshBuilder.fill_box(g, Vector3i(1, 8, 1), Vector3i(6, 1, 6), C_HOOD)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, 4), Vector3i(8, 4, 4), C_HOOD_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 1, 0), Vector3i(1, 4, 4), C_HOOD_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(7, 1, 0), Vector3i(1, 4, 4), C_HOOD_DARK)
			# Crimson & gold brow trim
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, -1), Vector3i(8, 1, 1), C_HOOD_TRIM)
			VoxelMeshBuilder.fill_box(g, Vector3i(3, 6, -1), Vector3i(2, 2, 1), C_GOLD)
			return g
	return {}


static func _equip_pauldron(index: int, is_left: bool) -> Dictionary:
	# Coordinates match arm_upper (0..3 in X, 0..4 in Y, 0..3 in Z).
	if index == 1:
		var x0: int = 0 if is_left else -1
		var g := VoxelMeshBuilder.box(Vector3i(x0, 2, -1), Vector3i(5, 3, 6), C_IRON)
		VoxelMeshBuilder.fill_box(g, Vector3i(x0, 5, 0), Vector3i(5, 1, 4), C_IRON_LIGHT)
		var edge_x: int = 4 if is_left else -1
		VoxelMeshBuilder.fill_box(g, Vector3i(edge_x, 2, -1), Vector3i(1, 3, 6), C_GOLD)
		return g
	elif index == 4:
		var x0: int = 0 if is_left else -1
		var g := VoxelMeshBuilder.box(Vector3i(x0, 3, -1), Vector3i(5, 2, 6), C_LEATHER_DARK)
		VoxelMeshBuilder.fill_box(g, Vector3i(1, 5, 1), Vector3i(2, 1, 2), C_STUD)
		return g
	return {}


static func _equip_main_hand(index: int) -> Dictionary:
	# Grip centered at z = 0..3 (inside fist); weapon extends forward along -Z (z < 0).
	match index:
		0: # unarmed
			return {}
		1: # Broadsword (blade extends forward along -Z)
			var g: Dictionary = {}
			# Gold pommel (+Z, behind fist) & leather grip (z = 0..3)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 3), Vector3i(2, 2, 2), C_GOLD)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, -1), Vector3i(2, 2, 4), C_LEATHER_DARK)
			# Gold crossguard at z = -2 (in front of knuckles, quillions along Y)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -3, -2), Vector3i(2, 8, 2), C_GOLD)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -4, -3), Vector3i(2, 1, 1), C_GOLD_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 5, -3), Vector3i(2, 1, 1), C_GOLD_DARK)
			# Steel blade extending forward along -Z (z = -3 .. -18)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -1, -16), Vector3i(1, 4, 14), C_BLADE_EDGE)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, -15), Vector3i(1, 2, 13), C_BLADE)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, -18), Vector3i(1, 2, 2), C_BLADE_EDGE)
			return g
		2: # Battle Axe (haft extends forward along -Z, crescent blade on front)
			var g: Dictionary = {}
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, -14), Vector3i(2, 2, 18), C_WOOD)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 4), Vector3i(2, 2, 1), C_IRON_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 0), Vector3i(2, 2, 3), C_LEATHER_DARK)
			# Crescent axe head at z = -13..-9 (vertical blade in Y)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -4, -13), Vector3i(2, 4, 5), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -6, -14), Vector3i(1, 2, 7), C_BLADE_EDGE)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 2, -12), Vector3i(2, 2, 3), C_IRON_DARK)
			return g
		3: # Runed Warhammer
			var g: Dictionary = {}
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, -13), Vector3i(2, 2, 17), C_WOOD_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 0, 4), Vector3i(2, 2, 1), C_GOLD_DARK)
			# Heavy warhammer block head at z = -13..-9
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, -4, -13), Vector3i(4, 10, 5), C_HAMMER_HEAD)
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, -5, -12), Vector3i(4, 1, 3), C_IRON_LIGHT)
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, 6, -12), Vector3i(4, 1, 3), C_IRON_LIGHT)
			# Glowing cyan runes on the sides
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, -2, -11), Vector3i(1, 6, 1), C_RUNE)
			VoxelMeshBuilder.fill_box(g, Vector3i(2, -2, -11), Vector3i(1, 6, 1), C_RUNE)
			return g
	return {}


static func _equip_off_hand(index: int) -> Dictionary:
	# Attached to left hand (+X side of character); shields face forward (-Z) at z = -3.
	match index:
		0: # none
			return {}
		1: # Kite Shield (tapered heater shield in XY plane facing -Z forward)
			var g: Dictionary = {}
			# Main shield body (x = -3..4, y = -5..4, z = -3)
			VoxelMeshBuilder.fill_box(g, Vector3i(-3, -1, -3), Vector3i(8, 6, 1), C_SHIELD_RED)
			VoxelMeshBuilder.fill_box(g, Vector3i(-2, -3, -3), Vector3i(6, 2, 1), C_SHIELD_RED)
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, -5, -3), Vector3i(4, 2, 1), C_SHIELD_RED)
			# Steel rim
			VoxelMeshBuilder.fill_box(g, Vector3i(-3, 4, -3), Vector3i(8, 1, 1), C_SHIELD_TRIM)
			VoxelMeshBuilder.fill_box(g, Vector3i(-3, -1, -3), Vector3i(1, 6, 1), C_SHIELD_TRIM)
			VoxelMeshBuilder.fill_box(g, Vector3i(4, -1, -3), Vector3i(1, 6, 1), C_SHIELD_TRIM)
			# Gold cross emblem on front face (z = -4)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -3, -4), Vector3i(2, 7, 1), C_GOLD)
			VoxelMeshBuilder.fill_box(g, Vector3i(-2, 0, -4), Vector3i(6, 2, 1), C_GOLD)
			return g
		2: # Round Buckler (in XY plane facing -Z forward)
			var g: Dictionary = {}
			VoxelMeshBuilder.fill_box(g, Vector3i(-2, -2, -3), Vector3i(6, 5, 1), C_SHIELD)
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, -3, -3), Vector3i(4, 7, 1), C_SHIELD)
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, 3, -3), Vector3i(4, 1, 1), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, -3, -3), Vector3i(4, 1, 1), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(-2, -1, -3), Vector3i(1, 3, 1), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(3, -1, -3), Vector3i(1, 3, 1), C_IRON)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -1, -4), Vector3i(2, 3, 1), C_GOLD)
			return g
		3: # Burning Torch (held forward and upward in -Z / +Y)
			var g: Dictionary = {}
			VoxelMeshBuilder.fill_box(g, Vector3i(0, -2, -2), Vector3i(2, 8, 2), C_WOOD_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(-1, 5, -3), Vector3i(4, 1, 4), C_IRON_DARK)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 6, -2), Vector3i(2, 3, 2), C_TORCH)
			VoxelMeshBuilder.fill_box(g, Vector3i(0, 9, -2), Vector3i(2, 2, 2), C_EMBER)
			return g
	return {}
