## Context

> Historical plan (character feature removed): character/rig/slot-model/attack notes below describe
> pre-removal context, not current behavior.
Add flipbook (voxel frame) animation to voxdot: each frame is a full voxel set with per-frame timing and once/loop/ping-pong repetition. Whole-model frames (recommended, user-chosen) + duplicate-frame editing (user-chosen).
## Approach
1. `VoxelModel`: add `anim_frame_cells: Array[PackedInt32Array]` (same packed xyz+palette-index layout as `cells`, one entry per extra frame; frame 0 is the base `cells`), `anim_frame_palettes: Array[PackedColorArray]` (per-frame palette — shared palette is a later size optimization), `anim_frame_materials: Array[PackedByteArray]` + `anim_frame_overrides: Array[PackedByteArray]` (aligned with each frame's cells, empty = default/inherit), `anim_frame_times: PackedFloat32Array` (seconds per frame), `anim_mode: int` (0=once, 1=loop, 2=ping-pong). Reuses `set_cells`/`to_grid` per frame for sorted stable saves and material support. All empty/zero by default: old files load unchanged, static models pay nothing.
2. `VoxelDocument`: add `frames: Array[Dictionary]` (grid+materials+overrides per frame, frame 0 mirrors `grid`/`cell_materials`/`cell_overrides`), `frame_times: Array[float]`, `anim_mode: int`, `current_frame: int`. All existing edit paths (`place_cells`, `erase_cells`, `_write`, strokes, undo namespaces) keep operating on frame 0's live dicts untouched; frame switching swaps which stored dict the live `grid` refs point at (no geometry rewrite, no undo for the switch itself).
3. Frame ops on the document: `add_frame_from_current()` (duplicate), `delete_frame(i)`, `set_frame_time(i, secs)`, `set_anim_mode(m)`, `goto_frame(i)` (swap live refs, emit `changed`). Frame content edits are normal strokes (undo works per frame); add/delete/reorder are meta ops (saved, not undoable — like mirror flags). Undo-safety rule: stroke history entries are bare Vector3i records with no frame tag, so `goto_frame(i)` clears the undo/redo stacks (same as `load_model`'s reset). Alternative (per-frame stacks) rejected: unbounded memory and cross-frame redo semantics nobody asked for; clearing matches the existing load/new-document precedent.
4. Playback: new `VoxelFlipbookPlayer` node (child of editor, like `prefab_rig`): `play()`/`stop()`/`tick(delta)` advances `current_frame` per timing x mode and calls `doc.goto_frame()`. Visible transport lives in a left-panel "Animation" section: frame strip (prev/next/add/delete/duplicate), per-frame time spin, mode `OptionButton`, play/stop.
5. `to_model`/`load_model`/`new_document`: persist frames/times/mode; `set_cells` round-trips the base frame; empty frames array = static (no migration).
6. MCP: `anim_get_state`, `anim_add_frame`, `anim_delete_frame`, `anim_set_frame`, `anim_set_frame_time`, `anim_set_mode`, `anim_play`, `anim_stop` — same `_tool_` + schema pattern as the other editor tools.
## Critical files & anchors
- `scripts/editor/voxel_model.gd:22-28,89-123` — packed cell layout + `set_cells` to reuse per frame.
- `scripts/editor/voxel_document.gd:53-60,96-97,161-206,233-254` — live grid dicts, stroke/undo namespaces (frame 0 path untouched; switch swaps refs).
- `scripts/editor/voxel_model_editor.gd` — left-panel sections (`_section`), `_set_tool` patterns; new transport section follows `_build_material_ui` shape.
- `scripts/editor/mcp_server.gd` — `_define_tools` schema + `_tool_` dispatch (learning 9: schema entry required, not just handler).
## Verification
- `godot --headless --path . --import`, then `voxel_document`, `voxel_editor`, `mcp_server_test` suites.
- New: save a 3-frame model (distinct cells/frame, 0.2s each, ping-pong) → reload → same frames/times/mode; `anim_play` advances `current_frame` 0→1→2→1…; duplicate-frame edit isolation (paint frame 1, frame 0 unchanged); MCP round-trip.
## Assumptions & contingencies
- Lights/sun stay model-global (not per-frame) — per-frame lights would multiply the 32-light cap UI; refuse later if asked.
- (Historical — character feature removed; slot models/rig previews no longer exist.) The plan originally noted: character slot models with frames would rebuild the slot mesh on frame change; headless animation capture would use the same rig-visible technique as the villager shots; flipbook transport would live in the left-panel "Animation" section while rig previews stayed in the right-panel Character section with one clock at a time and a combined status bar.
- Stroke guard: `goto_frame()` during an active stroke would snap painted cells into another frame and corrupt stroke records. Single `editor._anim_playing` guard: `_begin_stroke` refuses while playing, playback refuses/toggles off while `_stroking`. MCP `anim_play` honors the same guard.
