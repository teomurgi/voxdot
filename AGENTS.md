# AGENTS.md — Voxdot

Standalone voxel model editor on **Godot 4.7.2** (system binary `/usr/bin/godot`). Origin: extracted from the
`rpg-forge` project (`../rpg-forge`), whose own copy of the editor is not kept in sync.

> **Rule:** when you learn something non-obvious (engine quirks, CLI behaviour, packaging), add it to
> "Learnings" below before finishing your turn.

## Layout & conventions
- Typed GDScript, tabs. Code layers: `VoxelDocument` (UI-free edits/undo/IO, unit tested) → `VoxelRaycast` →
  `VoxelModelEditor` (camera, tools, UI built in code; `scenes/voxdot.tscn` is just the script on a Node3D).
- `VoxelModel` must stay at `res://scripts/editor/voxel_model.gd` with `class_name VoxelModel`: saved `.tres` files
  reference that path, and `rpg-forge` (and any game) loads them by it. Keep its `.gd.uid` too.
- Verify with `godot --headless --path . --import` then the scripts in `tests/` (see README; the MCP one needs
  `VOXDOT_MCP_PORT=7851`). Rebuild with `./build.sh`.

## Learnings
1. **Packaging without export templates**: `godot --headless --path . --export-pack "Linux" dist/voxdot.pck` works with no
   templates installed (needs `export_presets.cfg`). The runtime is the system `godot` binary copied next to it for
   Linux; for Windows/macOS, `build.sh` downloads the official runtime zip from the Godot releases page and pairs
   it with the same `.pck`.
2. **Bare CLI args are scenes**: `godot --main-pack x.pck castle.tres` fails with "Failed loading scene: res://castle.tres".
   File args must come after `--` (read via `OS.get_cmdline_user_args()`), so each platform gets a launcher script:
   `voxdot` (shell) on Linux, `voxdot.bat` on Windows, `Contents/MacOS/voxdot` (shell) inside `Voxdot.app` on macOS.
   Relative file args are resolved against `$PWD`.
3. **Titles**: the system Godot is a debug-type build, so the window title gets " (DEBUG)" appended.
4. **Standalone file IO**: models live outside `res://`; `ResourceSaver`/`ResourceLoader` work with absolute paths (covered in
   `voxel_document_test.gd`). Default dir is `<Documents>/Voxdot`. Window close goes through `set_auto_accept_quit(false)` +
   `NOTIFICATION_WM_CLOSE_REQUEST` so unsaved work prompts first.
