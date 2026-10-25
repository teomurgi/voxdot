class_name VoxelMaterial
extends RefCounted

## Built-in voxel material presets. The numeric IDs are stored per voxel and
## must stay stable across releases. A voxel can override the preset's solid or
## walkable flag; see `make_overrides`.
##
## Walkability is a material capability. The editor/runtime derive actual
## walkable surfaces from solid + walkable cells whose cell above is not solid.

enum Kind { DEFAULT, STONE, DIRT, GRASS, WOOD, LEAVES, WATER, GLASS, METAL }

enum Override { INHERIT = 0, ON = 1, OFF = 2 }

const SOLID_SHIFT: int = 0
const WALKABLE_SHIFT: int = 2
const OVERRIDE_MASK: int = 0b11

static var _defs: Array[Dictionary] = [
	{
		"id": "default", "name": "Default", "color": Color("c2c7d1"),
		"solid": true, "walkable": true, "tags": PackedStringArray(["generic"]),
	},
	{
		"id": "stone", "name": "Stone", "color": Color("8c8f96"),
		"solid": true, "walkable": true, "tags": PackedStringArray(["stone", "mineral"]),
	},
	{
		"id": "dirt", "name": "Dirt", "color": Color("8a5a33"),
		"solid": true, "walkable": true, "tags": PackedStringArray(["soil"]),
	},
	{
		"id": "grass", "name": "Grass", "color": Color("5f8a3a"),
		"solid": true, "walkable": true, "tags": PackedStringArray(["soil", "foliage"]),
	},
	{
		"id": "wood", "name": "Wood", "color": Color("8b5a2b"),
		"solid": true, "walkable": true, "tags": PackedStringArray(["wood", "organic"]),
	},
	{
		"id": "leaves", "name": "Leaves", "color": Color("417a35"),
		"solid": true, "walkable": false, "tags": PackedStringArray(["foliage", "organic"]),
	},
	{
		"id": "water", "name": "Water", "color": Color("3f7fbf"),
		"solid": false, "walkable": false, "tags": PackedStringArray(["liquid"]),
	},
	{
		"id": "glass", "name": "Glass", "color": Color("9fd8e8"),
		"solid": true, "walkable": true, "tags": PackedStringArray(["glass"]),
	},
	{
		"id": "metal", "name": "Metal", "color": Color("9aa4ad"),
		"solid": true, "walkable": true, "tags": PackedStringArray(["metal", "mineral"]),
	},
]


static func count() -> int:
	return _defs.size()


static func info(kind: int) -> Dictionary:
	if kind < 0 or kind >= _defs.size():
		return _defs[0]
	return _defs[kind]


static func display_name(kind: int) -> String:
	return str(info(kind).get("name", "Default"))


static func id(kind: int) -> String:
	return str(info(kind).get("id", "default"))


static func color(kind: int) -> Color:
	return info(kind).get("color", Color("c2c7d1"))


static func tags(kind: int) -> PackedStringArray:
	var value: Variant = info(kind).get("tags", PackedStringArray())
	return value if value is PackedStringArray else PackedStringArray()


static func base_solid(kind: int) -> bool:
	return bool(info(kind).get("solid", true))


static func base_walkable(kind: int) -> bool:
	return bool(info(kind).get("walkable", true))


static func try_kind_from_id(value: String) -> int:
	var key: String = value.strip_edges().to_lower()
	for i in _defs.size():
		if str(_defs[i].get("id", "")) == key or str(_defs[i].get("name", "")).to_lower() == key:
			return i
	return -1


static func is_known_id(value: String) -> bool:
	return try_kind_from_id(value) >= 0


static func is_valid_kind(kind: int) -> bool:
	return kind >= 0 and kind < _defs.size()


static func kind_from_id(value: String) -> int:
	var found: int = try_kind_from_id(value)
	return found if found >= 0 else Kind.DEFAULT


static func solid_override(bits: int) -> int:
	return bits & OVERRIDE_MASK


static func walkable_override(bits: int) -> int:
	return (bits >> WALKABLE_SHIFT) & OVERRIDE_MASK


static func make_overrides(solid: int, walkable: int) -> int:
	return ((solid & OVERRIDE_MASK) << SOLID_SHIFT) \
			| ((walkable & OVERRIDE_MASK) << WALKABLE_SHIFT)


static func is_solid(kind: int, overrides: int) -> bool:
	var o: int = solid_override(overrides)
	if o == Override.ON:
		return true
	if o == Override.OFF:
		return false
	return base_solid(kind)


static func is_walkable(kind: int, overrides: int) -> bool:
	var o: int = walkable_override(overrides)
	if o == Override.ON:
		return true
	if o == Override.OFF:
		return false
	return base_walkable(kind)
