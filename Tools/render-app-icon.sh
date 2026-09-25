#!/bin/zsh
# Renders the app icon from the shared glyph geometry (UnderPressureIconRenderer.swift)
# and writes every size macOS needs into Assets.xcassets/AppIcon.appiconset.
# Usage: Tools/render-app-icon.sh   (run from the repository root)
set -euo pipefail

root=${0:A:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O "$root/Tools/AppIcon/main.swift" "$root/UnderPressure/UnderPressureIconRenderer.swift" -o "$work/render"
"$work/render" "$work/icon_1024.png"

set=$root/UnderPressure/Assets.xcassets/AppIcon.appiconset
mkdir -p "$set"
for size in 16 32 64 128 256 512 1024; do
  sips -z $size $size "$work/icon_1024.png" --out "$set/icon_$size.png" >/dev/null
done

cat > "$set/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "App icon written to $set"
