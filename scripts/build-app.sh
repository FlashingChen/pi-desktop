#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
swift build --build-system native -c "$configuration"
bin_dir="$(swift build --build-system native -c "$configuration" --show-bin-path)"
mkdir -p build
stage="$(mktemp -d "$PWD/build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app_dir="$stage/Pi Desktop.app"
final_app="$PWD/build/Pi Desktop.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$stage/AppIcon.iconset"
cp "$bin_dir/PiDesktop" "$app_dir/Contents/MacOS/PiDesktop"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift scripts/make-icon.swift "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
# Standard macOS resource placement; the terminal uses the default CoreText renderer.
for bundle in "$bin_dir"/*.bundle(N); do cp -R "$bundle" "$app_dir/Contents/Resources/"; done
cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [[ -e "$final_app" ]]; then mv "$final_app" "$stage/previous.app"; fi
mv "$app_dir" "$final_app"
echo "Built: $final_app"
