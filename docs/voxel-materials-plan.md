# Voxel materials & metadata

Status: v1 implemented. This document records the agreed design and the follow-up
ideas that were deliberately left out of v1.

## Goal

Give every voxel enough metadata to answer, automatically:

- Is it solid (does it contribute collision)?
- Is it walkable (can a character stand on its top surface)?
- What material is it made of (tags such as stone/wood/liquid)?

Authors should not have to tag every voxel by hand: assigning a material is enough,
with optional per-voxel overrides for exceptions.

## Decisions

- **Material + overrides.** A voxel references a material; the material defines the
  base solid/walkable flags. Per-voxel overrides can force solid or walkable on/off.
- **Built-in presets in v1.** Default, Stone, Dirt, Grass, Wood, Leaves, Water,
  Glass, Metal. Custom material definitions are a follow-up.
- **Material tool + palette.** Place uses the active material; the Material tool
  repaints existing voxels; Pick samples color + material + overrides.
- **Derived walkable surfaces.** A walkable surface is a solid, walkable voxel whose
  cell above is not solid. Steps and ramps are represented by adjacent surface cells;
  the game's navigation system decides whether a height change is traversable.

## Materials

| ID | Base solid | Base walkable | Tags |
|---|---|---|---|
| default | yes | yes | generic |
| stone | yes | yes | stone, mineral |
| dirt | yes | yes | soil |
| grass | yes | yes | soil, foliage |
| wood | yes | yes | wood, organic |
| leaves | yes | no | foliage, organic |
| water | no | no | liquid |
| glass | yes | yes | glass |
| metal | yes | yes | metal, mineral |

Numeric IDs are stable and are what the byte arrays store. Display names and
`kind_from_id()` accept case-insensitive names for tooling.

## Model format

The four-int `cells` record stays unchanged. Two optional byte arrays are aligned
with the sorted cell order:

- `material_ids`: `VoxelMaterial.Kind` per voxel.
- `material_overrides`: packed solid/walkable override bits per voxel.

Both arrays are omitted when every voxel is default/inherit, so old color-only
`.tres` files load unchanged and new default models do not grow. Override bit layout:

```text
bits 0-1: solid   (0 inherit, 1 force solid, 2 force non-solid)
bits 2-3: walkable (0 inherit, 1 force walkable, 2 force not walkable)
```

`VoxelDocument` keeps sparse `cell_materials` / `cell_overrides` dictionaries
(only non-default entries), so a 1M-voxel default model pays nothing in memory.
Color paint preserves metadata; erase clears it.

## Editor

- Left-panel **Material** section with a nine-button palette, effective state text,
  and Solid/Walkable override dropdowns.
- Tool `M` = Material: click/drag existing voxels to apply the active material and
  overrides. Place and Box Place use the active material.
- Pick samples color, material and overrides.
- Selecting a material also updates the active color when the previous color was the
  previous material's default; custom colors are left alone.
- Material edits are non-undoable only at the palette level; voxel material changes
  live in the separate `"materials"` undo namespace.

## Prefabs

A source model carries its own material arrays. Runtime composition transforms source
cells and their material/override metadata into the parent; local cells and earlier
instances win, matching the color composition rule. Unpack copies source material
metadata into the parent's local voxels. Built-in IDs are global, so no material
merging is needed in v1.

## Runtime API

`VoxelModel`:

- `build_composed_data()` -> `{colors, materials, overrides}`.
- `is_solid_cell(cell)` / `is_walkable_cell(cell)` (optional cached data argument).
- `build_solid_grid()` / `build_collision_mesh()`.
- `walkable_cells()` -> exposed top-surface cells.
- `material_kind_at(cell)` / `material_override_at(cell)`.

`VoxelModelInstance`:

- Render mesh still contains every voxel.
- Collision body is built from solid cells only.
- `is_solid_cell()`, `is_walkable_cell()`, `walkable_cells()` query the cached
  composed data; caches invalidate on `rebuild()`.

## MCP

- `list_materials`, `set_material`, `get_material`, `get_voxel`, `paint_material`.
- `place`, `place_box`, `place_voxels` accept an optional material and optional
  solid/walkable overrides.
- `get_state` reports the active material and effective flags.

## Follow-ups

- Custom/user-defined material definitions and a material library.
- Transparency for water/glass (rendering currently treats every material as opaque;
  solidity/walkability are unaffected).
- Collision layers/masks and friction per material.
- A generated nav grid with step/slope rules and traversal costs.
- Visual material indicators in the viewport and material-aware prefab catalogue
  thumbnails.
