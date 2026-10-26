class_name VoxelPrefabCatalog
extends RefCounted

## Scans the user and project prefab libraries, validates sources, and keeps
## per-asset metadata (stable asset ID, pivot, cached bounds/counts) in
## `<library>/.voxdot/catalogue.cfg`.
##
## The catalogue is UI-free and headless-testable. It never embeds source
## geometry and never writes into the library except for the small manifest.
## Thumbnails live under `user://prefab_thumbs/`.

const MANIFEST_VERSION: int = 1
const MANIFEST_DIR: String = ".voxdot"
const MANIFEST_FILE: String = "catalogue.cfg"
const THUMB_DIR: String = "user://prefab_thumbs"
const SKIP_DIRS: Array[String] = [".godot", ".import"]

var project_dir: String = ""
## Test hook: when set, replaces the OS Documents-based user library so tests
## never touch the real `~/Documents/voxdot/Prefabs`.
var user_library_override: String = ""

var _assets: Array[Dictionary] = []
var _by_id: Dictionary = {}
var _by_path: Dictionary = {}
var _manifests: Dictionary = {} # library_dir -> { relative_path: entry }
var _libraries: Array[Dictionary] = []


func user_library() -> String:
	if user_library_override != "":
		return user_library_override
	var docs: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs == "":
		docs = OS.get_user_data_dir()
	return docs.path_join("voxdot").path_join("Prefabs")


func project_library(open_model_dir: String = "") -> String:
	var base: String = open_model_dir if open_model_dir != "" else project_dir
	if base == "":
		return ""
	return base.path_join("Prefabs")


