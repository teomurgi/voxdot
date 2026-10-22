#!/usr/bin/env bash
# Builds a self-contained Voxdot into dist/. No Godot export templates needed.
#
#   dist/voxdot          launcher script (adds the `--` Godot needs for file args)
#   dist/voxdot-runtime  copy of the Godot runtime
#   dist/voxdot.pck      the app (scripts, scenes, icon)
#
# Copy or move the whole dist/ folder anywhere; it has no other dependencies
# than the system libraries Godot itself needs.
set -euo pipefail
cd "$(dirname "$0")"
GODOT="${GODOT:-godot}"
GODOT_BIN="$(command -v "$GODOT")"

rm -rf dist
mkdir -p dist
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
"$GODOT" --headless --path . --export-pack "Linux" dist/voxdot.pck
cp "$GODOT_BIN" dist/voxdot-runtime
install -m755 packaging/voxdot-launcher.sh dist/voxdot
chmod +x dist/voxdot-runtime
echo "Built: $(pwd)/dist/voxdot"
