#!/usr/bin/env bash
# Installs Voxdot for the current user: ~/.local/share/voxdot, a `voxdot`
# command in ~/.local/bin, and an application-launcher entry + icon.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh linux

dir=dist/voxdot-linux-x86_64
prefix="${XDG_DATA_HOME:-$HOME/.local/share}"
bin="$HOME/.local/bin"
mkdir -p "$prefix/voxdot" "$bin" "$prefix/applications" "$prefix/icons/hicolor/scalable/apps"
install -m755 "$dir/voxdot" "$prefix/voxdot/voxdot"
install -m755 "$dir/voxdot-runtime" "$prefix/voxdot/voxdot-runtime"
install -m644 "$dir/voxdot.pck" "$prefix/voxdot/voxdot.pck"
install -m644 icon.svg "$prefix/icons/hicolor/scalable/apps/voxdot.svg"
ln -sf "$prefix/voxdot/voxdot" "$bin/voxdot"
sed "s|^Exec=.*|Exec=$prefix/voxdot/voxdot %f|" packaging/voxdot.desktop > "$prefix/applications/voxdot.desktop"
update-desktop-database "$prefix/applications" 2>/dev/null || true
echo "Installed. Run 'voxdot' or launch it from your app launcher."
