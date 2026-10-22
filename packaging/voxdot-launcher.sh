#!/usr/bin/env bash
# Voxdot launcher. Godot treats bare arguments as scenes to run, so file
# arguments must come after `--`; this wrapper adds it. Symlink-safe.
dir="$(dirname "$(readlink -f "$0")")"
exec "$dir/voxdot-runtime" --main-pack "$dir/voxdot.pck" -- "$@"
