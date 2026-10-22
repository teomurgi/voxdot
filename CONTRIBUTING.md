# Contributing to Voxdot

Thanks for helping out. Voxdot is a small, self-contained Godot app, so the
workflow is simple: get the app running, make a focused change, and make sure
the tests still pass.

## Getting set up

You need **Godot 4.7.2** (`godot --version`). Everything else is in the repo.

```bash
./run.sh                              # run the editor from source
./run.sh path/to/model.tres           # ...opening a model
godot --headless --path . --import    # import the project (needed once, and
                                      # after adding or renaming scripts)
```

`build.sh` and `install.sh` package the app; `install.sh` writes to your
`~/.local`, so you do not need to run it to contribute.

## Running the tests

All tests are headless scripts and print `PASS` or a list of failures:

```bash
godot --headless --path . -s tests/voxel_document_test.gd      # data layer
godot --headless --path . -s tests/voxel_editor_test.gd        # tools and standalone behaviour
godot --headless --path . -s tests/voxel_editor_input_test.gd  # real input events
```

Please run all three before opening a pull request. CI runs them on every
push and pull request.

## Code layout

The app is layered so that most changes stay in one place:

| File | Responsibility |
|---|---|
| `scripts/editor/voxel_document.gd` | The editing core: grid, strokes, undo/redo, mirror, flood fill, bounds, file IO. No UI. |
| `scripts/editor/voxel_raycast.gd` | DDA picking through the voxel grid. |
| `scripts/editor/voxel_model.gd` | The saved resource format. |
| `scripts/editor/voxel_model_editor.gd` | Camera, tools, ghost preview, UI. |
| `scripts/editor/voxel_mesh_builder.gd` | Grid to mesh conversion, shared with games. |
| `scripts/runtime/voxel_model_instance.gd` | Drop-in node for placing a saved model in a game. |

Two rules of thumb:

- **Keep the editing core UI-free.** Logic that does not need a screen belongs
  in `VoxelDocument`, where it can be unit tested headlessly.
- **Put new tools in `VoxelModelEditor`, but keep their grid operations in
  `VoxelDocument`.** A tool that only rearranges voxels is a few lines in the
  document and a few lines in the editor.

## Style

- Typed GDScript everywhere (`var x: int = 0`, typed returns and parameters).
- Tabs for indentation, one statement per line, no tabs-vs-spaces mix.
- Keep the existing naming style: `snake_case` for functions and variables,
  `PascalCase` for classes, `SCREAMING_SNAKE` for constants.
- Comment the *why*, not the *what*. The code already says what it does.
- No new dependencies. The app ships with Godot and nothing else.

## Adding a tool

1. Add the grid operation to `VoxelDocument` (e.g. `place_cells`, `paint_cells`,
   `flood_cells`) and make it emit `changed` so the mesh rebuilds.
2. Add the `Tool` enum entry, its name, its hint text and the branch in
   `_begin_stroke` / `_apply_cell` in `VoxelModelEditor`.
3. Add a button in the tool grid; the buttons are generated from `TOOL_NAMES`,
   so a new entry shows up automatically and can be bound to a number key.
4. Add a test in `tests/voxel_editor_test.gd`.

## Adding an undoable action

One user gesture should be one undo step. Wrap the edits in
`doc.begin_stroke()` / `doc.end_stroke()`; `VoxelDocument` records the net
change of every cell, so an action that adds and removes the same cell
correctly records nothing.

## Do not move `voxel_model.gd`

`scripts/editor/voxel_model.gd` must stay at that exact path. Every `.tres`
model saved by Voxdot hard-references `res://scripts/editor/voxel_model.gd`,
so renaming or moving the file silently breaks loading every model that was
ever saved. `tests/voxel_document_test.gd` and the format guard in the RPG
Forge project check this.

If the format itself needs to change, keep `class_name VoxelModel` and the
path, and add a migration in `VoxelModel.set_grid()` so older files still
load.

## Commit and pull request style

- One logical change per commit.
- Subject line in the imperative mood, under 72 characters.
- Body as a short bullet list describing what changed and why.
- Reference the issue or feature in the body when there is one.
- Open a pull request against `main` and describe the user-visible change.

## Reporting bugs

Include your Godot version (`godot --version`), your OS, what you did, what
happened, and what you expected. A `.tres` model that reproduces the problem
is the most useful thing you can attach.

## License

Voxdot is MIT licensed (see [LICENSE](LICENSE)). By contributing you agree
that your contributions are licensed under the same terms.
