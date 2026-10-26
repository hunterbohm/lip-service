#!/bin/bash
# Regenerates Resources/AppIcon.icns, the bundle's icon, from Resources/AppIcon-1024.png with sips and iconutil.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/Resources/AppIcon-1024.png"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
iconset="$scratch/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$root/Resources/AppIcon.icns"
printf 'Wrote Resources/AppIcon.icns (%s bytes).\n' "$(stat -f %z "$root/Resources/AppIcon.icns")"
