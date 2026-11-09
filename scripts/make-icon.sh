#!/bin/bash
# Renders the Ad-Owl icon and packs it into Assets/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Assets
swift scripts/make-icon.swift Assets/AppIcon-1024.png
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Assets/AppIcon.icns
echo "Wrote Assets/AppIcon.icns"