5. **Shell gotcha**: `pkill -f dist/voxdot` kills your own shell if the command line contains that text; use `pkill -x voxdot-runtime`.
6. **Editor/UI gotchas inherited from rpg-forge**:
   - Drag strokes lock to the first hit's face plane and intersect later rays with it; re-raycasting each frame stacks voxels toward the camera.
   - Gate clicks with `get_viewport().gui_get_hovered_control() != null` (root Control `MOUSE_FILTER_IGNORE`), handle press in
     `_unhandled_input`, detect release by polling `Input.is_mouse_button_pressed` in `_process`; call `gui_release_focus()` on viewport clicks.
   - Height lock: Place/Box intersect the ray with plane `y = work_layer` and ignore voxels.
   - Wheel events: a `ScrollContainer` at its top/bottom edge stops consuming the wheel, so it falls through to
     `_unhandled_input` and zooms the camera. Gate wheel handling on `gui_get_hovered_control() != null` (same
     gate as clicks). And `accept_event()` does not exist on Node — use `get_viewport().set_input_as_handled()`.
   - `_open_path` / MCP `open` must set `_doc_replaced = true` *before* calling `doc.load_file()`. The document emits
     `changed` during the load; the editor's handler only routes to `_on_doc_reset()` (which rebuilds chunk records)
     when the flag is already true. Setting it after the load leaves the mesh invisible until the next edit.
   - Render horizon: `0` means unlimited (`UNLIMITED_HORIZON` sentinel); the horizon is a **horizontal radius
     around the camera** — chunks whose center is farther are not meshed (the full grid is always kept and saved),
     so raising it reveals strictly farther parts. Measuring from the focus instead looked broken: with the camera
     outside the model, growing a focus-centred radius adds the model's near side (closer to the viewer) first.
     The meshed set follows the camera via `_update_horizon_chunks()` in `_process` (after `_update_camera()`);
     `set_render_horizon(0)` must re-mesh chunks a previous cap dropped, because `_update_horizon_chunks()` returns
     early when unlimited. UI spinbox and MCP both report 0 for "all"; never leak the raw sentinel value out.
     Chunk rebuilds use the `_chunk_cells` index (chunk key -> cells), never a full-grid scan.
   - Scene mood is a directional sun (energy/yaw/pitch/color/shadows) plus an atmospheric ambient fill
     (`atmosphere_enabled/energy/color`), stored in the model and applied via `_on_meta_changed` →
     `_apply_environment`. `ambient_energy` remains a legacy field but nothing reads it.
   - Headless input tests: dummy window is 64x64 — set `root.content_scale_mode = DISABLED` and `root.size` *after* the first frames, give
     synthetic motion events a real `relative`, set `Input.use_accumulated_input = false`. Don't click "empty panel space" in tests (it can hit
     the `ColorPickerButton` and open a modal popup); click the title area `Vector2(100, 8)`. Nodes added from a
     `SceneTree` test's `_initialize()` have not run `_ready()` yet: defer the test body and await a frame before using
     fields initialized there. For held-key tests, set `physical_keycode` too; setting only an event's `ctrl_pressed`
     flag does not update `Input.is_physical_key_pressed(KEY_CTRL)`, so synthesize the modifier key press itself. The dummy
     display also ignores `Input.warp_mouse()`: drive `_hover` directly and disable `_process` for deterministic hover fixtures.
   - Keyboard focus beats polling: `_update_navigation()` polls WASD/Space/C but bails while a `LineEdit`/`TextEdit` has
     focus, so editing any spin box left WASD dead. Only a *left* click released focus, so middle-dragging to orbit
     appeared to break navigation until the next left click. Release focus on every mouse press (and wheel) that reaches
     the viewport, not just LMB.
   - Side panels: `_side_panel(root, name, width, on_right)` builds a scrollable `PanelContainer` anchored to
     either edge. The left **ToolPanel** holds File, Model, Tool (tools + mirror), Color, View and Help (last);
     the right **ScenePanel** holds Sun, point lights and Prefabs. Sections come from
     `_section(parent, title, expanded)` which returns the body `VBoxContainer` to fill (the header is a flat
     toggle button with a ▼/▶ arrow). Model, point lights, Prefabs and Help start collapsed. Keybinding help
     lives in the left Help section, not as a viewport overlay. The right panel is 352 px wide because the
     light position row (three spins) needs ~311 px; narrower widths clip the Delete button. UI tests that
     focus a spin box should use a visible one — fields inside collapsed sections are not reliable focus fixtures.
   - Resizing bounds is refused if it would drop voxels; undo/redo skips out-of-bounds cells.
7. **Cross-platform shortcuts**: on macOS, Godot fires shortcuts with `meta_pressed` instead of `ctrl_pressed`. Use
   `k.command_or_control_autoremap` (or check both) so Ctrl works on Windows/Linux and Cmd works on macOS. Ignore
   raw `KEY_META` presses or macOS won't trigger shortcuts.
8. **Runtime download URLs**: official Godot binaries live at
   `https://github.com/godotengine/godot/releases/download/<version>-stable/Godot_v<version>-stable_<platform>.zip`.
   `build.sh` derives the tag from `godot --version` and caches zips in `dist/downloads/`.
9. **MCP server**: `scripts/editor/mcp_server.gd` is a raw `TCPServer` node added by `VoxelModelEditor` when
   `--mcp`/`VOXDOT_MCP_PORT` is set. It speaks JSON-RPC 2.0 over HTTP POST (no SSE). Gotchas learned the hard way:
   - A `PackedByteArray` stored in a `Dictionary` does not mutate in place: `dict[k].append_array(x)` silently
     drops the bytes. Copy to a local, append, write back.
   - `StreamPeerTCP` request parsing: read head + body by Content-Length from one buffer, and keep the leftover
     bytes for the next pipelined request.
   - Editor `_process` must not end a stroke just because LMB isn't held — API-driven strokes have no mouse. It
     only poll-releases once a real press was seen (`_stroke_mouse_driven`).
   - Headless has no viewport texture, so `screenshot` returns a clean error there.
   - MCP dispatch builds `Callable(self, "_tool_" + name)`: the `tools/list` schema and the handler functions
     live in the same file but are not checked against each other. A tool can be advertised while a matching
     `_tool_<name>` is missing — `tools/list` shows it, calls fail with "unknown tool". Verify new tools
     end-to-end; a running editor also keeps the old script until restarted.
