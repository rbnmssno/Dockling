#!/bin/bash
# Rebuilds the icon's artwork from the built-in sprite sheet: the character's bust from idle frame 0,
# 24 icon points per sprite pixel, rising from the bottom edge, with a one-pixel light outline.
# Run after replacing Resources/Skin, then scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOL="$(mktemp -d)/sprite-to-svg"
swiftc -O scripts/sprite-to-svg.swift -o "$TOOL"
A=Resources/AppIcon.icon/Assets
"$TOOL" Resources/Skin "$A/ghost.svg" 0 0 6 0 45 37 24 25.5 1024
"$TOOL" Resources/Skin "$A/rim.svg" 0 0 6 0 45 37 24 25.5 1024 rim "#EFEAFF"
rm -rf "$(dirname "$TOOL")"
