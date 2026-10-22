#!/usr/bin/env bash
# Run Voxdot from source with the system Godot. Pass a model to open: ./run.sh my.tres
set -euo pipefail
orig="$PWD"
cd "$(dirname "$0")"
args=()
for a in "$@"; do
	case "$a" in
		/*) args+=("$a") ;;
		*) args+=("$orig/$a") ;;
	esac
done
exec "${GODOT:-godot}" --path . -- "${args[@]}"
