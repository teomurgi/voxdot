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
- Verify with `godot --headless --path . --import` then the three scripts in `tests/` (see README). Rebuild with `./build.sh`.

## Learnings
1. **Packaging without export templates**: `godot --headless --path . --export-pack "Linux" dist/voxdot.pck` works with no
   templates installed (needs `export_presets.cfg`). The runtime is the system `godot` binary copied next to it.
2. **Bare CLI args are scenes**: `godot --main-pack x.pck castle.tres` fails with "Failed loading scene: res://castle.tres".
   File args must come after `--` (read via `OS.get_cmdline_user_args()`), so `dist/voxdot` is a launcher script that
   runs `voxdot-runtime --main-pack voxdot.pck -- "$@"`. Relative file args are resolved against `$PWD`.
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
   - Headless input tests: dummy window is 64x64 — set `root.content_scale_mode = DISABLED` and `root.size` *after* the first frames, give
     synthetic motion events a real `relative`, set `Input.use_accumulated_input = false`. Don't click "empty panel space" in tests (it can hit
     the `ColorPickerButton` and open a modal popup); click the title area `Vector2(100, 8)`.
   - Resizing bounds is refused if it would drop voxels; undo/redo skips out-of-bounds cells.
