# Voxdot

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Godot 4.7.2](https://img.shields.io/badge/godot-4.7.2-478cbf)](https://godotengine.org)
[![Tests](https://github.com/teomurgi/voxdot/actions/workflows/tests.yml/badge.svg)](https://github.com/teomurgi/voxdot/actions/workflows/tests.yml)

A standalone voxel model editor built on [Godot](https://godotengine.org) 4.7. Sculpt blocky voxel models, light them
with a directional sun and point lights, save them as Godot `.tres` resources, and drop them into any Godot game.

![Voxdot editing a voxel castle](docs/screenshots/01-editor.png)

## Run

```bash
./run.sh                 # from source, with the system `godot`
./run.sh castle.tres     # ...opening a model

./build.sh               # builds for all platforms -> dist/*.zip, dist/*.tar.gz
./build.sh linux         # just Linux
dist/voxdot-linux-x86_64/voxdot castle.tres

./install.sh             # build Linux + install for your user: `voxdot` command, launcher entry, icon
```

`build.sh` needs no Godot export templates. It exports the app data once
(`voxdot.pck`), then downloads the official Godot runtimes for Windows and
macOS (cached in `dist/downloads/`) and pairs each with the `.pck` and a small
launcher. The Linux build uses the system's Godot runtime. Unzip anywhere and
run: `voxdot` (Linux), `voxdot.bat` (Windows), or `Voxdot.app` (macOS — first
launch may need right-click → Open since the app is unsigned). You can also
drag a `.tres` onto the window to open it.

## Controls

| | |
|---|---|
| Tools `1`-`9` | Place, Erase, Paint, Pick, Box, Box Erase, Fill, Light, Edit Light |
| Orbit / pan / zoom | MMB or RMB / Shift+MMB / wheel |
| Fly through the scene | hold `W` `A` `S` `D` relative to the view; `Space` / `C` for up / down; hold `Shift` to move faster |
| Screenshot… | View-section button saves a PNG without the HUD, grid, bounds, or editing overlays |
| `Q` `E` | rotate view 90 degrees |
| `P` / `G` / `F` | ortho toggle / grid toggle / frame model |
| `H` | height lock: Place and Box target the plane at layer Y, so you can build in mid-air |
| `[` `]` (or PageDown/Up) | lower / raise the work layer (turns the lock on) |
| `X` `Z` | mirror across X / Z |
| Delete | remove the selected light |
| `Ctrl+Z`, `Ctrl+Shift+Z` / `Ctrl+Y` | undo / redo (one drag = one step) |
| `Ctrl+N` `Ctrl+O` `Ctrl+S` (`+Shift` = Save As) | new / open / save |

## MCP server (agent control)

Voxdot embeds an [MCP](https://modelcontextprotocol.io) server so an agent can drive every user-visible action
while you watch it happen in the window. It is off by default; enable it with a port:

```bash
VOXDOT_MCP_PORT=7850 ./run.sh            # from source
VOXDOT_MCP_PORT=7850 dist/voxdot          # a build
```

That serves JSON-RPC 2.0 over HTTP on `http://127.0.0.1:7850/` (methods `initialize`, `tools/list`, `tools/call`).
Every tool mirrors a UI action, so the window shows the tool switch, ghost preview, camera move, and status line
as the agent works. Highlights: `set_tool`, `set_color`, `place`/`erase`/`paint`/`fill`, `place_box`,
`begin_stroke`/`update_stroke`/`end_stroke` (a drag, as one undo step), `undo`/`redo`, `open`/`save`,
`set_mirror`/`set_height_lock`/`set_bounds`, `set_camera`/`orbit`/`pan`/`zoom`/`frame`, `set_render_horizon`,
lighting control (`add_light`/`update_light`/`remove_light`/`get_lights`/`select_light`/`set_light_handles`,
`set_sun`), plus `get_state`, `get_voxels` and `screenshot` so the agent can read back and *see* the result.
`GET /health` returns a status blob. Example:

```bash
curl -s -X POST http://127.0.0.1:7850/ -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
  "params":{"name":"place_box","arguments":{"from":[4,0,4],"to":[7,3,7],"color":"e03a3a"}}}'
```

Tests: `VOXDOT_MCP_PORT=7851 godot --headless --path . -s tests/mcp_server_test.gd`.

Box depth extrudes Box / Box Erase. Model size (up to 1024 per axis) and real-world voxel size are in the panel.
Shrinking the size is refused if voxels would be cut off. Files default to `~/Documents/Voxdot`.
The panel sections (File, Model, Tool, Color, Sun, Lighting, View) are collapsible — click a section header to fold
it away; Model and point lights start folded so the common controls fit without scrolling.

## Lighting

Every model carries its own scene mood, so a lit scene reopens exactly as you left it:

- **Sun** (Sun section) — one directional light with energy, yaw/pitch, color, and a shadow toggle.
- **Point lights** (Lighting section, tools `8` Light / `9` Edit Light) — up to 32 lights with position, color,
  energy, radius, and shadows. Drag a light's handle to move it, `Delete` removes the selected one, `<`/`>` cycle.

Both live in the `.tres` (`VoxelModel.lights` plus the `sun_*` fields) and are available over MCP
(`add_light`, `update_light`, `set_sun`, …). Point-light edits are undoable; sun settings are scene-wide and save
with the model like the mirror flags.

**Render horizon** (View section) caps how much of a big model gets meshed: only chunks within that horizontal
distance of the camera are rendered, and it follows the camera as you fly. Raising it reveals *farther* parts;
`0` renders everything. The full grid is always kept and saved, so this is purely a display setting.

## Screenshots

**Lighting** — a dusk sun plus four warm point lights, authored in the Sun/Lighting sections and saved with the
model. The selected light's position, energy, radius, color, and shadow toggle are in the panel.

![Point lights and a dusk sun in the editor](docs/screenshots/04-lighting.png)

**Box tool** — drag a rectangle and the ghost shows exactly the block that will be placed, extruded to the
depth you set.

![The Box tool previewing an extrusion](docs/screenshots/03-box-tool.png)

**Height lock** — with the lock on, Place and Box land on the golden work plane, so you can build a floor or a
bridge at an exact layer without stacking voxels up to reach it.

![Height lock building at an exact layer](docs/screenshots/02-height-lock.png)

The screenshots are generated by `tools/make_screenshots.gd`, which drives the editor scene and saves the
rendered frames:

```bash
godot --path . -s tools/make_screenshots.gd
```

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

Models can also store point lights (`VoxelModel.lights`, packed) and a directional sun (`sun_energy`,
`sun_yaw`, `sun_pitch`, `sun_color`, `sun_shadows`) so lit scenes reopen exactly as authored.
`VoxelModelInstance` rebuilds the lights as `OmniLight3D`s scaled to `voxel_size`; the sun is applied by
the voxdot editor — runtime scenes use their own lighting. Old models without these fields load unchanged.

## Tests

```bash
godot --headless --path . --import
godot --headless --path . -s tests/voxel_document_test.gd      # data layer
godot --headless --path . -s tests/voxel_editor_test.gd        # tools, standalone behaviour
godot --headless --path . -s tests/voxel_editor_input_test.gd  # real input events
VOXDOT_MCP_PORT=7851 godot --headless --path . -s tests/mcp_server_test.gd  # MCP server over HTTP
```

## Layout

```
scripts/editor/   VoxelDocument (edits, undo, IO), VoxelModel (resource), VoxelRaycast, VoxelModelEditor (UI, tools), VoxelMeshBuilder
scripts/runtime/  VoxelModelInstance (drop-in node for games)
scenes/voxdot.tscn   main scene
packaging/        launcher scripts (Linux/Windows/macOS), .desktop file, Info.plist
```

## Contributing

Bug reports and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first: it covers the
code layout, the style rules, how to add a tool, and the one file you must not move
(`scripts/editor/voxel_model.gd`, because saved models reference it by path).

## License

MIT — see [LICENSE](LICENSE). The `VoxelModel` format is intentionally simple and stable so that models
saved here stay loadable in other Godot projects.

