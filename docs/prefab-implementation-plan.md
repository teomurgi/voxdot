# Voxdot Prefab System — Implementation Plan

Status: **proposed, not implemented.**
Target: Voxdot on Godot 4.7.2, Linux/macOS/Windows standalone build.

Goal: reuse saved Voxdot models inside other models by choosing them from a visual catalogue.
Placements are **linked, atomic instances**: they keep a source reference and a transform, and
source edits propagate on reopen or an explicit reload. An instance can be **unpacked** into
ordinary voxels and point lights when local edits are needed.

This plan records the decisions made during the design review. It describes the hard cases
(missing files, source edits, overlap, undo, game runtime) before the UI polish.

---

## 1. V1 decisions

| Topic | Decision |
|---|---|
| Reuse semantics | **Linked instances.** A placement stores a source reference plus a transform. Source edits propagate on reopen or manual reload. |
| Portability | **External dependencies.** No embedded copy of source geometry. Copying the parent alone intentionally produces missing placeholders. |
| Editing a placement | **Atomic instance + unpack.** Move/rotate/duplicate/delete the whole instance. `Unpack` converts it to ordinary editable voxels and lights. |
| Transforms | **Integer-cell translation + 90° yaw only.** No arbitrary rotation, fractional scale, or mirror in v1. |
| Pivot | **Saved custom pivot per catalogue asset**, snapshotted into each placement so later pivot edits do not move existing instances. |
| Nesting | **Not allowed.** A model containing prefab instances cannot itself be a prefab source in v1. |
| Reused content | **Voxels + point lights.** Source sun, palette, bounds, editor settings, and voxel size are not reused. The parent owns the scene sun and physical scale. |
| Overlap | **Forbidden** between valid instances, and between an instance and local voxels. Placement/move/rotate are all-or-nothing. |
| Conflicts after refresh | **Conflicted placeholder.** Affected instances are marked conflicted, omit their solid mesh/lights, show a red wireframe, and keep their reference for move/relink/delete. |
| Missing sources | **Placeholder + relink.** Keep the reference and placement, show a wireframe/error placeholder, and preserve unresolved instances when saving. |
| Catalogue UX | **Visual asset browser**: search, folders, rendered thumbnails, details, large interactive preview, numeric pivot fields, and viewport pivot picking. |
| Catalogue admission | **Every valid `.tres`/`.res` VoxelModel in a library is reusable.** No explicit publish step. |
| Libraries | Global user library `~/Documents/Voxdot/Prefabs` plus project library `<open model folder>/Prefabs`. |
| Source refresh | Load fresh on open; explicit **Reload prefabs** while open. No filesystem watcher. |
| Lighting | Source point lights are instance-owned and transformed. Soft configurable budget with explicit override; never silently dropped. |
| Out-of-bounds | Refuse the whole placement/move. Never clip or auto-grow bounds. |
| Unpack | Voxels and lights atomically. Refuse if the parent 32-light limit would be exceeded. One undo step. |
| Ordinary tools | Build on prefab surfaces into empty adjacent cells. Paint/Erase/Fill refuse linked cells with an “unpack to edit” message. Pick may sample a color. |
| Scale target | ~500 small/medium instances, ~1M composed cells total, ~500 catalogue assets with lazy thumbnails. |

---

## 2. Non-goals for v1

These are deliberately excluded. They are not “later polish”; each would change the data model or
the editing semantics.

- Arbitrary/free rotation, mirroring, non-uniform or fractional scaling.
- Nested prefabs (a prefab containing prefab instances).
- Embedded source geometry, self-contained parent files, or automatic flatten-on-save.
- Per-voxel overrides on a linked instance (paint/erase one cell while keeping the link).
- Automatic filesystem watching / live reload.
- Source revision pinning or versioned instances. V1 always uses the current source.
- Asset tags, collections, favorites, or multi-user library sync.
- Custom prefab materials; prefabs use the existing vertex-color voxel material.
- Background/threaded mesh generation or prefab streaming.
- A runtime relinking UI. Runtime either resolves the dependency or warns.
- Undoable source refresh. Refresh is a view/data reload, not a document edit.

---

## 3. Glossary

- **Source** — the `.tres`/`.res` `VoxelModel` file that is reused.
- **Prefab asset** — a catalogue entry pointing at a source, with a stable asset ID and a pivot.
- **Instance** — one placement of a prefab asset in a parent document. Atomic for editing.
- **Parent** — the model document containing instances.
- **Composition** — the derived spatial view of the parent: local voxels plus the cells and lights
  of every valid instance. Used for meshing, picking, overlap checks, bounds, and unpacking.
- **Unpack** — replace one instance with ordinary parent voxels and parent point lights.
- **Missing** — the source file cannot be resolved.
- **Conflicted** — the source resolves, but its current geometry cannot be composed without
  violating overlap/bounds. The instance is retained but omitted from the solid composition.
- **Incompatible** — the source resolves but is not a legal prefab source (for example, it
  contains prefab instances).

---

## 4. Architecture overview

```
VoxelModel (.tres)
  ├─ local cells / palette / lights / sun
  └─ prefab_instances: Array[VoxelPrefabInstance]
        ├─ source: VoxelModel        (native external resource reference)
        ├─ source_path: String       (parent-relative fallback)
        ├─ asset_id: String          (stable catalogue identity / relink hint)
        ├─ pivot: Vector3            (snapshot, source cell space)
        ├─ anchor: Vector3i          (parent cell)
        └─ yaw_quarters: int         (0..3)

VoxelDocument
  ├─ grid / lights / sun / undo
  ├─ prefab_instances
  ├─ VoxelPrefabComposition       (transforms, chunk index, overlap, conflicts)
  └─ prefab source cache / status

VoxelModelEditor
  ├─ composed raycast + hover
  ├─ chunk renderer (local + instance cells)
  ├─ Prefab tool / selection / ghost
  └─ VoxelPrefabCatalogDialog

VoxelPrefabCatalog
  ├─ library scan (user + project)
  ├─ .voxdot/catalogue.cfg manifest
  ├─ asset IDs / pivots / metadata cache
  └─ thumbnail cache in user://

VoxelModelInstance (runtime)
  └─ composed mesh + lights + optional collision
```

The data layer stays UI-free. `VoxelDocument` and `VoxelPrefabComposition` are testable headlessly.
The catalogue is a separate layer so the editor can open/close it without owning library state.

---

## 5. File map

New files:

- `scripts/editor/voxel_prefab_instance.gd` — `VoxelPrefabInstance` Resource.
- `scripts/editor/voxel_prefab_composition.gd` — `VoxelPrefabComposition` RefCounted:
  transforms, spatial index, validation, conflict state.
- `scripts/editor/voxel_prefab_catalog.gd` — `VoxelPrefabCatalog` RefCounted:
  libraries, scanning, manifest, IDs, pivots, thumbnails metadata.
- `scripts/editor/voxel_prefab_catalog_dialog.gd` — `VoxelPrefabCatalogDialog` Window:
  browser, preview, pivot editor, problems tab, placement request.
- `scripts/editor/voxel_prefab_rig.gd` — `VoxelPrefabRig` Node3D:
  placement ghost, selection outline, drag feedback, pivot marker helpers, and the editor-side
  group of transformed instance point lights.

Modified files:

- `scripts/editor/voxel_model.gd` — `prefab_instances`, light budget, composed build helpers.
- `scripts/editor/voxel_document.gd` — instance list, place/move/rotate/duplicate/delete/unpack/
  relink/refresh, undo namespace, bounds, save/load.
- `scripts/editor/voxel_model_editor.gd` — Prefab tool, composed raycast, chunk composition,
  selection/ghost, shortcuts, status, panel section, catalogue wiring.
- `scripts/editor/voxel_raycast.gd` — composed cast variant.
- `scripts/editor/mcp_server.gd` — catalogue/instance tools and state.
- `scripts/runtime/voxel_model_instance.gd` — composed mesh/lights/collision.
- `tests/voxel_document_test.gd`, `tests/voxel_editor_test.gd`,
  `tests/voxel_editor_input_test.gd`, `tests/mcp_server_test.gd`.
- `README.md`, `AGENTS.md`, `tools/make_screenshots.gd`.

`VoxelModel` must remain at `res://scripts/editor/voxel_model.gd` with `class_name VoxelModel`.
New scripts keep their generated `.gd.uid` files in git.

---

## 6. Resource format

### 6.1 `VoxelPrefabInstance`

`scripts/editor/voxel_prefab_instance.gd`:

```gdscript
class_name VoxelPrefabInstance
extends Resource

@export var instance_id: int = 0
@export var asset_id: String = ""
@export var source: VoxelModel = null          # native external reference
@export var source_path: String = ""            # parent-relative fallback
@export var source_uid: String = ""             # optional uid:// hint
@export var source_bounds: AABB = AABB()        # occupied AABB snapshot (placeholder)
@export var pivot: Vector3 = Vector3.ZERO       # source cell space, multiples of 0.5
@export var anchor: Vector3i = Vector3i.ZERO    # parent cell
@export var yaw_quarters: int = 0               # 0..3
```

Rules:

- `instance_id` is unique within the parent document and stable across saves. It is the selection
  key and the undo key. Never reuse an ID within a document; allocate `max(existing) + 1`.
- `source` is the native Godot external reference. This is what makes the parent a real Godot
  dependency and what the runtime composes.
- `source_path` is a **fallback locator**, stored relative to the parent file's directory when
  possible. It is not a replacement for `source`.
- `source_uid` is an optional hint captured from `ResourceUID` when available. It must never be the
  only locator: standalone runtime saving does not perform the editor's full UID bookkeeping.
- `source_bounds` is a snapshot of the source's **occupied cell AABB** at placement/relink time,
  in source cell space. For light-only assets, use the light-position AABB. It is only used to
  draw a correctly positioned/sized placeholder when the source is missing. It is **not** embedded
  geometry. Do not use the source's editable `bounds` for this: a large empty volume would draw a
  huge placeholder, and a stray light should not inflate the box when the asset has cells.
- `pivot` is in source cell space and is constrained to multiples of `0.5`. This guarantees that
  90° yaw maps cell centers to cell centers without gaps or overlaps. The catalogue UI and MCP
  validation both snap/refuse other values.
