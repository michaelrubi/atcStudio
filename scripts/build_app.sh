#!/usr/bin/env bash
#
# Builds "dist/ATC Studio.app" (arm64, Release).
#
# Usage: scripts/build_app.sh [version]     e.g. scripts/build_app.sh 1.0.0
#
# Uses xcodebuild, not `swift build`, because only xcodebuild compiles MLX's Metal
# shaders (the Title model needs them). One-time: xcodebuild -downloadComponent MetalToolchain
# Run scripts/build_ffmpeg.sh first; the app ships its own ffmpeg in Resources/bin.

set -euo pipefail

VERSION="${1:-0.0.0}"
BUNDLE_ID=com.rubiconetic.atcstudio
APP_NAME="ATC Studio"

cd "$(dirname "$0")/.."
DERIVED=.build/xcode-release
PRODUCTS="$DERIVED/Build/Products/Release"
APP="dist/$APP_NAME.app"
FFMPEG=.build/ffmpeg/bin/ffmpeg

[[ -x "$FFMPEG" ]] || { echo "error: $FFMPEG missing. Run scripts/build_ffmpeg.sh first." >&2; exit 1; }

xcodebuild build -quiet \
  -scheme ATCStudio -configuration Release \
  -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation -skipMacroValidation

[[ -f "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] || {
  echo "error: MLX Metal shaders were not built. Run: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"

cp "$PRODUCTS/ATCStudio" "$APP/Contents/MacOS/ATCStudio"
# SwiftPM resource bundles (MLX shaders, app icon, GRDB, ...). Bundle.module finds them here.
cp -R "$PRODUCTS"/*.bundle "$APP/Contents/Resources/"
# Dynamic package frameworks, if any. Xcode links them from @executable_path/../Frameworks.
if compgen -G "$PRODUCTS/PackageFrameworks/*.framework" >/dev/null; then
  cp -R "$PRODUCTS"/PackageFrameworks/*.framework "$APP/Contents/Frameworks/"
fi
rmdir "$APP/Contents/Frameworks" 2>/dev/null || true
cp "$FFMPEG" "$APP/Contents/Resources/bin/ffmpeg"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/render_icon.swift assets/branding/atc_studio_icon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ATCStudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $APP ($VERSION)"