func libraries(open_model_dir: String = "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var user: String = user_library().simplify_path()
	out.append({"kind": "user", "dir": user})
	var p: String = project_library(open_model_dir)
	if p != "" and p.simplify_path() != user:
		out.append({"kind": "project", "dir": p})
	return out


## Rebuilds the asset list. `open_model_dir` is the directory of the open
## model; when empty, only the user library is scanned. Project library paths
## are remembered for later placement/save-copy calls.
func scan(open_model_dir: String = "") -> Dictionary:
	project_dir = open_model_dir
	_assets.clear()
	_by_id.clear()
	_by_path.clear()
	_manifests.clear()
	_libraries = libraries(open_model_dir)
	for lib: Dictionary in _libraries:
		var dir: String = lib["dir"]
		var kind: String = lib["kind"]
		var manifest: Dictionary = _load_manifest(dir)
		_manifests[dir] = manifest
		_scan_dir(dir, dir, kind, manifest)
		_write_manifest(dir, manifest)
	_sort_assets()
	return summary()


func summary() -> Dictionary:
	var valid: int = 0
	for a: Dictionary in _assets:
		if bool(a.get("valid", false)):
			valid += 1
	return {
		"assets": _assets.size(),
		"valid": valid,
		"invalid": _assets.size() - valid,
		"libraries": _libraries.duplicate(true),
	}


func assets() -> Array[Dictionary]:
	return _assets


func asset_count() -> int:
	return _assets.size()


func asset(asset_id: String) -> Dictionary:
	return _by_id.get(asset_id, {})


func asset_at(path: String) -> Dictionary:
	return _by_path.get(path.simplify_path(), {})


## Loads (and caches) the source resource for an asset. Returns null when the
## asset is unknown or unreadable.
func load_asset(asset_id: String) -> VoxelModel:
	var a: Dictionary = asset(asset_id)
	if a.is_empty():
		return null
	if a.get("model") != null:
		return a["model"] as VoxelModel
	var res: Resource = _load_resource(a["path"])
	if res is VoxelModel:
		a["model"] = res
		return res as VoxelModel
	return null


## Re-reads one asset from disk, preserving its ID and pivot. Returns the
## updated asset (or {} when the file is gone).
func refresh_asset(asset_id: String) -> Dictionary:
	var a: Dictionary = asset(asset_id)
	if a.is_empty():
		return {}
	var path: String = a["path"]
	if not _path_exists(path):
		a["valid"] = false
		a["reason"] = "source file is missing"
		a["model"] = null
		return a
	var manifest: Dictionary = _manifests.get(a["library_dir"], {})
	var entry: Dictionary = manifest.get(a["relative_path"], {})
	var res: Resource = _load_resource(path)
	_fill_from_model(a, res, entry)
	entry = _entry_for(a)
	manifest[a["relative_path"]] = entry
	_manifests[a["library_dir"]] = manifest
	_write_manifest(a["library_dir"], manifest)
	return a


func set_pivot(asset_id: String, pivot: Vector3) -> Dictionary:
	var a: Dictionary = asset(asset_id)
	if a.is_empty():
		return {}
	if not VoxelPrefabInstance.pivot_is_valid(pivot):
		a["pivot_error"] = "pivot must be a multiple of 0.5"
		return a
	var p: Vector3 = VoxelPrefabInstance.snap_pivot(pivot)
	if absf(p.x) > VoxelDocument.MAX_BOUND or absf(p.y) > VoxelDocument.MAX_BOUND \
			or absf(p.z) > VoxelDocument.MAX_BOUND:
		a["pivot_error"] = "pivot is outside the valid range"
		return a
	a.erase("pivot_error")
	a["pivot"] = p
	var manifest: Dictionary = _manifests.get(a["library_dir"], {})
	var entry: Dictionary = manifest.get(a["relative_path"], {})
	entry["id"] = a["asset_id"]
	entry["pivot"] = p
	manifest[a["relative_path"]] = entry
	_manifests[a["library_dir"]] = manifest
	_write_manifest(a["library_dir"], manifest)
	return a


func reset_pivot(asset_id: String) -> Dictionary:
	var model: VoxelModel = load_asset(asset_id)
	if model == null:
		return {}
	return set_pivot(asset_id, default_pivot(model))


## Bottom-center pivot in source cell space. Uses the occupied cell AABB, or
## the light positions for light-only assets.
static func default_pivot(model: VoxelModel) -> Vector3:
	if model == null:
		return Vector3.ZERO
	var grid: Dictionary = model.to_grid()
	if not grid.is_empty():
		var lo := Vector3i(2147483647, 2147483647, 2147483647)
		var hi := Vector3i(-2147483648, -2147483648, -2147483648)
		for p: Vector3i in grid:
			lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
			hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
		return VoxelPrefabInstance.snap_pivot(Vector3(
			(lo.x + hi.x + 1) * 0.5, lo.y, (lo.z + hi.z + 1) * 0.5))
	var packed: PackedFloat32Array = model.lights
	if packed.is_empty():
		return Vector3.ZERO
	var min_p := Vector3(INF, INF, INF)
	var max_p := Vector3(-INF, -INF, -INF)
	for i in range(0, packed.size() - VoxelModel.LIGHT_STRIDE + 1, VoxelModel.LIGHT_STRIDE):
		var p := Vector3(packed[i + 1], packed[i + 2], packed[i + 3])
		min_p = min_p.min(p)
		max_p = max_p.max(p)
	return VoxelPrefabInstance.snap_pivot(Vector3(
		(min_p.x + max_p.x) * 0.5, min_p.y, (min_p.z + max_p.z) * 0.5))


## Cache key includes source mtime and pivot so pivot edits invalidate it.
func thumbnail_path(a: Dictionary) -> String:
	if a.is_empty():
		return ""
	var key: String = "%s|%s|%s" % [a.get("asset_id", ""), a.get("mtime", 0), a.get("pivot", Vector3.ZERO)]
	return THUMB_DIR.path_join(key.sha256_text() + ".png")


func invalidate_thumbnail(a: Dictionary) -> void:
	if a.is_empty():
		return
	var p: String = thumbnail_path(a)
	if FileAccess.file_exists(ProjectSettings.globalize_path(p)) or FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


## Finds an asset by its stable ID across the currently scanned libraries.
## Used by relink when only the asset ID survived.
func find_by_asset_id(asset_id: String) -> Dictionary:
	return asset(asset_id)


func write_manifests() -> void:
	for dir: String in _manifests:
		_write_manifest(dir, _manifests[dir])


func manifest_for(library_dir: String) -> Dictionary:
	return _manifests.get(library_dir, {})


func library_dir_for(kind: String, open_model_dir: String = "") -> String:
	if kind == "project":
		return project_library(open_model_dir)
	return user_library()


# --- Internals ---

func _scan_dir(root: String, dir: String, kind: String, manifest: Dictionary) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = false
	var dirs: Array = []
	var files: Array = []
	for sub: String in d.get_directories():
		if sub.begins_with(".") or sub in SKIP_DIRS:
			continue
		dirs.append(sub)
	for f: String in d.get_files():
		if f.begins_with("."):
			continue
		var ext: String = f.get_extension().to_lower()
		if ext == "tres" or ext == "res":
			files.append(f)
	dirs.sort()
	files.sort()
	for f: String in files:
		_scan_file(root, dir.path_join(f), kind, manifest)
	for sub: String in dirs:
		_scan_dir(root, dir.path_join(sub), kind, manifest)


func _scan_file(root: String, path: String, kind: String, manifest: Dictionary) -> void:
	var abs_path: String = path.simplify_path()
	var rel: String = _relative_to(root, abs_path)
	var mtime: int = FileAccess.get_modified_time(abs_path)
	var size: int = _file_size(abs_path)
	var entry: Dictionary = manifest.get(rel, {})
	var cached: bool = not entry.is_empty() \
			and int(entry.get("mtime", -1)) == mtime \
			and int(entry.get("size", -1)) == size \
			and entry.has("cells") and entry.has("lights") \
			and entry.has("bounds") and entry.has("valid")
	var a: Dictionary = {
		"asset_id": str(entry.get("id", "")),
		"name": abs_path.get_file().get_basename(),
		"file": abs_path.get_file(),
		"path": abs_path,
		"relative_path": rel,
		"folder": rel.get_base_dir(),
		"library": kind,
		"library_dir": root,
		"mtime": mtime,
		"size": size,
		"pivot": entry.get("pivot", Vector3.ZERO),
		"model": null,
		"valid": false,
		"reason": "",
		"has_prefabs": false,
		"bounds": Vector3i.ZERO,
		"cells": 0,
		"lights": 0,
	}
	if a["asset_id"] == "":
		a["asset_id"] = _new_asset_id(kind, rel)
	if cached:
		a["valid"] = bool(entry.get("valid", false))
		a["reason"] = str(entry.get("reason", ""))
		a["has_prefabs"] = bool(entry.get("has_prefabs", false))
		a["bounds"] = entry.get("bounds", Vector3i.ZERO)
		a["cells"] = int(entry.get("cells", 0))
		a["lights"] = int(entry.get("lights", 0))
		if not VoxelPrefabInstance.pivot_is_valid(a["pivot"]):
			a["pivot"] = VoxelPrefabInstance.snap_pivot(a["pivot"])
	else:
		var res: Resource = _load_resource(abs_path)
		_fill_from_model(a, res, entry)
	# The manifest is refreshed on scan; the file itself is only loaded when
	# the metadata cache is stale (lazy for 500-asset libraries).
	manifest[rel] = _entry_for(a)
	_register(a)


func _fill_from_model(a: Dictionary, res: Resource, entry: Dictionary) -> void:
	a["model"] = null
	a["valid"] = false
	a["reason"] = ""
	a["has_prefabs"] = false
	a["bounds"] = Vector3i.ZERO
	a["cells"] = 0
	a["lights"] = 0
	if not (res is VoxelModel):
		a["reason"] = "not a VoxelModel resource"
		return
	var m: VoxelModel = res as VoxelModel
	a["model"] = m
	a["has_prefabs"] = not m.prefab_instances.is_empty()
	a["bounds"] = m.bounds
	a["cells"] = m.voxel_count()
	a["lights"] = m.lights.size() / VoxelModel.LIGHT_STRIDE
	if m.voxel_size <= 0.0:
		a["reason"] = "voxel_size must be positive"
		return
	if not m.prefab_instances.is_empty():
		a["reason"] = "contains prefab instances"
		return
	if m.voxel_count() == 0 and m.lights.is_empty():
		a["reason"] = "source is empty"
		return
	var bad: Vector3i = _first_out_of_bounds_cell(m)
	if bad != Vector3i(-1, -1, -1):
		a["reason"] = "cell (%d, %d, %d) is outside source bounds" % [bad.x, bad.y, bad.z]
		return
	var pivot: Vector3 = entry["pivot"] if entry.has("pivot") else default_pivot(m)
	if not VoxelPrefabInstance.pivot_is_valid(pivot) \
			or absf(pivot.x) > VoxelDocument.MAX_BOUND \
			or absf(pivot.y) > VoxelDocument.MAX_BOUND \
			or absf(pivot.z) > VoxelDocument.MAX_BOUND:
		pivot = default_pivot(m)
	a["pivot"] = pivot
	a["valid"] = true


static func _first_out_of_bounds_cell(m: VoxelModel) -> Vector3i:
	var grid: Dictionary = m.to_grid()
	for p: Vector3i in grid:
		if p.x < 0 or p.y < 0 or p.z < 0 \
				or p.x >= m.bounds.x or p.y >= m.bounds.y or p.z >= m.bounds.z:
			return p
	return Vector3i(-1, -1, -1)


func _entry_for(a: Dictionary) -> Dictionary:
	return {
		"id": a["asset_id"],
		"pivot": a["pivot"],
		"mtime": a["mtime"],
		"size": a["size"],
		"bounds": a["bounds"],
		"cells": a["cells"],
		"lights": a["lights"],
		"has_prefabs": a["has_prefabs"],
		"valid": a["valid"],
		"reason": a["reason"],
	}


func _register(a: Dictionary) -> void:
	_assets.append(a)
	_by_id[a["asset_id"]] = a
	_by_path[a["path"]] = a


func _sort_assets() -> void:
	_assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var an: String = str(a.get("name", "")).to_lower()
		var bn: String = str(b.get("name", "")).to_lower()
		if an == bn:
			return str(a.get("relative_path", "")) < str(b.get("relative_path", ""))
		return an < bn)