10. **Lights & scene mood in the model format**: `VoxelModel.lights` packs each light as 10 floats (id, x, y, z,
    r, g, b, energy, range, shadows); positions/ranges are in voxel units and runtime instances scale them by
    `voxel_size`. Undo history entries are namespaced (`{"voxels", "lights"}`) — anything iterating raw undo
    entries must go through `_is_legacy_history`. Scene mood (`sun_*` and `atmosphere_*`) is saved in the
    same `.tres` but is not undoable (like mirror flags); the editor applies it via `_on_meta_changed`, so
    loads/restores come for free. `ambient_energy` is a legacy field and is not applied. Godot 4.7 has no `Geometry3D.ray_intersects_sphere` — ray–sphere picking in
    `voxel_light_rig.gd` is manual. Light drags lock to the camera-facing plane through the light (same rule as
    voxel strokes), so a drag target off that plane lands at the plane intersection.
11. **README screenshots**: `tools/make_screenshots.gd` drives the real editor in a `SubViewport` and writes
    `docs/screenshots/*.png` (run with `godot --path . -s tools/make_screenshots.gd`; it needs a display/Vulkan,
    not headless). Assigning `doc.grid` directly skips `last_touched`, so set `_doc_replaced = true` *before*
    emitting `changed` or the chunk renderer stays empty. Panels can be folded from the tool via the `▼/▶` header
    buttons, which is how the lighting shot makes room for the light inspector.
12. **Prefab storage**: `VoxelPrefabInstance` stores a native `source: VoxelModel` external reference plus
    `source_path`, a parent-relative fallback. `ResourceSaver.FLAG_RELATIVE_PATHS` only relativizes `res://`
    paths, so models outside the project keep absolute native refs and portability relies on `source_path`.
    Loading a parent whose source file is gone must use `ResourceLoader.set_abort_on_missing_resources(false)`
    (VoxelDocument and `VoxelModel.load_with_prefabs` do); the instance keeps `source == null` and survives a
    resave. `ResourceLoader.exists()` can return true for a cached resource after the file was deleted — use
    `FileAccess.file_exists` for absolute paths (`VoxelDocument._path_exists`).
