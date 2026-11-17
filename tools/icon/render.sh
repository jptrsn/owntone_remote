#!/usr/bin/env bash
#
# render.sh — Render the launcher-icon assets from the SVG sources.
#
# The SVGs live in Inkscape on the user's 108dp adaptive-icon grid, so the
# generated PNGs are build-time artifacts, committed so CI and other
# machines never need Inkscape. Re-run this after editing the SVG sources,
# then `dart run flutter_launcher_icons`.
#
# --export-background paints the canvas because rect6 sits at y=-0.84375
# (an Inkscape-grid nudge) and would otherwise leave a ~4 px transparent
# strip at the bottom edge; #0F172A is the gradient's bottom stop.

set -euo pipefail
cd "$(dirname "$0")"

command -v inkscape &>/dev/null || { echo "inkscape is required (brew install --cask inkscape)" >&2; exit 1; }
mkdir -p render

inkscape owntone_remote_icon.svg --export-type=png --export-filename=render/icon-512.png -w 512 -h 512 --export-background='#0F172A'
inkscape owntone_remote_icon-foreground.svg --export-type=png --export-filename=render/foreground-512.png -w 512 -h 512
inkscape owntone_remote_icon-background.svg --export-type=png --export-filename=render/background-512.png -w 512 -h 512 --export-background='#0F172A'
inkscape owntone_remote_icon-monochrome.svg --export-type=png --export-filename=render/monochrome-512.png -w 512 -h 512

echo "rendered: render/icon-512.png render/foreground-512.png render/background-512.png render/monochrome-512.png"
