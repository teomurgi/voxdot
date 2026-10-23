#!/usr/bin/env bash
# Dev install: adds an app-launcher entry that runs the Linux build straight
# from this checkout (dist/voxdot-linux-x86_64/voxdot), so rebuilding with
# ./build.sh linux is all it takes to update what the menu launches. Unlike
# install.sh, nothing is copied out of the repo.
set -euo pipefail
cd "$(dirname "$0")"
repo="$(pwd)"
build="$repo/dist/voxdot-linux-x86_64/voxdot"

if [ ! -x "$build" ]; then
	./build.sh linux
fi

apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$apps"
cat > "$apps/voxdot-dev.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Voxdot (dev)
Comment=Voxel model editor (dev build from $repo)
Exec=$build %f
Icon=$repo/icon.svg
Terminal=false
Categories=Graphics;3DGraphics;
StartupWMClass=Voxdot
EOF
update-desktop-database "$apps" 2>/dev/null || true
echo "Installed 'Voxdot (dev)' launcher -> $build"
echo "After code changes, refresh it with: ./build.sh linux"
