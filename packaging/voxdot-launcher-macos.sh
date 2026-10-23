#!/usr/bin/env bash
# Voxdot launcher. Godot treats bare arguments as scenes to run, so file
# arguments must come after `--`; this wrapper adds it. Lives in Contents/MacOS,
# so the .pck sits in ../Resources.
dir="$(cd "$(dirname "$0")" && pwd)"
exec "$dir/voxdot-runtime" --main-pack "$dir/../Resources/voxdot.pck" -- "$@"