- `anchor` is the parent cell whose minimum corner coincides with the transformed pivot. See §8.
- `yaw_quarters` is normalized modulo 4 on load and on every edit.

Do **not** store transformed cell arrays in the resource. They are derived and cached by
`VoxelPrefabComposition`. This keeps `.tres` files small and makes source refresh cheap.

### 6.2 `VoxelModel` changes

Add to `voxel_model.gd`:

```gdscript
@export var prefab_instances: Array[VoxelPrefabInstance] = []
@export var prefab_light_budget: int = 64  # soft editor budget, saved with the parent
```

- `prefab_instances` defaults to empty. Old files load unchanged.
- `prefab_light_budget` is a soft warning threshold, not a hard cap. It is saved with the model so
  a project can choose its own comfort level. It is not undoable (like sun settings and mirror
  flags).
- Typed-array serialization must be verified in the Phase 0 spike. If Godot 4.7.2 does not
  round-trip `Array[VoxelPrefabInstance]` cleanly, fall back to
  `@export var prefab_instances: Array[Resource] = []` and validate each element at load. Keep the
  public API typed as `Array[VoxelPrefabInstance]` where practical.

`to_model()` in `VoxelDocument` must copy instances with a `copy_for_save()` helper that copies
scalar fields and assigns `source` by reference. Do not deep-duplicate `source`: that would copy
geometry and can break external references.

`to_model()` also copies `prefab_light_budget`.

### 6.3 Example parent `.tres`

```text
[gd_resource type="Resource" script_class="VoxelModel" format=3]

[ext_resource type="Script" path="res://scripts/editor/voxel_model.gd" id="1_model"]
[ext_resource type="Resource" path="Prefabs/tree.tres" id="2_tree"]
[ext_resource type="Script" path="res://scripts/editor/voxel_prefab_instance.gd" id="3_inst"]

[sub_resource type="Resource" id="VoxelPrefabInstance_1"]
script = ExtResource("3_inst")
instance_id = 1
asset_id = "prj_4f2a9c1d7e30"
source = ExtResource("2_tree")
source_path = "Prefabs/tree.tres"
source_bounds = AABB(0, 0, 0, 8, 12, 8)
pivot = Vector3(4, 0, 4)
anchor = Vector3i(10, 0, 6)
yaw_quarters = 1

[resource]
script = ExtResource("1_model")
bounds = Vector3i(64, 64, 64)
prefab_instances = Array[Resource]([SubResource("VoxelPrefabInstance_1")])
prefab_light_budget = 64
```

The exact typed-array spelling depends on the spike. The important properties are:

- `source` is an `ExtResource`, not a path string.
- The path is relative to the parent file when possible (`FLAG_RELATIVE_PATHS`).
- `source_path` remains readable even if the `ExtResource` is dropped on a missing-source save.

### 6.4 Save flags

`VoxelDocument.save_file()` changes from:

```gdscript
ResourceSaver.save(to_model(), target)
```

to:

```gdscript
ResourceSaver.save(to_model(), target, ResourceSaver.FLAG_RELATIVE_PATHS)
```

Phase 0 must verify this for **absolute paths outside `res://`**, which is Voxdot's normal case.
If relative external paths do not work there:

- Save the native reference with an absolute path.
- Keep `source_path` relative for relinking.
- Accept that moving the parent/source together requires a relink pass.
- Document the limitation; do not silently lose the instance.

### 6.5 Save As and unsaved parents

Relative paths need a parent directory.

- If `doc.path == ""` (unsaved parent), store `source_path` as an absolute path and keep the native
  `source` reference. The document is not yet portable.
- On the first successful `Save As`, recompute every `source_path` relative to the new parent
  directory and save again (or compute before the save). This is path bookkeeping, not a content
  edit; do not mark the document dirty for it.
- On a later `Save As` to another folder, recompute `source_path` the same way. The native
  `ExtResource` paths are rewritten by `FLAG_RELATIVE_PATHS`; the fallback must follow.
- Implement a small `relative_path(from_dir: String, to_path: String) -> String` helper. Godot's
  `String` API does not provide a reliable general-purpose relative-path helper across all
  platforms. Split on `/`, find the common prefix, prepend `../` for each remaining `from_dir`
  component, then append the rest. Test Windows drive letters and paths outside the project.
- If a relative path would cross a drive/root boundary, store the absolute path and log a
  portability warning in the status bar.

### 6.6 Loading with missing dependencies

`VoxelDocument.load_file()` must tolerate a missing external source. Godot aborts resource loading
on missing sub-resources by default. Use the scoped pattern:

```gdscript
# Godot 4.7 has no getter for this setting; the engine default is true.
ResourceLoader.set_abort_on_missing_resources(false)
var res := ResourceLoader.load(source, "", ResourceLoader.CACHE_MODE_IGNORE)
ResourceLoader.set_abort_on_missing_resources(true)
```

Voxdot does not change this setting anywhere else, so restoring the documented default is safe.
If a future feature needs a non-default value, add a small helper that tracks the previous value
in a constant/global instead of assuming the default.

Verify in Phase 0 that:

1. The parent still loads as a `VoxelModel`.
2. `prefab_instances` survive with `source == null`.
3. `source_path` and `asset_id` survive.
4. Saving the parent again preserves the unresolved instance.

If Godot drops the whole `ExtResource` line or the instance, the fallback is to keep a separate
plain-data `prefab_records` array in `VoxelModel` and hydrate it after load. Do not choose that
fallback until the spike proves it is necessary.

---

## 7. Catalogue and asset identity

### 7.1 Libraries

- **User library:** `<Documents>/Voxdot/Prefabs`. This is the same parent directory Voxdot already
  uses for models (`OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)` + `Voxdot`). Create it on demand.
- **Project library:** `<directory of the open model>/Prefabs`. Only available when the open model
  has a path. If the model is unsaved, only the user library is scanned.
- Both libraries are scanned recursively. Skip hidden directories, `.godot`, `.import`, and any
  directory named `.voxdot` except for reading its manifest.
- A source may live in either library. The catalogue displays a `User` / `Project` badge.
- Relinking may point outside the libraries, but the asset then shows as `External` and is not
  part of the normal scan. Placement in v1 is catalogue-only; use `Save a copy to library` if you
  want an external model to appear in the catalogue.

### 7.2 Manifest

Each library gets a small metadata file:

```text
<library>/.voxdot/catalogue.cfg
```

Use Godot's `ConfigFile` format so it is human-readable and round-trips `Vector3`/`Vector3i`.

```ini
[meta]
version=1

[assets]

"props/lamp.tres"={
"id": "prj_4f2a9c1d7e30",
"pivot": Vector3(0.5, 0, 0.5),
"mtime": 1760000000,
"size": 12345,
"bounds": Vector3i(4, 8, 4),
"cells": 42,
"lights": 2,
"has_prefabs": false
}
```

- The manifest stores **catalogue metadata**, not source content.
- `pivot` is materialized when an asset is first catalogued, so it is stable even if the source
  later grows. Default: occupied bottom-center (or light AABB for light-only assets). A “Reset to
  bottom-center” button recomputes it.
- `mtime`/`size`/`bounds`/`cells`/`lights`/`has_prefabs` are a metadata cache. If the file's
  current `mtime`/`size` differ, reload it and refresh the entry.
- Thumbnail files live under `user://prefab_thumbs/`, never in the library. The library stays
  clean and can be read-only.
- If the manifest is missing or unreadable, scan the library and build an in-memory index. Persist
  a new manifest when the user places an asset, edits a pivot, or presses “Refresh” (one write per
  scan at most). A failed manifest write must not block catalogue use.

### 7.3 Asset IDs

- Format: `<usr|prj>_<12+ lowercase hex>`, for example `usr_9b1e0c7a4d22`.
- New IDs are random (or derived from a hash of the canonical relative path plus a random salt) and
  written to the manifest.
- If an asset has no manifest entry yet, use a deterministic temporary ID
  `local_<sha256(relative_path).substr(0, 12)>` so repeated scans agree. Persist the real ID on
  first placement or pivot edit.
- Asset IDs are a **relink hint**, not the primary dependency. Resolution order is:
  1. `source` native reference.
  2. `source_uid` via `ResourceUID.text_to_id()` + `ResourceUID.get_id_path()` when the UID is
     registered and the file exists.
  3. `source_path` relative to the parent (then absolute if stored absolute).
  4. Search both libraries for a manifest entry with the same `asset_id`.
  5. Prompt for relink.
- Capture `source_uid` with `ResourceLoader.get_resource_uid(path)` +
  `ResourceUID.id_to_text(id)` when `id >= 0`. Store `""` when the file has no UID. This is a hint;
  standalone files outside `res://` often have none.
- Renaming a source inside a library keeps its asset ID if the manifest is updated. The scanner can
  match by `mtime`/`size` when a manifest path disappears and exactly one new file appears; if
  ambiguous, leave the entry missing and let the user relink. Never guess when multiple candidates
  match.

### 7.4 Source validation

A source is **valid** when all of these hold:

- It loads as `VoxelModel`.
- `prefab_instances.is_empty()` (no nesting).
- It contains at least one cell or one light.
- Its cells lie within its own `bounds` (normalize/clip only in the source's own editor; a
  catalogue source is expected to be clean).
- Its `voxel_size` is positive. It is otherwise ignored for composition.
- Its catalogue pivot (default or stored) is finite and within `[-MAX_BOUND, MAX_BOUND]` on each
  axis, snapped to 0.5.

Invalid sources appear in the catalogue with a reason and cannot be placed. An instance whose
source becomes invalid is **incompatible**, not deleted.

### 7.5 Default pivot

For a source with cells:

```text
lo = minimum occupied cell (inclusive)
hi = maximum occupied cell (inclusive)
pivot = Vector3(
    (lo.x + hi.x + 1) * 0.5,
    lo.y,
    (lo.z + hi.z + 1) * 0.5)
```

This is the center of the occupied AABB in X/Z and its bottom face in Y. For a 1×1 asset the pivot
is `(0.5, 0, 0.5)`; for a 2×2 asset it is `(1.0, 0, 1.0)`.

For a light-only source, use the light position AABB:

```text
pivot = Vector3((min.x + max.x) * 0.5, min.y, (min.z + max.z) * 0.5)
```

Snap every component to the nearest 0.5. If the source is empty, reject it.

### 7.6 Source refresh

