# Voxdot

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Godot 4.7.2](https://img.shields.io/badge/godot-4.7.2-478cbf)](https://godotengine.org)
[![Tests](https://github.com/teomurgi/voxdot/actions/workflows/tests.yml/badge.svg)](https://github.com/teomurgi/voxdot/actions/workflows/tests.yml)

A standalone voxel model editor built on [Godot](https://godotengine.org) 4.7. Sculpt blocky voxel models,
save them as Godot `.tres` resources, and drop them into any Godot game.

## Run

```bash
./run.sh                 # from source, with the system `godot`
./run.sh castle.tres     # ...opening a model

./build.sh               # self-contained build -> dist/
dist/voxdot castle.tres

./install.sh             # build + install for your user: `voxdot` command, launcher entry, icon
```

`build.sh` needs no Godot export templates. `dist/` holds a launcher (`voxdot`), a copy of the Godot runtime
(`voxdot-runtime`, ~180 MB) and the app data (`voxdot.pck`). Move the folder anywhere. You can also drag a `.tres`
onto the window to open it. Linux/x86_64 only for now (it bundles whatever Godot your system has).

## Controls

| | |
|---|---|
| Tools `1`-`7` | Place, Erase, Paint, Pick, Box, Box Erase, Fill |
| Orbit / pan / zoom | MMB or RMB / Shift+MMB / wheel |
| `Q` `E` | rotate view 90 degrees |
| `P` / `G` / `F` | ortho toggle / grid toggle / frame model |
| `H` | height lock: Place and Box target the plane at layer Y, so you can build in mid-air |
| `[` `]` (or PageDown/Up) | lower / raise the work layer (turns the lock on) |
| `X` `Z` | mirror across X / Z |
| `Ctrl+Z`, `Ctrl+Shift+Z` / `Ctrl+Y` | undo / redo (one drag = one step) |
| `Ctrl+N` `Ctrl+O` `Ctrl+S` (`+Shift` = Save As) | new / open / save |

Box depth extrudes Box / Box Erase. Model size (up to 64 per axis) and real-world voxel size are in the panel.
Shrinking the size is refused if voxels would be cut off. Files default to `~/Documents/Voxdot`.

## Using models in a game

Copy these into your Godot project, keeping `voxel_model.gd` at **`res://scripts/editor/voxel_model.gd`**
(saved `.tres` files reference that path):

- `scripts/editor/voxel_model.gd`
- `scripts/editor/voxel_mesh_builder.gd`
- `scripts/runtime/voxel_model_instance.gd` (optional)

Then either add a `VoxelModelInstance` node and assign the model (optional trimesh collision), or in code:
`var mesh: ArrayMesh = (load("res://castle.tres") as VoxelModel).build_mesh()`. The mesh is scaled to the model's
`voxel_size` and uses vertex colors with the shared material from `VoxelMeshBuilder.get_material()`.
`VoxelModel.to_grid()` returns the raw `{Vector3i: Color}` grid.

## Tests

```bash
godot --headless --path . --import
godot --headless --path . -s tests/voxel_document_test.gd      # data layer
godot --headless --path . -s tests/voxel_editor_test.gd        # tools, standalone behaviour
godot --headless --path . -s tests/voxel_editor_input_test.gd  # real input events
```

## Layout

```
scripts/editor/   VoxelDocument (edits, undo, IO), VoxelModel (resource), VoxelRaycast, VoxelModelEditor (UI, tools), VoxelMeshBuilder
scripts/runtime/  VoxelModelInstance (drop-in node for games)
scenes/voxdot.tscn   main scene
packaging/        launcher script, .desktop file
```

## Contributing

Bug reports and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first: it covers the
code layout, the style rules, how to add a tool, and the one file you must not move
(`scripts/editor/voxel_model.gd`, because saved models reference it by path).

## License

MIT — see [LICENSE](LICENSE). The `VoxelModel` format is intentionally simple and stable so that models
saved here stay loadable in other Godot projects.

