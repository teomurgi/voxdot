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
   - Scene mood is one directional sun (energy/yaw/pitch/color/shadows) stored in the model and applied via
     `_on_meta_changed` → `_apply_environment`; there is no ambient-fill control anymore (a small constant
     ambient floor of 0.08 stays in `_build_world`). `ambient_energy` remains in the format as a legacy field
     but nothing reads it.
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
   - Side panel: sections come from `_section(parent, title, expanded)` which returns the body `VBoxContainer` to fill
     (the header is a flat toggle button with a ▼/▶ arrow). File is first, then Model, Tool (tools + mirror), Color,
     Sun, point lights, View; Model and point lights start collapsed. UI tests that focus a spin box should use a
     visible one — fields inside collapsed sections are not reliable focus fixtures.
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
    entries must go through `_is_legacy_history`. Scene mood (`sun_energy`, `ambient_energy`) is saved in the
    same `.tres` but is not undoable (like mirror flags); the editor applies it via `_on_meta_changed`, so
    loads/restores come for free. Godot 4.7 has no `Geometry3D.ray_intersects_sphere` — ray–sphere picking in
    `voxel_light_rig.gd` is manual. Light drags lock to the camera-facing plane through the light (same rule as
    voxel strokes), so a drag target off that plane lands at the plane intersection.
11. **README screenshots**: `tools/make_screenshots.gd` drives the real editor in a `SubViewport` and writes
    `docs/screenshots/*.png` (run with `godot --path . -s tools/make_screenshots.gd`; it needs a display/Vulkan,
    not headless). Assigning `doc.grid` directly skips `last_touched`, so set `_doc_replaced = true` *before*
    emitting `changed` or the chunk renderer stays empty. Panels can be folded from the tool via the `▼/▶` header
    buttons, which is how the lighting shot makes room for the light inspector.