- **On open:** resolve all instances fresh. Use `CACHE_MODE_IGNORE` for the parent and
  `CACHE_MODE_IGNORE_DEEP` for sources so a changed file is not served from the resource cache.
- **Manual “Reload prefabs”:** reload each unique source path, update the catalogue metadata cache,
  recompute transforms, and revalidate every instance.
- **No watcher.** A source edit is noticed on reopen or when the user explicitly reloads.
- Refresh is **not undoable** and does **not** mark the parent dirty. It changes derived content,
  not authored data.
- Refresh summary: `Reloaded N prefabs: X updated, Y missing, Z conflicted, W incompatible`.
- If a source file disappears during refresh, its instances become **missing** (keep the old
  placeholder AABB from `source_bounds`; do not keep stale solid geometry).
- If a source becomes invalid, its instances become **incompatible**.
- If a source grows into another instance or a local voxel, the affected instances become
  **conflicted** (see §9.5). Do not clip, overwrite, or auto-move.
- If a source's lights are added/removed, the instance light count changes. Show the soft-budget
  warning if it is exceeded; do not block the refresh.

---

## 8. Transform math

### 8.1 Coordinates

- Source cell `c ∈ Z³` occupies `[c, c+1)` in source cell space; its center is `c + 0.5`.
- `pivot` is a point in the same continuous source space.
- `anchor` is a parent cell. The transformed pivot coincides with the anchor's **minimum corner**.
- `yaw_quarters ∈ {0,1,2,3}` rotates around the Y axis through the pivot.
- The parent controls physical scale. One source cell becomes one parent cell regardless of
  `source.voxel_size`.

### 8.2 Exact rotation

Use integer/fixed-point math, not `Vector3.rotated()` in a loop, to avoid float drift. With
`d = c + 0.5 - pivot`, the yaw mapping is:

```text
q = 0: ( x, y,  z)
q = 1: ( z, y, -x)     # +90° about Y, matching Godot's R_y(+90°)
q = 2: (-x, y, -z)
q = 3: (-z, y,  x)
```

Then:

```text
parent_center = Vector3(anchor) + rotated
parent_cell   = Vector3i(floori(parent_center.x),
                         floori(parent_center.y),
                         floori(parent_center.z))
```

Because `pivot` is a multiple of 0.5 and `c + 0.5` is a half-integer, every `parent_center`
component is a multiple of 0.5. Flooring is exact and two distinct source cells cannot collapse
into one parent cell. Do **not** allow arbitrary pivot values; a pivot at, say, `0.25` would make
the transformed cells land on quarter-cell offsets and break the voxel grid.

Implementation detail: compute per-source-cell **offsets** once:

```text
offset(c) = floor(rotate(c + 0.5 - pivot))
world(c)  = anchor + offset(c)
```

`offset` is independent of `anchor`, so an instance can be translated without recomputing the
rotation. Cache `(source identity, pivot, yaw) -> {offsets, colors, light_offsets}` in
`VoxelPrefabComposition`.

### 8.3 Lights

Source light position `l` is continuous in source cell space:

```text
world_light = Vector3(anchor) + rotate(l - pivot)
```

Range, color, energy, and shadows are unchanged. No floor. The light's transformed position must
lie inside the parent bounds (use the existing `light_in_bounds` rule).

### 8.4 Anchor and placement feel

`anchor` is the target cell returned by the placement hover (the empty cell adjacent to the hit
face). The transformed pivot lands on that cell's minimum corner. Consequences:

- A 1×1 asset with default pivot `(0.5, 0, 0.5)` fills exactly the target cell.
- A 3×3 asset with pivot `(1.5, 0, 1.5)` is centered on the target cell.
- A 2×2 asset with pivot `(1.0, 0, 1.0)` spans the target cell and the cell one step in `-X` and
  `-Z`; the pivot is the shared corner between the four bottom cells. This is inherent to an
  even-width bottom-center pivot and is made obvious by the ghost footprint.
- On top of a voxel at cell `c`, the placement target is `c + UP`, so `anchor.y = c.y + 1` and the
  asset's bottom sits on the voxel's top face.

Height-lock placement intersects the ray with the `y = work_layer` plane and uses the same anchor
rule. It ignores prefab voxels for the intersection, like the existing Place/Box behavior.

### 8.5 Rotation gesture

`R` increments `yaw_quarters` by 1 (mod 4) around the instance's pivot. The anchor does not change.
If the rotated footprint overlaps local voxels or another instance, the rotation is refused as a
whole; the instance keeps its previous yaw. Show a red preview while the key is held? No: rotate is
a discrete action. Show a status message with the reason and leave the instance unchanged. A
successful rotation marks old and new chunks dirty.

### 8.6 Bounds of a transformed instance

- With a resolved source: the AABB of `world(c)` over all source cells. For light-only assets, the
  AABB of transformed light positions.
- With a missing source: transform the 8 corners of the `source_bounds` AABB around the pivot and
  anchor, then take the AABB. This is only a placeholder.
- With a conflicted source: use the resolved source's transformed cell AABB. The solid content is
  omitted, but the red wireframe shows where it would be.

---

## 9. Composition, overlap, and conflicts

### 9.1 `VoxelPrefabComposition`

`VoxelPrefabComposition` owns the derived spatial view. It is a `RefCounted`, UI-free, and unit
tested. `VoxelDocument.prefab_instances` is the **authoritative authored list**; the composition's
`instances` dictionary is a lookup/cache kept in sync by the document. The local voxel grid is
passed into validation methods rather than stored, because `VoxelDocument.grid` is replaced on
load.

State:

```gdscript
var instances: Dictionary = {}        # instance_id -> VoxelPrefabInstance
var status: Dictionary = {}           # instance_id -> {state, reason}
var cells: Dictionary = {}            # Vector2i column key -> Dictionary(cell -> int owner)
var colors: Dictionary = {}           # Vector2i column key -> Dictionary(cell -> Color)
var instance_cells: Dictionary = {}   # instance_id -> Array[Vector3i]
var instance_lights: Dictionary = {}  # instance_id -> Array[Dictionary]
var source_cache: Dictionary = {}     # resolved path -> {model, revision, error}
```

Use the same 64×64 XZ column bucketing as the editor's chunk renderer. `cells[column][cell]`
answers ownership in O(1); `colors[column][cell]` gives the mesh color without a second instance
lookup. `owner_at` returns `0` for “no instance”; instance IDs start at 1. Column keys are
`Vector2i(cell.x / 64, cell.z / 64)`. This avoids a single million-entry global dictionary and
makes chunk rebuilds and moves local.

Methods:

```gdscript
func add_instance(inst, source_model, source_path, local_grid) -> Dictionary
func remove_instance(id) -> bool
func move_instance(id, anchor, local_grid) -> Dictionary
func rotate_instance(id, delta, local_grid) -> Dictionary
func set_instance_transform(id, anchor, yaw, local_grid) -> Dictionary
func set_source(id, source_model, source_path, asset_id, source_bounds, local_grid) -> bool
func refresh(sources: Dictionary, local_grid) -> Dictionary
func validate_all(local_grid) -> Dictionary
func owner_at(cell: Vector3i) -> int
func color_at(cell: Vector3i) -> Color
func has_cell(cell: Vector3i) -> bool
func colors_in_column(key: Vector2i) -> Dictionary  # cell -> Color, for meshing
func world_cells(id) -> Array[Vector3i]
func world_lights(id) -> Array[Dictionary]
func bounds_for(id) -> AABB
func light_count() -> int
func total_cells() -> int
```

`add_instance` / `move_instance` / `rotate_instance` / `set_instance_transform` return
`{ok: bool, reason: String, cells: Array, lights: Array}`. They are all-or-nothing and do not
mutate on failure. They are called by `VoxelDocument` inside a stroke.

### 9.2 Validation order

For a candidate placement/duplicate (and for a move/rotate that will re-add solid content):

1. Source is resolved and valid.
2. Every transformed cell is inside `[0, doc.bounds)`.
3. Every transformed light is inside the parent bounds.
4. Every transformed cell is empty in `doc.grid`.
5. Every transformed cell is unowned in the composition (excluding the instance being moved or
   rotated).
6. Light budget is checked separately (soft warning, not a validation failure).

Moving or rotating a **missing** instance has no transformed cells/lights, so only the transform
and placeholder-bounds checks apply. Moving a **conflicted** instance re-runs the full validation;
a successful move clears the conflict.

Refuse the whole operation on any failure. Never clip cells, drop lights, or partially place.

### 9.3 Overlap rules

- Local voxels always block instance cells.
- Instance cells always block local voxels and other instances.
- Adjacency is allowed and expected. Faces between adjacent local/instance cells are culled by the
  chunk mesh builder because both are merged into one per-chunk color grid.
- There is no “local wins” or “placement order wins” rule because overlap is never allowed for
  valid content. Conflicts after an external source edit are handled by the conflict state, not by
  ownership priority.
- Placement, move, rotate, and duplicate all use the same validation. A drag that ends on an
  invalid position cancels and restores the previous transform.

### 9.4 Bounds and resize

`resize_bounds()` must also refuse if shrinking would cut any **valid** instance cell or
transformed light. It does not need to block on missing/conflicted placeholders, because those are
not part of the solid composition. Never clip an instance. The existing “refuse if voxels/lights
would fall outside” rule stays, extended with prefab cells/lights.

The parent's `MAX_BOUND` is 1024 per axis. A source larger than that can still be catalogued, but
placing it is refused unless the transformed footprint fits. There is no auto-grow.

### 9.5 Conflict state after a source refresh

“Forbid overlap” governs user edits. It cannot prevent an external file from changing into an
overlapping shape. The non-destructive answer is a conflict state.

When refresh or open detects an instance whose transformed cells overlap local voxels, another
instance, or the bounds:

- Set `status[id] = {state: "conflict", reason: "..."}`.
- Remove its cells/lights from the composition. It contributes nothing solid and no lights.
- Keep the instance resource, source reference, pivot, anchor, and yaw.
- Draw a **red wireframe** around its transformed footprint (resolved source AABB, or
  `source_bounds` for missing sources).
- Keep it selectable in the Prefab tool so the user can move, rotate, relink, or delete it.
- Refuse `Unpack` while conflicted; unpacking would create overlapping local voxels.
- Moving or rotating it to a valid position clears the conflict and re-adds its cells/lights.
- On save, conflicted instances are saved normally (their references are preserved). Reopening
  re-evaluates the conflict against the then-current sources.