func _new_asset_id(kind: String, rel: String) -> String:
	var prefix: String = "usr" if kind == "user" else "prj"
	var salt: String = "%s|%s|%s|%s" % [Time.get_unix_time_from_system(), Time.get_ticks_usec(),
		randi(), rel]
	return "%s_%s" % [prefix, salt.sha256_text().substr(0, 12)]


func _load_resource(path: String) -> Resource:
	# Catalogue sources are arbitrary files; a broken dependency must not abort
	# the scan. There is no getter for this flag, so restore the default.
	ResourceLoader.set_abort_on_missing_resources(false)
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	ResourceLoader.set_abort_on_missing_resources(true)
	return res


func _load_manifest(root: String) -> Dictionary:
	var out: Dictionary = {}
	var path: String = root.path_join(MANIFEST_DIR).path_join(MANIFEST_FILE)
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return out
	if not cfg.has_section("assets"):
		return out
	for key: String in cfg.get_section_keys("assets"):
		var value: Variant = cfg.get_value("assets", key)
		if value is Dictionary:
			out[key] = value
	return out


func _write_manifest(root: String, manifest: Dictionary) -> void:
	var dir: String = root.path_join(MANIFEST_DIR)
	if not DirAccess.dir_exists_absolute(dir):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			return
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "version", MANIFEST_VERSION)
	var keys: Array = manifest.keys()
	keys.sort()
	for rel: String in keys:
		cfg.set_value("assets", rel, manifest[rel])
	var err: Error = cfg.save(dir.path_join(MANIFEST_FILE))
	if err != OK:
		push_warning("Could not write prefab catalogue manifest: " + dir.path_join(MANIFEST_FILE))


func _file_size(path: String) -> int:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n: int = f.get_length()
	f.close()
	return n


static func _relative_to(root: String, path: String) -> String:
	var r: String = root.simplify_path().trim_suffix("/") + "/"
	var p: String = path.simplify_path()
	if p.begins_with(r):
		return p.substr(r.length())
	return p.get_file()


static func _path_exists(p: String) -> bool:
	if p.begins_with("res://") or p.begins_with("user://"):
		return ResourceLoader.exists(p)
	return FileAccess.file_exists(p)
