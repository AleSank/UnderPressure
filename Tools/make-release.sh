#!/bin/zsh
# Builds a release for GitHub: runs the tests, builds the universal (arm64 + x86_64)
# Release app, checks it, and packs it as dist/UnderPressure-<version>.zip.
# Usage: Tools/make-release.sh   (run from anywhere; the version comes from the project)
# The Release workflow (.github/workflows/release.yml) runs it on every v* tag and publishes
# the result; run it locally to check a release before tagging.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
# Use the selected Xcode (CI selects one); fall back to /Applications/Xcode.app when only the
# Command Line Tools are selected, which can't build apps.
if [[ -z ${DEVELOPER_DIR:-} ]]; then
  selected=$(xcode-select -p 2>/dev/null || true)
  if [[ -z $selected || $selected == *CommandLineTools* ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    export DEVELOPER_DIR=$selected
  fi
fi
derived=build/DerivedData
app=$derived/Build/Products/Release/UnderPressure.app

version=$(sed -nE 's/.*MARKETING_VERSION = ([0-9.]+);.*/\1/p' UnderPressure.xcodeproj/project.pbxproj | head -1)
echo "==> UnderPressure $version"

echo "==> Tests"
xcodebuild test -scheme UnderPressure -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath $derived -quiet

echo "==> Universal Release build"
rm -rf "$app"
xcodebuild build -scheme UnderPressure -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath $derived \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet

echo "==> Checks"
archs=$(lipo -archs "$app/Contents/MacOS/UnderPressure")
[[ $archs == *arm64* && $archs == *x86_64* ]] || { echo "Not universal: $archs" >&2; exit 1; }
built=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
[[ $built == $version ]] || { echo "Version mismatch: app $built, project $version" >&2; exit 1; }
codesign --verify --deep --strict "$app"

echo "==> Package"
mkdir -p dist
zip=dist/UnderPressure-$version.zip
rm -f "$zip"
# ditto keeps the bundle's symlinks, permissions and signature intact (plain zip may not).
ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip"

echo "Done: $zip"