Conflict reasons should be specific: `overlaps local voxel at (x, y, z)`,
`overlaps prefab instance #N`, `cell (x, y, z) is outside bounds`,
`light at (x, y, z) is outside bounds`.

### 9.6 Missing state

- Set `status[id] = {state: "missing", reason: "..."}` when neither the native source nor the
  fallback path/asset ID resolves.
- Remove its cells/lights from the composition.
- Draw a red/grey wireframe box from `source_bounds`.
- Keep it selectable; allow move/rotate/delete/relink. Move/rotate of a missing instance is
  allowed because there is no solid content to overlap; it just updates the transform.
- Refuse `Unpack` while missing (no geometry to unpack).
- Saving preserves `instance_id`, `asset_id`, `source_path`, `source_uid`, `source_bounds`,
  `pivot`, `anchor`, and `yaw`, with `source = null`.
- Reopening tries the fallback again. If the file reappears at the same path, it resolves
  automatically.

### 9.7 Incompatible state

- A source that contains prefab instances is not a legal source.
- Set `status[id] = {state: "incompatible", reason: "source contains prefab instances"}`.
- Omit its solid content/lights and show a red wireframe from `source_bounds` (or the resolved
  source's transformed bounds).
- Keep the instance for relink/delete.
- The catalogue shows the asset with an “Incompatible” badge and disables Place.
- To make such a model a source, the user must unpack its instances and save it again. A
  “Unpack all prefabs” action is a nice-to-have; see §18.

### 9.8 Composition status summary

`VoxelDocument` exposes:

```gdscript
func prefab_status_counts() -> Dictionary  # {ok, missing, conflict, incompatible}
func prefab_light_count() -> int
func prefab_cell_count() -> int
func has_prefab_problems() -> bool
```

The editor shows a warning in the status bar and a `Review...` button when any count is non-zero.

---

## 10. Document API and undo

### 10.1 Public API

Add to `VoxelDocument`:

```gdscript
signal prefabs_changed

var prefab_instances: Array[VoxelPrefabInstance] = []
var prefab_light_budget: int = 64
var prefab_composition: VoxelPrefabComposition

func place_prefab(source: VoxelModel, source_path: String, asset_id: String,
                  pivot: Vector3, anchor: Vector3i, yaw: int) -> Dictionary
func move_prefab(id: int, anchor: Vector3i) -> Dictionary
func rotate_prefab(id: int, delta: int = 1) -> Dictionary
func duplicate_prefab(id: int, anchor: Vector3i) -> Dictionary
func delete_prefab(id: int) -> Dictionary
func unpack_prefab(id: int) -> Dictionary
func relink_prefab(id: int, source: VoxelModel, source_path: String,
                   asset_id: String = "") -> Dictionary
func refresh_prefabs(sources: Dictionary = {}) -> Dictionary
func prefab_at(cell: Vector3i) -> int
func prefab_world_cells(id: int) -> Array[Vector3i]
func prefab_world_lights(id: int) -> Array[Dictionary]
func prefab_bounds(id: int) -> AABB
func prefab_status(id: int) -> Dictionary
func prefab_light_count() -> int
func prefab_cell_count() -> int
func prefab_status_counts() -> Dictionary
```

All mutating methods except `refresh_prefabs` wrap a stroke:

```gdscript
begin_stroke()
# validate + mutate
end_stroke()
```

`refresh_prefabs` is not undoable and does not dirty the document. It emits
`prefabs_changed` and `changed` so the renderer rebuilds.

`place_prefab` is called by the catalogue/editor and by MCP. It accepts a resolved `source`
resource; the caller is responsible for loading it (the catalogue has already done so). The
document re-validates the source and pivot.

### 10.2 `last_touched` for prefabs

The editor's chunk invalidation currently uses `doc.last_touched` (local cells) and
`doc.last_touched_lights`. Add:

```gdscript
var last_touched_prefab_chunks: Dictionary = {}  # Vector2i -> true
var last_touched_prefabs: Dictionary = {}        # instance_id -> true
```

Every prefab mutation records the old and new column keys of the affected instance(s) into
`last_touched_prefab_chunks`. For add/remove/move/rotate/unpack/relink, this is a small set. For
refresh, record all columns that currently contain instance cells plus the columns the refreshed
instances previously occupied. The editor's `changed` handler:

```gdscript
for key in doc.last_touched_prefab_chunks:
    _touch_chunk(key.x * CHUNK_SIZE, key.y * CHUNK_SIZE)
doc.last_touched_prefab_chunks.clear()
```

Then it rebuilds those chunks from `doc.grid` + `doc.prefab_composition.colors_in_column(key)`.
`_doc_replaced` still rebuilds everything on open.

### 10.3 Undo namespace

`end_stroke()` currently appends `{"voxels": net, "lights": net_lights}`. Add a third namespace:

```gdscript
var net_prefabs: Dictionary = {}  # instance_id -> [before_instance, after_instance]
```

- `before_instance` / `after_instance` are `VoxelPrefabInstance` copies (scalars + `source`
  reference), or `null` for add/remove.
- A stroke is a no-op only if `net`, `net_lights`, and `net_prefabs` are all empty.
- The undo entry becomes `{"voxels": ..., "lights": ..., "prefabs": ...}`.

`_is_legacy_history()` becomes:

```gdscript
return not entry.has("voxels") and not entry.has("lights") and not entry.has("prefabs")
```

Apply order:

- **Undo:** voxels side 0 → lights side 0 → prefabs side 0.
- **Redo:** prefabs side 1 → voxels side 1 → lights side 1.

This order matters for unpack:

- Unpack adds voxels/lights and removes an instance. Undo removes the added content first, then
  restores the instance. Redo removes the instance first, then adds the content.
- Add/remove/move/rotate/relink have no voxel/light deltas, so the order is irrelevant.

`_apply_prefab_history(entry, side)`:

- For each `id`, take the snapshot.
- If `null`, remove the instance from the document and composition.
- If a snapshot, insert or replace it and rebuild its composition entry.
- Recompute `prefab_light_count`, status counts, and affected chunks.
- Do not **refuse** an undo/redo because of overlap; history is authoritative. Attempt to insert
  the snapshot; if the composition detects an overlap (because the document changed outside the
  history), keep the instance in the conflict state rather than silently dropping it. This is
  rare; it can happen if undo crosses a source refresh. Mark it conflicted and let the user
  resolve it.

### 10.4 Unpack

`unpack_prefab(id)`:

1. Refuse if the instance is missing/conflicted/incompatible.
2. Refuse if any world cell is already occupied by local voxels (invariant violation; report it).
3. Count the instance's transformed lights. If `doc.lights.size() + count > 32`, refuse the whole
   unpack with a clear message. (The parent's hard light limit is 32.)
4. Begin one stroke.
5. For each world cell, write the source color into `doc.grid` using the normal `_write` path so
   the voxel history and `last_touched` are recorded.
6. For each transformed light, allocate a new parent light ID and add it with that ID. Keep the
   transformed position, color, energy, range, and shadows.
7. Remove the instance from the document/composition and record the prefab history entry
   (`before = instance`, `after = null`).
8. End the stroke. One undo restores both the instance and removes the unpacked content.

If step 5/6 fails partway (it should not, after validation), abort the stroke and restore the
document state; do not leave a half-unpacked instance. The light count check happens before any
mutation.

### 10.5 Duplicate

`duplicate_prefab(id, anchor)`:

- Copy the instance with a new `instance_id`.
- Same source, asset ID, pivot, source bounds, and yaw.
- Validate the new anchor exactly like placement.
- One stroke, one undo step.
- The UI normally starts a placement ghost for the duplicate and calls this on click. MCP can call
  it directly with an anchor.

### 10.6 Delete

- Remove the instance from the list and composition.
- Record `before = instance`, `after = null`.
- One stroke. Undo restores it and revalidates. If it no longer fits, it comes back conflicted
  rather than silently dropped.

### 10.7 Relink

- Validate the new source and its compatibility.
- Update `source`, `source_path`, `asset_id`, and `source_bounds` (the new source's occupied AABB).
- Keep `pivot`, `anchor`, and `yaw`; the new source is composed with the existing pivot snapshot.
- Revalidate. If the new source overlaps at the current transform, the instance becomes
  conflicted (the relink itself succeeds, because the user explicitly chose the file; the
  conflict is shown and can be resolved by moving).
- One stroke, one undo step. Undo restores the old source/path/status.
- If the old source was missing, undo restores the missing state.

### 10.8 Load/save

`load_model(m, source_path)`:

- Load `m.prefab_instances` into the document (copy scalar fields; keep `source` references).
- Resolve missing sources via `source_uid`/`source_path`/`asset_id`.
- Build the composition and validate all instances.
- Populate `prefab_light_budget` from the model.
- Clear prefab undo/redo history along with voxel/light history.
- `changed` must fire after the composition is ready so the editor's `_doc_replaced` path rebuilds
  all chunks.
- Return the existing dropped-voxel count; also log dropped/invalid prefab instances (they are
  kept, not dropped, unless the resource itself is malformed).

`to_model()`:

- Copy local data as today.
- Copy `prefab_instances` with `copy_for_save()`.
- Copy `prefab_light_budget`.
- Do not include derived composition data.

`save_file(target)`:

- Use `FLAG_RELATIVE_PATHS`.
- Recompute `source_path` for every instance relative to `target.get_base_dir()` before saving.
- After a successful save, update `path`, `dirty = false`, and emit `meta_changed`.
- If a source path cannot be made relative safely, keep the absolute path and warn.

---

## 11. Editor integration

### 11.1 Tools and shortcuts

Add a `PREFAB` tool to the `Tool` enum. Keep the existing numbering for tools 1–9; Prefab is `0`.

```text
Tool { PLACE, ERASE, PAINT, PICK, BOX, BOX_ERASE, FILL, LIGHT_PLACE, LIGHT_EDIT, PREFAB }
```

`TOOL_NAMES` / `TOOL_HINTS` gain `"Prefab"` / a context-sensitive hint.

Shortcuts:

- `0` — Prefab tool.
- `B` — open/close the prefab catalogue.
- `R` — rotate the selected instance (or the armed placement ghost) by 90°.
- `Ctrl+D` / `Cmd+D` — duplicate the selected instance into a placement ghost.
- `Delete` / `Backspace` — delete the selected instance.
- `Esc` — cancel the armed asset/ghost, then clear the selection.
- Existing shortcuts (`1`–`9`, `H`, `[`/`]`, `X`/`Z`, `Q`/`E`, `P`, `G`, `F`, `Ctrl+Z`,
  `Ctrl+N/O/S`) remain unchanged.

Use `k.command_or_control_autoremap` for Ctrl/Cmd. Ignore raw `KEY_META` presses as today.
Keyboard handling must respect focus: if a `LineEdit`, `TextEdit`, or `SpinBox` has focus, do not
consume `B`, `R`, `Ctrl+D`, `Delete`, or `0`. The existing `_update_navigation()` focus check is a
useful pattern.

### 11.2 Prefab tool behavior

Two modes:

1. **Armed asset** (chosen from the catalogue):
   - The cursor shows a translucent ghost of the prefab at the current hover anchor.
   - Ghost color: normal translucent tint when valid; red tint when out of bounds, overlapping,
     or light-out-of-bounds.
   - LMB places one instance and keeps the asset armed for repeated placement. This is the natural
     default for trees/lamps; `Esc` or a right-click exits.
   - `R` rotates the ghost; the ghost mesh updates.
   - `Ctrl+D` while armed is ignored (nothing selected to duplicate).
   - Clicking the catalogue again or pressing `B` switches the armed asset.
2. **Selection mode** (no asset armed):
   - Click a valid instance to select it. Because conflicted/missing instances have no solid
     cells, also test their placeholder AABBs when the solid raycast misses. Clicking a local
     voxel or empty space clears the selection.
   - Drag a selected instance on the grabbed face plane (the same rule as voxel strokes), so dragging
     sideways on a top face never sinks the instance in Y. The drag delta is snapped to integer
     cells. Each new cell calls `move_prefab` immediately, which is all-or-nothing: an invalid step
     is refused with a message and the instance stays at its last valid anchor. Release ends the
     stroke; the whole drag is one undo step.
   - `R` rotates around the pivot. Invalid rotation is refused with a message.
   - `Ctrl+D` starts a placement ghost for a duplicate. The original remains selected until the
     duplicate is placed; `Esc` cancels the duplicate.
   - `Delete` removes the selected instance.
   - The status/hint line shows the asset name, anchor, yaw, and status.
   - Selection outline: a wireframe box plus a brighter outline of the instance's cells (or just
     the AABB for large instances). Do not rebuild a million-line mesh; use the AABB for assets
     above a threshold (e.g. 50k cells) and a cell-edge mesh below it.

Placement uses the composed raycast, so prefab surfaces behave like solid surfaces for the cursor.
The hovered target cell becomes `anchor`: the source cell at the pivot maps onto that cell (a 3×3
tree with pivot `(1.5, 0, 1.5)` spans `anchor − 1 … anchor + 1`).
Selection uses it first, then falls back to placeholder AABBs for non-solid instances.

### 11.3 Ordinary tools on prefab content

- **Place / Box:** raycast the composed scene. A hit on a prefab cell gives a normal; the target is
  the empty adjacent cell. Building on a prefab surface is allowed. The new voxel is local.
  Height lock still uses the `y = work_layer` plane and ignores prefab voxels.
- **Paint / Erase / Fill / Box Erase:** if the hit cell is instance-owned, refuse and say
  `Linked prefab: unpack to edit`. If a box/fill region contains any instance cell, refuse the
  whole operation (all-or-nothing), with the same message and the first conflicting cell.
- **Pick:** allowed. Sample `composition.color_at(cell)` for instance cells, `doc.grid[cell]` for
  local cells. Set the current color. Do not select or unpack.
- **Light Place:** raycast the composed scene for a surface; add a parent light in the adjacent
  cell/space as today. Do not add lights to the instance.
- **Light Edit:** only edits parent lights. Clicking an instance light does nothing (instance
  lights are atomic and not individually selectable in v1).
- **Box / Fill preview:** if the preview includes linked cells, tint the preview red and show the
  refusal hint before the user commits.

### 11.4 Chunk renderer

The existing renderer is chunked by 64×64 XZ columns, all Y. Extend it:

- The composition is already indexed by column, so the renderer does **not** need a second
  prefab cell index. `doc.prefab_composition.colors_in_column(key)` returns the column's prefab
  color grid.
- On a prefab change, `VoxelDocument` fills `last_touched_prefab_chunks`. The editor's `changed`
  handler marks each affected column dirty and ensures its chunk record exists.
- `_build_chunk_mesh`:

```gdscript
var cells := {}
for p in (_chunk_cells.get(key, []) as Array):
    if doc.grid.has(p):
        cells[p] = doc.grid[p]
var prefab_colors: Dictionary = doc.prefab_composition.colors_in_column(key)
for p: Vector3i in prefab_colors:
    cells[p] = prefab_colors[p]
var mesh := VoxelMeshBuilder.build_mesh(cells, 1.0)
```

- Merge local and instance cells **before** meshing so faces between a local voxel and an adjacent
  prefab cell are culled. Faces at chunk boundaries remain unculled, matching current behavior.
- Rebuild only affected columns on move/rotate/delete. On source refresh, mark all columns that
  contain instance cells (plus previously occupied columns) dirty; do not rescan the full grid.
- The render horizon still applies. Chunks beyond the horizon are not meshed; raising it reveals
  farther chunks. The composition always holds the full instance set.
- `_on_doc_reset()` must clear `_chunks`, `_grid_chunks`, and `_chunk_cells`, then rebuild from the
  new document. The composition is rebuilt by `VoxelDocument` before `changed` fires.

### 11.5 Composed raycast

Add to `voxel_raycast.gd`:

```gdscript
static func cast_composed(local_grid: Dictionary, composition, bounds: Vector3i,
                          origin: Vector3, dir: Vector3) -> Dictionary
```

It performs the same Amanatides & Woo traversal and returns the existing keys plus:

- `prefab_id: int` — 0 for a local voxel, the instance ID for a prefab cell, -1 for none.
- `color: Color` — the hit cell's color, for Pick.
- `owner` semantics: local cells win if both somehow exist (they should not, due to overlap
  rules), so the invariant is defensive.

The DDA checks `local_grid.has(p)` first, then `composition.has_cell(p)`. This is a dictionary
lookup per step, not a full-scene scan. It returns the same `floor` behavior as `cast()`.

Keep the existing `cast()` unchanged for current tests and callers. The editor's `_compute_hover`
switches to `cast_composed` and records `prefab_id` in the hover dictionary.

### 11.6 Ghost and selection visuals

`VoxelPrefabRig` (Node3D) owns:

- A ghost `MeshInstance3D` built from the transformed cells of the armed asset, with a translucent
  unshaded material. Cache meshes by `(source path, source revision, pivot, yaw)`; invalidate on
  source refresh.
- A red invalid tint (or a second material) when the candidate is invalid.
- A selection wireframe (AABB or cell edges) for the selected instance.
- A pivot marker (small 3-axis cross or sphere) used by the catalogue preview and optionally the
  main viewport selection.
- A drag plane helper? The editor computes the plane and anchor; the rig only displays.

For assets above a size threshold (e.g. 50k cells), the ghost falls back to an AABB wireframe to
avoid building a huge translucent mesh. The status hint says `Large prefab: box preview`. This is
a display fallback, not a semantic one.

### 11.7 Side panel

Add a compact **Prefabs** section to the existing side panel (collapsed by default). It is not the
catalogue; it is the action/status surface:

- `Open catalogue (B)` button.
- `Reload prefabs` button.
- Selected instance: name, anchor, yaw, status; `Unpack` and `Delete` buttons.
- `Instance lights: N / soft budget B` label; clicking opens a small budget spin box.
- `Problems: M missing, K conflicted, J incompatible` label with `Review...` (opens the catalogue
  on its Problems tab).
- `Save a copy to library...` action for the current model (disabled if the model contains
  prefab instances, because that would create a nested source).

Keep the section header consistent with `_section(parent, title, expanded)` and the ▼/▶ arrow.
Do not add the catalogue grid to the side panel; the user chose a separate visual browser.

### 11.8 Status bar

Update `_update_status()`:

```text
castle.tres*  |  1,234 local voxels  |  5,678 linked  |  64x64x64  |  12 prefabs  |  38 lights
```

- `linked` = `doc.prefab_cell_count()`.
- `lights` = parent lights + instance lights for display. The `!`/warning color appears when
  `doc.prefab_light_count() > doc.prefab_light_budget` (instance lights only; the parent has its
  own hard limit of 32).
- If any problems: append `| 2 missing, 1 conflicted` and make it clickable if the status label
  supports it. Otherwise the Prefabs section’s `Review...` is the entry point.
- The window title stays `name* - Voxdot`.

### 11.9 Placement validation messages

Use the existing `_say()`/status hint mechanism. Be specific:

- `Cannot place: overlaps local voxel at (12, 3, 8)`
- `Cannot place: overlaps prefab #4`
- `Cannot place: cell (64, 0, 0) is outside bounds`
- `Cannot place: light at (12.5, 4, 8) is outside bounds`
- `Cannot place: source is missing`
- `Cannot place: source contains prefab instances`
- `This placement adds 12 instance lights; the scene will have 76 (soft budget 64). Place anyway?`
- `Cannot unpack: 5 instance lights would exceed the parent limit of 32`
- `Linked prefab: unpack to edit`

Do not silently skip cells or lights.

### 11.10 Instance light rendering in the editor

The parent's `doc.lights` and the instance lights are separate rendering groups:

- `_sync_light_nodes()` continues to render only `doc.lights` (the parent's editable lights).
- `VoxelPrefabRig` owns a `PrefabLights` `Node3D`. After any prefab change or refresh, rebuild it
  from `doc.prefab_composition.world_lights(id)` for every **valid** instance. Conflicted, missing,
  and incompatible instances contribute no lights.
- Each light is an `OmniLight3D` named `Prefab<instance_id>_Light<index>` with the transformed
  position, color, energy, range, and shadow flag. Instance lights are not added to `doc.lights`,
  are not in the Light inspector, and are not individually selectable in v1.
- The parent sun remains the only directional light. Instance lights do not change
  `_apply_environment()`.
- Rebuilding the whole group is fine for the target scale (hundreds of instances, a few lights
  each). If profiling shows a stall, update transforms in place when the instance set and source
  revisions are unchanged.
- The Prefabs section's light count is `doc.lights.size() + doc.prefab_light_count()`; the soft
  budget warning uses the instance count, not the parent count.
- On `_on_doc_reset()` / `_doc_replaced`, clear the `PrefabLights` group before rebuilding from the
  new document.

---

## 12. Catalogue dialog

### 12.1 Layout

A dedicated `Window` (resizable, centered, exclusive input) opened by `B` or the Prefabs section.
Suggested minimum size 1000×640.

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ [Search..............] [Library: All/User/Project] [Refresh]             │
├──────────────┬───────────────────────────────────────┬───────────────────┤
│ Folders      │  Thumbnail grid                       │  Details          │
│  All         │  ┌────┐ ┌────┐ ┌────┐                 │  Preview viewport │
│  props/      │  │tree│ │lamp│ │door│                 │  (orbit/zoom)     │
│  buildings/  │  └────┘ └────┘ └────┘                 │  name / path      │
│              │                                       │  bounds / counts  │
│  Problems    │                                       │  pivot X/Y/Z      │
│              │                                       │  [Reset pivot]    │
│              │                                       │  [Place]          │
├──────────────┴───────────────────────────────────────┴───────────────────┤
│ 123 assets · 2 missing · 1 conflicted                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

- Left: folder tree (All / User / Project roots, then subfolders) plus a `Problems` item.
- Center: `ScrollContainer` + `GridContainer` of thumbnail buttons. Each shows the rendered
  thumbnail, asset name, and a badge for missing/incompatible. Double-click or `Place` arms it.
- Right: large interactive preview, metadata, pivot editor, `Place`.
- Bottom: counts and a short status/hint line.

### 12.2 Search and filtering

- Search matches asset name and relative path, case-insensitive. Debounce ~150 ms.
- Library filter: All / User / Project. Project is disabled when no model is open or the folder
  does not exist.
- Folder selection filters to that folder (non-recursive) by default; a `Search all folders`
  toggle (or search automatically searches recursively) is available. Keep the rule simple:
  typing in search searches the whole selected library; an empty search shows the selected
  folder’s direct children.
- `Show problems` toggle includes missing/incompatible assets; by default valid assets are shown.
- Sort by name ascending in v1. Recent-modified sorting is a nice-to-have.

### 12.3 Thumbnails

- Generate from the source geometry in an offscreen `SubViewport` (256×256 or 320×320) with an
  isometric camera, a directional light, and the shared voxel material.
- Frame the model to fit with a small margin; include the pivot marker (small cross/sphere) so the
  thumbnail communicates the anchor.
- Cache key: `asset_id + mtime + pivot` (hash it for the filename). Store as PNG or WebP under
  `user://prefab_thumbs/`.
- Generate lazily while the dialog is visible, a few per frame, to avoid a long stall on a
  500-asset library. Show a placeholder icon until ready.
- On headless builds, skip generation and use a placeholder. Tests must not require a display.
- Invalidate a thumbnail when the source `mtime`/size changes or the pivot changes.
- Do not write thumbnails into the library folder.

### 12.4 Large preview and pivot picking

- The preview is a `SubViewportContainer` with its own `Camera3D`, light, and environment.
- Orbit with LMB drag, zoom with the wheel. Do not let these events reach the main editor.
- Draw a pivot marker at the current pivot.
- Click a voxel face to set the pivot: cast a ray from the preview camera against the source
  grid, take the hit point, snap each component to the nearest 0.5, and update the pivot fields.
  This makes it easy to click a bottom face for a ground pivot or a side face for a hinge.
- Numeric X/Y/Z `SpinBox` fields with step 0.5, range `[-MAX_BOUND, MAX_BOUND]`, and
  `allow_greater`/`allow_lesser` off. Editing a field updates the marker and preview.
- `Reset to bottom-center` recomputes the default pivot from the source's current occupied AABB.
- Pivot edits write the catalogue manifest (debounced) and affect **future placements only**.
  Existing instances keep their snapshot. Show a one-line note: `Existing instances keep their
  pivot.`
- If the source contains prefab instances, the preview shows an “Incompatible” overlay and the
  Place button is disabled.

### 12.5 Problems tab

Lists every instance in the current parent with a non-ok status:

```text
[Missing]  tree_01.tres        instance #3   anchor (10,0,6)   [Relink...] [Select]
[Conflict] house.tres          instance #7   overlaps #4        [Select]
[Incompatible] village.tres    instance #9   contains prefabs   [Relink...] [Select]
```

- `Relink...` opens a file dialog filtered to `.tres`/`.res`, loads and validates the chosen file,
  and calls `doc.relink_prefab`. If the new source would conflict at the current transform, the
  relink succeeds but the instance stays conflicted; show the reason.
- `Select` closes the dialog, switches to the Prefab tool, and selects the instance.
- A `Reload prefabs` button is also available here.
- Missing entries can also offer `Search by asset ID` (scans both libraries) before a manual file
  pick.

### 12.6 Placement flow

1. Select an asset in the grid.
2. Inspect the preview/pivot.
3. Press `Place` or double-click the thumbnail.
4. The dialog hides, the editor switches to the Prefab tool, and the asset is armed.
5. The ghost follows the cursor; LMB places; `R` rotates; `Esc` cancels.
6. The asset stays armed for repeated placement; `Esc` once more returns to selection mode.

If the parent has unsaved changes, opening/closing the catalogue does not prompt; it does not
modify the parent. Only placement does.

### 12.7 Save a copy to library

A convenience action in the Prefabs section or File menu:

- Choose `User library` or `Project library` and a filename.
- Refuse if the current model contains prefab instances (would create a nested source).
- Save `doc.to_model()` to `<library>/<name>.tres` with `FLAG_RELATIVE_PATHS`; do not change the
  current document's path or dirty state.
- Refresh the catalogue and select the new asset.
- If a file with that name exists, ask before overwriting.
- This is the easiest way to populate an empty library without using Save As and losing the
  current document path.

### 12.8 Empty states

- No libraries / no assets: `No prefabs found. Save a model into <path> or use “Save a copy to
  library”.` with a button to create/open the user library folder.
- Project library unavailable: `Open a saved model to see its project Prefabs folder.`
- Search with no results: `No prefabs match “...”`.
- All assets invalid: list the reasons in the Problems tab; do not show a blank grid without
  explanation.

---

## 13. MCP tools

The MCP server mirrors user-visible actions. Add these tools to `_define_tools()` and implement
matching `_tool_*` functions. Keep `tools/list` and the handlers in sync; add an end-to-end test
for every new tool (see AGENTS learning #9).

Catalogue:

- `prefab_list_assets` — args: `library` (`all|user|project`), `search`, `include_invalid`.
  Returns `{assets: [{asset_id, name, path, library, bounds, cells, lights, pivot, valid,
  has_prefabs, reason}]}`.
- `prefab_refresh_assets` — rescan libraries and return the asset list summary.
- `prefab_get_asset` — args: `asset_id` or `path`; returns details including a thumbnail path if
  cached.
- `prefab_set_pivot` — args: `asset_id`, `pivot: [x,y,z]`. Validates/snaps to 0.5. Writes the
  manifest. Returns the updated asset.
- `prefab_reset_pivot` — args: `asset_id`.

Instances:

- `prefab_place` — args: `asset_id` (or `path`), `anchor: [x,y,z]`, `yaw: 0..3`,
  `allow_over_budget: bool = false`. Returns `{ok, instance_id, cells, lights, status}` or a
  specific error.
- `prefab_list_instances` — returns `{instances: [{id, asset_id, source_path, anchor, yaw, pivot,
  status, cells, lights}], counts}`.
- `prefab_get_instance` — args: `id`.
- `prefab_move` — args: `id`, `anchor`.
- `prefab_rotate` — args: `id`, `delta` (default 1).
- `prefab_duplicate` — args: `id`, `anchor` (required, so automation is deterministic).
- `prefab_delete` — args: `id`.
- `prefab_unpack` — args: `id`.
- `prefab_relink` — args: `id`, `path`, optional `asset_id`.
- `prefab_reload` — reload all sources, return the refresh summary.
- `prefab_get_state` — counts, statuses, instance light total, soft budget, missing/conflict
  reasons.

Composition queries:

- `get_voxels` remains **local-only** for backward compatibility.
- Add `get_composed_voxels` — args: `include_prefabs` (default true), returns cells with owner
  (`0` = local, `instance_id` for linked). For large scenes this can be huge; document it.
- `prefab_light_count` is included in `prefab_get_state`.

Tool naming and errors:

- Add `"prefab"` to `TOOL_NAMES_LIST` at the same index as `Tool.PREFAB` so `set_tool` works.
- Errors must be actionable strings: `overlap at (x,y,z)`, `outside bounds`, `source missing`,
  `source incompatible`, `parent light limit would be exceeded`, `soft light budget exceeded
  (pass allow_over_budget=true)`.
- `prefab_place` must not open a modal budget dialog. It uses the explicit
  `allow_over_budget` flag. The UI uses the dialog and then calls the same document method.
- MCP calls go through the same `VoxelDocument` methods as the UI, so undo, dirty state, and
  status are identical.

---

## 14. Runtime

### 14.1 `VoxelModel` composed helpers

Add:

```gdscript
func build_composed_grid() -> Dictionary
func build_composed_lights() -> Array[Dictionary]
func has_unresolved_prefabs() -> bool
func prefab_summary() -> Dictionary
```

- `build_composed_grid()` starts from `to_grid()` and adds each resolved instance's transformed
  cells with the source colors. If two instances somehow overlap in a malformed file, the first
  one in `prefab_instances` order wins and a warning is emitted. The editor prevents this; runtime
  is defensive.
- `build_composed_lights()` returns local lights plus transformed instance lights. Local light
  entries keep their IDs. Instance lights get a synthetic ID for naming/debugging, e.g.
  `instance_id * 100000 + source_light_index` (names only; the editor never edits these IDs).
- `has_unresolved_prefabs()` is true when any instance has `source == null` or fails validation.
- `prefab_summary()` returns counts for debugging/telemetry.

`build_mesh()` changes to use `build_composed_grid()`; for models without prefabs it is
byte-for-byte the same mesh as today. `build_lights()` uses `build_composed_lights()`.

### 14.2 `VoxelModelInstance`

- `rebuild()` builds one mesh from the composed grid and adds all composed lights.
- Collision uses the composed mesh, so linked content is collidable.
- Scaling is unchanged: the parent `VoxelModel.voxel_size` scales the whole composition. Source
  `voxel_size` is ignored.
- Missing sources: skip them and `push_warning("VoxelModelInstance: missing prefab source ...")`.
  Do not show editor wireframes in a shipped game. Optionally add
  `@export var show_missing_prefabs: bool = false` for debugging; when true, draw a magenta AABB
  from `source_bounds`. This is off by default.
- If the whole model fails to load because a dependency is missing, that is a Godot resource-load
  failure outside Voxdot's control. Document that dependencies must ship with the parent.
- Runtime does not enforce the soft light budget. It creates all instance lights. The editor
  warns; the game ships what the author saved.

### 14.3 Shipping dependencies

- A parent `.tres` references sources via Godot external resources. In a Godot project, keep the
  `Prefabs/` folder structure and let the resource loader resolve the dependencies. The editor
  writes relative paths when possible.
- In the standalone Voxdot build, models are loaded from absolute paths outside `res://`. Copy the
  parent and its `Prefabs/` folder together, preserving relative structure.
- Copying the parent alone intentionally produces missing placeholders in the editor and skipped
  instances/warnings at runtime. This is the chosen trade-off, not a bug.
- `.res` binary parents and `.tres` text parents both support external references; test both in
  the format spike if time permits.

### 14.4 Runtime mesh cost

The runtime builds one composed mesh, as today. For ~1M cells this can take noticeable time at
load; acceptable for v1. A future optimization is per-instance meshes with boundary face culling,
but that would complicate adjacency and is out of scope. Document the load-time cost and suggest
splitting very large scenes into multiple `VoxelModelInstance` nodes.

---

## 15. Performance plan

Target workload: ~500 small/medium instances, ~1M composed cells, ~500 catalogue assets.

### 15.1 Composition

- Column-bucketed indices avoid a single million-entry dictionary and make moves local.
- Each instance caches its transformed `world_cells` and light offsets for its current
  `(source revision, pivot, yaw)`. Moving only adds `anchor`; rotating recomputes offsets.
- Cache transform results per `(source path, source revision, pivot, yaw)` so 100 identical trees
  share one offset array; invalidate on source refresh. Colors are stored per source cell and
  copied into the column color map on insertion.
- Overlap checks iterate only the candidate instance's cells, not the whole scene.
- Moving an instance removes old cells from the old columns and inserts new cells into the new
  columns; only those columns are marked dirty.
- Avoid full-grid scans. The existing chunk-cell index is the model.

### 15.2 Rendering

- Chunk meshes merge local + instance cells for the column. Rebuild only dirty columns.
- The render horizon still caps which chunks are meshed. A large scene can keep the full
  composition in memory while rendering only nearby chunks.
- The ghost mesh is cached per asset/pivot/yaw; invalidate on source refresh. Use an AABB fallback
  above a cell threshold.
- Thumbnails are lazy and cached; no thumbnail generation during normal editing.

### 15.3 Benchmark script

Add `tools/bench_prefabs.gd` (not CI) that:

- Creates a synthetic source with N cells and a few lights.
- Places 500 instances on a grid with no overlap.
- Measures place, move, rotate, delete, undo, raycast, chunk rebuild, save, and load times.
- Reports composed cell count, instance light count, and memory estimates.
- Uses `Time.get_ticks_msec()` and prints a table.

Suggested v1 budgets (desktop, debug build):

- Place a 1k-cell asset: < 100 ms including chunk rebuild for visible columns.
- Move a 1k-cell asset: < 150 ms.
- Raycast composed scene: < 5 ms.
- Save a 500-instance parent: < 2 s.
- Open a 500-instance parent (sources cached on disk): < 5 s.
- Idle frame time unaffected by off-screen instances.

If these are missed, the first fallback is to defer chunk rebuilds (existing `CHUNK_COOLDOWN`) and
the second is to reduce the ghost/selection detail, not to change semantics.

Measured on the development machine (Godot 4.7.2 debug, `godot --headless --path . -s
tools/bench_prefabs.gd`, 500 instances × 2000 cells = 1M composed cells, 1000 instance lights):

| Operation | Time |
| --- | --- |
| Place 500 instances | ~3.0 s total (~6 ms each) |
| Move / rotate one instance | 5–7 ms |
| Delete + undo one instance | ~9 ms |
| Composed raycast | < 1 ms |
| Rebuild one dense 64×64 chunk mesh | ~95 ms |
| Full composition rebuild | ~2.0 s |
| Refresh 500 sources (one disk read each) | ~2.1 s |
| Save the parent (references only) | ~10 ms |
| Open the parent (fresh sources) | ~2.1 s |

The v1 budgets hold. Placement cost is dominated by copying the 2000 transformed cells into the
column indices per instance; the editor avoids it per frame by caching ghost validation and by
rebuilding only dirty chunks.

---

## 16. Tests

All existing suites must keep passing. Add coverage in the existing files; keep them headless.

### 16.1 `voxel_document_test.gd`

Transform and composition:

- Default pivot for 1×1, 2×2, 3×3, and asymmetric assets.
- Each yaw 0–3 maps a known asymmetric cell set exactly; no duplicates, no gaps.
- Pivot must be a multiple of 0.5; invalid pivots are rejected.
- Light transform: position rotates around the pivot; range/color/energy/shadows preserved.
- Anchor translation is exact and independent of rotation.

Placement and editing:

- Place a valid instance; cells/lights appear in the composition.
- Overlap with local voxels is refused; document unchanged.
- Overlap with another instance is refused; document unchanged.
- Out-of-bounds cell or light is refused; document unchanged.
- Move to a free anchor succeeds; move onto a voxel/instance fails and keeps the old anchor.
- Rotate in place when valid; rotate into an obstacle fails and keeps the old yaw.
- Duplicate creates a new ID and one undo step.
- Delete removes cells/lights; undo restores.
- Every mutation is one undo step and redo replays it.
- `_is_legacy_history()` still recognizes old entries; prefab-only entries are not misread.

Unpack:

- Unpack converts cells to local voxels with the right colors and lights to parent lights with new
  IDs.
- One undo restores the instance and removes the unpacked content.
- Refuse unpack if `doc.lights.size() + instance_lights > 32`; nothing changes.
- Refuse unpack of missing/conflicted instances.
- Unpack into an occupied cell is refused (invariant test).

Bounds:

- Shrinking bounds that would cut a valid instance is refused.
- Shrinking bounds that would cut an instance light is refused.
- Missing/conflicted placeholders do not block a resize.
- Growing bounds works and does not clip.

Save/load:

- Save a parent + source in a temp dir; `source_path` is relative; `ResourceLoader.get_dependencies`
  includes the source.
- Reload reproduces cells, lights, pivot, anchor, yaw, and instance IDs.
- Old `.tres` without `prefab_instances` loads unchanged and resaves without adding prefab data
  (or with an empty array, depending on serializer behavior; test the chosen expectation).
- `FLAG_RELATIVE_PATHS` behavior for absolute paths; skip/relax only if the Phase 0 fallback is
  chosen and documented.
- Missing source: delete the file, load with abort disabled, instance retained with `missing`
  status, save, restore the file, reload resolves it.
- Source with prefab instances is rejected as a source and existing uses are `incompatible`.
- Source grows into overlap: refresh marks the instance `conflicted`, removes its cells/lights
  from composition, keeps the reference; moving it free clears the conflict.
- Refresh does not dirty the document or add undo history.

Catalogue:

- Scan a temp library with nested folders; only `.tres`/`.res` VoxelModels are included.
- Invalid files are listed with a reason, not crashed on.
- Default pivot is materialized; pivot edits persist in the manifest.
- Asset IDs are stable across rescans; a manifest-backed rename keeps the ID.
- Metadata cache invalidates on `mtime`/size change.
- No source files are modified by scanning or thumbnail caching.

### 16.2 `voxel_editor_test.gd`

- Catalogue dialog opens, lists assets, searches, filters by library, and arms placement.
- Headless thumbnail generation is skipped gracefully (placeholder, no crash).
- Chunk mesh contains instance cells; moving an instance dirties old and new columns; deleting
  clears them.
- Composed hover: Place on a prefab surface adds a local voxel in the adjacent empty cell.
- Paint/Erase/Fill on a linked cell is refused with the expected message.
- Pick on a linked cell samples its color.
- Prefab tool selects an instance, drags it to a free anchor, rotates with `R`, duplicates with
  `Ctrl+D`, deletes with `Delete`, and undo/redo works.
- Invalid drag release cancels and restores the old anchor.
- Status bar counts update; missing/conflict warnings appear.
- Save/reopen through the editor preserves instances and rebuilds chunks.
- Side panel Prefabs section opens the catalogue and shows selected instance details.

### 16.3 `voxel_editor_input_test.gd`

- `0` switches to the Prefab tool; `B` opens/closes the catalogue.
- `R`, `Ctrl+D`, `Delete` work only with the Prefab tool/selection and not while a text/spin field
  has focus.
- `Esc` cancels an armed asset, then clears selection.
- Drag move commits only on a valid release.
- `Ctrl+D` starts a duplicate ghost; placing it creates a new instance; `Esc` cancels.
- Existing navigation and tool shortcuts still pass.

### 16.4 `mcp_server_test.gd`

- Every new tool is present in `tools/list` and has a matching handler.
- `prefab_list_assets` finds a temp source; `prefab_place` places it; `prefab_list_instances`
  reflects it.
- Place overlap/out-of-bounds errors are specific and do not mutate the document.
- Move/rotate/duplicate/delete/unpack/relink/reload round-trip through MCP.
- `allow_over_budget=false` refuses a placement over the soft budget; `true` places it.
- `get_voxels` remains local-only; `get_composed_voxels` includes linked cells with owners.
- Save via MCP, reopen via MCP, verify instances and statuses.

### 16.5 Screenshot tool

Extend `tools/make_screenshots.gd` with an optional prefab shot:

- Build a small scene with a house and several linked trees/lamps.
- Open the catalogue dialog and capture it, or capture the composed scene with the Prefab tool
  selected.
- Remember the `_doc_replaced` ordering rule when assigning `doc.grid` directly.

---

## 17. Implementation phases

Estimates are for one developer familiar with the codebase; adjust after Phase 0.

### Phase 0 — Format spike (0.5–1 day)

Build a tiny throwaway scene/test that verifies:

1. `ResourceSaver.FLAG_RELATIVE_PATHS` writes a relative `ExtResource` for an absolute-path parent
   and source outside `res://`.
2. `ResourceLoader.set_abort_on_missing_resources(false)` loads a parent with a missing source,
   preserving the instance and `source_path`.
3. Saving that parent again preserves the unresolved instance.
4. `CACHE_MODE_IGNORE_DEEP` reloads a changed source without a stale reference.
5. `Array[VoxelPrefabInstance]` round-trips (or decide on the `Array[Resource]` fallback).
6. `ResourceLoader.get_dependencies(parent)` lists the source.
7. Saving a parent with a null `source` and a `source_path` works.

Deliverable: a short note in this file or a test script with the verified behavior and any
fallback decisions. Do not start the catalogue UI before this is settled.

### Phase 1 — Data model and composition (3–4 days)

- `VoxelPrefabInstance`.
- `VoxelPrefabComposition`: transforms, column index, overlap, bounds, lights, statuses.
- `VoxelModel` fields/helpers.
- `VoxelDocument` API, undo namespace, load/save, missing/conflict handling.
- Unit tests for transform, placement, move/rotate, undo, unpack, bounds, save/load, missing,
  conflict.
- Keep the editor rendering unchanged until the data layer is green.

### Phase 2 — Catalogue (3–4 days)

- `VoxelPrefabCatalog`: scan, manifest, IDs, metadata cache, pivot defaults/edits, refresh.
- `VoxelPrefabCatalogDialog`: layout, search, folders, grid, details, problems.
- Thumbnail generation/cache (display-only; headless fallback).
- Interactive preview and pivot picking.
- Placement request wiring to the editor (can be a stub until Phase 3).
- Tests for scanning/manifest and a UI smoke test.

### Phase 3 — Editor integration (3–5 days)

- Prefab tool, ghost, selection, drag/rotate/duplicate/delete/unpack.
- Composed raycast and hover; ordinary-tool refusal rules.
- Chunk composition and invalidation.
- Side panel section, status bar, shortcuts, focus gating.
- Editor/input tests.

### Phase 4 — Runtime, MCP, docs (2–3 days)

- `VoxelModel` composed mesh/lights; `VoxelModelInstance`; collision.
- MCP tools and parity tests.
- README/AGENTS updates, screenshots, benchmark.
- Performance pass and bug fixing.

Total: roughly **12–17 working days**, plus buffer for UI polish and platform testing.

---

## 18. Nice-to-haves (not required for v1)

- `Unpack all prefabs` (one undo step), with the 32-light check. Useful for making a composed
  model reusable as a source.
- Swap asset on an existing instance while preserving pivot/yaw and validating overlap.
- Numeric transform inspector for the selected instance.
- Recent/favorite assets and tags.
- “Reveal in file manager” for a library.
- Manual thumbnail override (PNG sidecar).
- Per-instance light budget override flag.
- Drag-and-drop a `.tres` onto the viewport to place it (outside the catalogue).
- Source revision pinning/versioned instances.

These should not complicate the core data model. Add them only after the v1 acceptance criteria
pass.

---

## 19. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `FLAG_RELATIVE_PATHS` does not work for absolute paths outside `res://`. | Phase 0 spike. Fallback: absolute native paths + relative `source_path` + relink; document the portability limit. |
| Godot drops the whole instance when an `ExtResource` is missing. | Phase 0 spike with `set_abort_on_missing_resources(false)`. Fallback: a plain-data `prefab_records` array in `VoxelModel` hydrated after load. |
| Typed `Array[VoxelPrefabInstance]` serialization fails. | Fallback to `Array[Resource]` + runtime validation. |
| 1M composed cells consume too much memory in dictionaries. | Column-bucketed indices; benchmark. If needed, store per-chunk packed arrays or a flat `PackedInt32Array` per column. |
| Moving/rotating a large instance causes a long chunk rebuild. | Only rebuild affected columns; existing `CHUNK_COOLDOWN` streaming; ghost fallback. |
| Source refresh creates conflicts that confuse users. | Explicit red wireframe, status counts, Problems tab, specific reasons, move/relink/delete actions. Never silently clip or overwrite. |
| Pivot edits move existing instances. | Snapshot pivot in the instance; catalogue edits affect future placements only; show a note. |
| Arbitrary pivot values break the voxel grid. | Constrain to 0.5; snap UI/MCP input; test all yaws. |
| Source edits change physical scale expectations. | Parent controls scale; source `voxel_size` ignored; document it in the catalogue details. |
| Instance lights explode rendering cost. | Soft budget with explicit override; runtime warning; benchmark. |
| Unpack exceeds the 32-light limit. | Pre-check the whole unpack; refuse atomically; no partial content. |
| Undo history memory grows with instances. | Store scalar snapshots, not cell arrays; recompute transforms; cap history at 200 as today. |
| Catalogue scan of 500 assets is slow. | Manifest metadata cache by `mtime`/size; lazy thumbnails; scan on demand, not every frame. |
| Headless CI has no display for thumbnails. | Skip generation; placeholder; test the cache/manifest logic only. |
| Save As changes relative paths. | Recompute `source_path` on every save; test moving parent+`Prefabs` together. |
| Two instances with the same asset ID but different files. | Asset ID is a hint; native ref/path wins; prompt if the ID lookup is ambiguous. |
| A conflicted instance is saved and reopened. | Recompute conflicts on open; never drop the reference; show the same red placeholder. |

---

## 20. Acceptance criteria

V1 is done when all of these work on Linux (and the build still runs on macOS/Windows):

1. Save `tree.tres` into `~/Documents/Voxdot/Prefabs`; open `castle.tres`; the catalogue (`B`)
   shows the tree with a rendered thumbnail, dimensions, and a pivot.
2. Place ten trees in `castle.tres`. Each is one atomic instance; no overlap is allowed; the ghost
   turns red over occupied cells and refuses the click.
3. Edit `tree.tres`, save it, and reopen `castle.tres`: all ten update. With `castle.tres` still
   open, `Reload prefabs` updates them without dirtying the parent.
4. Move, rotate (`R`), duplicate (`Ctrl+D`), and delete (`Delete`) instances; undo/redo each
   action; save and reopen preserves transforms and IDs.
5. Unpack one tree: its voxels and lights become ordinary editable parent content; one undo
   restores the instance and removes the content. If the parent light limit would be exceeded,
   unpack is refused and nothing changes.
6. Delete `tree.tres` and reopen: the trees appear as red wireframe placeholders with a missing
   status; relink to a copy restores them. Saving while missing preserves the instances.
7. Grow `tree.tres` so it overlaps a wall; `Reload prefabs` marks the affected instances
   conflicted, omits their solid mesh/lights, and shows red wireframes. Moving them to free space
   resolves the conflict.
8. Paint/Erase/Fill on a linked cell refuses with `Linked prefab: unpack to edit`. Place builds a
   local voxel on a prefab surface. Pick samples a prefab color.
9. Copy `castle.tres` alone to another folder: missing placeholders (intentional). Copy it with
   `Prefabs/` preserving relative paths: it works.
10. A game scene with `VoxelModelInstance` renders the composed voxels, transformed instance
    lights, and optional collision; scaling uses the parent `voxel_size` only.
11. ~500 instances / ~1M composed cells remain interactive; the benchmark numbers are recorded.
12. MCP can list assets, place, list/move/rotate/duplicate/delete/unpack/relink/reload, and report
    statuses; every tool has an end-to-end test.
13. All existing test suites pass; old `.tres` files without prefabs load and render unchanged.
14. README documents the library layout, linked-instance behavior, external-dependency warning,
    no-nesting rule, shortcuts, runtime usage, and MCP tools.

---

## 21. README and AGENTS updates

README additions:

- “Prefabs” section with the library layout:
  ```text
  ~/Documents/Voxdot/
    Prefabs/
      tree.tres
      props/lamp.tres
    castle.tres
  ```
- “A project can also have `<folder of castle.tres>/Prefabs/`.”
- How to create/place/unpack; the `B`, `0`, `R`, `Ctrl+D`, `Delete` shortcuts.
- Linked vs. unpacked; source refresh on open/manual reload.
- External dependencies warning and the “copy the folder” rule.
- No nesting; how to flatten (unpack all, if implemented).
- Transform rules (integer cells, 90° yaw, parent scale).
- Overlap and conflict behavior.
- Runtime `VoxelModelInstance` usage and shipping dependencies.
- MCP prefab tool list.

AGENTS.md learnings to add after implementation:

- The exact `FLAG_RELATIVE_PATHS` / missing-resource behavior verified in Phase 0.
- Typed-array serialization result.
- Prefab undo namespace and apply order.
- Column composition index and chunk invalidation.
- Pivot 0.5 constraint and yaw mapping.
- Catalogue manifest and thumbnail cache locations.
- Source refresh conflict behavior and why it is not undoable.
- Any Godot quirks found (e.g. resource cache modes, `set_abort_on_missing_resources`).

---

## 22. Open questions for Phase 0

These are the only unresolved implementation details. They do not change the product decisions.

1. Does `ResourceSaver.FLAG_RELATIVE_PATHS` produce portable relative `ExtResource` paths for
   parents/sources outside `res://`? If not, is the absolute-path fallback acceptable, or should
   Voxdot maintain its own dependency table?
2. Does `set_abort_on_missing_resources(false)` preserve the parent and the instance resource with
   `source == null`, or does Godot still drop the property?
3. Does `CACHE_MODE_IGNORE_DEEP` reliably refresh a source that changed on disk while the old
   resource is still referenced by an open document?
4. Does `Array[VoxelPrefabInstance]` round-trip in `.tres` and `.res`?
5. Does saving a parent with a null `source` rewrite the `ExtResource` as `null`, and does the
   fallback `source_path` survive?
6. Do relative paths work across Windows drive letters? If not, the UI must warn and relink.

Resolve these before writing the catalogue UI. Everything else in this plan is ready to implement.

