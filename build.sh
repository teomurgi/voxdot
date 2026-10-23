#!/usr/bin/env bash
# Builds self-contained Voxdot packages for Linux, Windows and macOS. No Godot
# export templates needed: each package is the official Godot runtime binary
# plus the shared .pck, with a launcher that adds the `--` Godot needs for
# file arguments.
#
#   dist/voxdot-<os>-x86_64.zip  (or .tar.gz for Linux)
#
# Runtime zips are downloaded once per version into dist/downloads/; delete
# that folder to force a fresh fetch. Requires curl, unzip, zip, tar.
set -euo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-godot}"
GODOT_BIN="$(command -v "$GODOT")"
GODOT_VER="$("$GODOT_BIN" --version | head -n1 | cut -d' ' -f1)"  # e.g. 4.7.2.stable.official.abc123
GODOT_FULL="$(echo "$GODOT_VER" | cut -d. -f1-3)"                 # 4.7.2
GODOT_TAG="$GODOT_FULL-stable"
DL_BASE="https://github.com/godotengine/godot/releases/download/$GODOT_TAG"
DL_DIR="dist/downloads"

PLATFORM="${1:-all}"
case "$PLATFORM" in
	linux|windows|macos|all) ;;
	*) echo "usage: ./build.sh [linux|windows|macos|all]" >&2; exit 1 ;;
esac

# Export the shared .pck once; it works with every platform's runtime.
rm -rf dist
mkdir -p dist "$DL_DIR"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
"$GODOT" --headless --path . --export-pack "Linux" dist/voxdot.pck

fetch_zip() { # name
	local name="$1"
	local file="$DL_DIR/$name.zip"
	if [ ! -f "$file" ]; then
		echo "Downloading Godot $GODOT_FULL runtime: $name" >&2
		curl -fSL "$DL_BASE/$name.zip" -o "$file"
	fi
	echo "$file"
}

build_linux() {
	local dir="dist/voxdot-linux-x86_64"
	mkdir -p "$dir"
	cp "$GODOT_BIN" "$dir/voxdot-runtime"
	cp dist/voxdot.pck "$dir/voxdot.pck"
	install -m755 packaging/voxdot-launcher.sh "$dir/voxdot"
	chmod +x "$dir/voxdot-runtime"
	tar -czf "$dir.tar.gz" -C dist "$(basename "$dir")"
}

build_windows() {
	local dir="dist/voxdot-windows-x86_64"
	local zip; zip="$(fetch_zip "Godot_v${GODOT_TAG}_win64.exe")"
	mkdir -p "$dir"
	unzip -o -q "$zip" "Godot_v${GODOT_TAG}_win64.exe" -d "$dir"
	mv "$dir/Godot_v${GODOT_TAG}_win64.exe" "$dir/voxdot-runtime.exe"
	cp dist/voxdot.pck "$dir/voxdot.pck"
	install -m755 packaging/voxdot-launcher.bat "$dir/voxdot.bat"
	(cd dist && zip -q -r "$(basename "$dir").zip" "$(basename "$dir")")
}

build_macos() {
	local dir="dist/voxdot-macos"
	local app="$dir/Voxdot.app/Contents"
	local zip; zip="$(fetch_zip "Godot_v${GODOT_TAG}_macos.universal")"
	mkdir -p "$app/MacOS" "$app/Resources"
	local tmp="dist/macos-tmp"
	rm -rf "$tmp"
	mkdir -p "$tmp"
	unzip -o -q "$zip" -d "$tmp"
	cp "$tmp/Godot.app/Contents/MacOS/Godot" "$app/MacOS/voxdot-runtime"
	rm -rf "$tmp"
	cp dist/voxdot.pck "$app/Resources/voxdot.pck"
	install -m755 packaging/voxdot-launcher-macos.sh "$app/MacOS/voxdot"
	sed -e "s/@VERSION@/$GODOT_FULL/" packaging/Info.plist > "$app/Info.plist"
	(cd dist && zip -q -r -y "$(basename "$dir").zip" "$(basename "$dir")")
}

case "$PLATFORM" in
	linux) build_linux ;;
	windows) build_windows ;;
	macos) build_macos ;;
	all) build_linux; build_windows; build_macos ;;
esac

echo "Built packages in $(pwd)/dist:"
ls -1 dist/*.zip dist/*.tar.gz 2>/dev/null || true
