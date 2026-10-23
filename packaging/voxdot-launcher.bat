@echo off
rem Voxdot launcher. Godot treats bare arguments as scenes to run, so file
rem arguments must come after `--`; this wrapper adds it.
"%~dp0voxdot-runtime.exe" --main-pack "%~dp0voxdot.pck" -- %*