13. **Prefab composition**: `VoxelDocument.prefab_instances` is authoritative; `prefab_composition` is a derived
    index that stores **world cells**. Conflict/missing/incompatible instances contribute no solid cells or
    lights but stay in the list so they can be moved out, relinked or deleted. Only `ok` instances are
    all-or-nothing on transform. Prefab undo lives in a `"prefabs"` namespace next to `"voxels"`/`"lights"`.
    `source_bounds` is the occupied-cell AABB snapshot (not the source's editable `bounds`) and drives red
    placeholders. No nesting: a source containing instances is refused.
14. **Prefab UI/tool**: `Tool.PREFAB` is appended (value 9) and `Tool.MATERIAL` after it (value 10) so
    shortcuts 1–9 keep their tools; the Prefab tool is on `0` and Material on `M`. Drags lock to the grabbed
    face plane (same rule as voxel strokes), *not* a camera-facing plane, or sideways drags sink the instance
    in Y. Switching to any non-Prefab tool clears `selected_prefab_id` and the selection outline (armed
    catalogue assets survive). A `Window` added to the tree is visible by default and swallows viewport input
    in headless tests — instantiate `VoxelPrefabCatalogDialog` hidden. Catalogue metadata is in
    `<library>/.voxdot/catalogue.cfg`; `VoxelPrefabCatalog.user_library_override` keeps tests out of the real
    `~/Documents/Voxdot/Prefabs`.
15. **Prefab lights & unpack**: instance lights render in a separate `PrefabLights` group owned by
    `VoxelPrefabRig`; parent lights stay in `doc.lights`. The soft budget (`prefab_light_budget`, default 64)
    only warns/asks for `allow_over_budget`; no light is dropped. Unpack writes voxels + lights atomically and
    refuses if `doc.lights.size() + instance_lights > 32` (the parent's hard limit). `VoxelModelInstance`
    composes linked cells/lights into its mesh and lights and skips unresolved sources with a warning.
16. **Pagoda example prefab**: `tools/build_pagoda_512.py` saves the first cherry tree as
    `<output dir>/Prefabs/cherry_tree.tres`, then places it as a linked instance at its original garden spot.
    The generator builds prefab cells in local space by offsetting `emit()` (pivot `(32, 0, 32)`); root-flare
    cells that dip below the garden surface are dropped because a prefab cannot have cells below `y=0` (and
    they are buried anyway). The script saves the prefab through MCP, starts a fresh 512³ parent, places the
    instance, saves, and copies the MCP screenshot next to the `.tres` as `<output>.png`.
17. **Catalogue library overlap**: if the open model's folder is the same as the user library
    (e.g. a model saved directly in `~/Documents/Voxdot`), `VoxelPrefabCatalog.libraries()` returns only the
    user library so the same folder is not scanned twice and assets do not appear duplicated.
18. **Open prefab source from catalogue**: double-clicking an asset button in the catalogue dialog launches
    a new Voxdot instance via `OS.create_instance`. In the editor, pass
    `["--path", ProjectSettings.globalize_path("res://"), "--", source_path]`. In a packaged build
    `globalize_path("res://")` is empty and `OS.get_cmdline_args()` does **not** expose the wrapper's
    `--main-pack`, so find the adjacent `voxdot.pck` (or `../Resources/voxdot.pck` on macOS) and pass
    `["--main-pack", pack, "--", source_path]`; verify with the packaged runtime, not just the editor.
    Use `get_viewport().set_input_as_handled()` (not `accept_event()`) inside a `gui_input` handler
    connected from a Button. Remember that bound arguments come *after* signal arguments:
    `button.gui_input.connect(_on_gui_input.bind(asset_id))` calls `_on_gui_input(event, asset_id)`,
    not `_on_gui_input(asset_id, event)`.
19. **Fit bounds to content**: `VoxelDocument.content_extent()` returns the smallest origin-anchored bounds that
    contain local voxels, valid prefab cells/lights and point lights; placeholders are excluded, matching
    `resize_bounds()`. `VoxelPrefabComposition.insert_candidate()` must also cache `_instance_bounds` and the
    `ok` status — otherwise `prefab_bounds()` is empty for freshly placed instances until a transform or reload.
20. **Sun shadows on large models**: `DirectionalLight3D.directional_shadow_max_distance` defaults to 100 m,
    so a 512³/1024³ model viewed from farther away shows no cast shadows even with `shadow_enabled = true`.
    `_apply_environment()` sets it to `min(max(100, bounds.length() * 1.5), camera.far)`; otherwise the
    "Sun casts shadows" toggle appears broken on the pagoda-scale examples.
21. **Voxel materials**: `VoxelMaterial` is a static registry of nine built-in IDs; `VoxelModel.material_ids`
    and `material_overrides` are optional byte arrays aligned with the sorted `cells` order (empty = all
    default/inherit, so old files load unchanged). `VoxelDocument` keeps sparse `cell_materials` /
    `cell_overrides` dictionaries and a separate `"materials"` undo namespace. `_write()` takes optional
    material/override values (`null` preserves them); color paint keeps metadata, erase clears it. Walkability
    is derived from solid + walkable materials with no solid cell above, not stored per voxel. Runtime
    collision uses `build_collision_mesh()` (solid cells only), and `VoxelModelInstance` caches composed cell
    data for `is_solid_cell()`/`is_walkable_cell()`/`walkable_cells()`.
22. **Prefab-first example scenes** (`tools/build_valley_512.py`): the parent holds ONLY terrain heightfield +
    water; every structure is a linked prefab source. Pads are terrain shaping done BEFORE emission
    (`RESERVES` consulted by `surface_h()`), so local writes stay heightfield-only. Prefab sources never
    contain cells below y=0 — anchors sit foundations ON pads instead of burying them. Corner-based sources
    (cabin/bridge) use pivot `(0,0,0)` plus a design `margin` shifted with `_ORIGIN` at build time and
    subtracted back in `place()` (yaw-0 only). Instance footprints must clear terrain: pads hug footprints
    with a 1-cell skirt, slope fill never rises above a reserved neighbour (`emit_terrain_band`), and pads
    must not overlap with different tops (`reserve_at` returns the first match — a lower yard pad overlapping
    a higher cabin pad buries the yard instance). All-or-nothing placement refuses any overlap, so validate
    footprints offline (local cells + pivot/yaw math) before the long MCP build. `open()` resets the editor
    camera, so builder scripts must re-apply hero framing (and wait for chunk rebuilds) after the reload check
    before capturing the shipped screenshot — otherwise the PNG is a black frame.
