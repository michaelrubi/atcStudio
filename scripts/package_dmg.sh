#!/usr/bin/env bash
#
# Signs "dist/ATC Studio.app", makes dist/ATC-Studio-<version>.dmg, and notarizes it.
#
# Usage: scripts/package_dmg.sh <version>
#
# Env (all optional; without them the app is ad-hoc signed and not notarized, for local tests):
#   SIGN_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)"
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID   App Store Connect API key for notarytool

set -euo pipefail

VERSION="${1:?usage: package_dmg.sh <version>}"
cd "$(dirname "$0")/.."
APP="dist/ATC Studio.app"
DMG="dist/ATC-Studio-$VERSION.dmg"
IDENTITY="${SIGN_IDENTITY:--}"

[[ -d "$APP" ]] || { echo "error: $APP missing. Run scripts/build_app.sh first." >&2; exit 1; }

sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
[[ "$IDENTITY" == "-" ]] && sign() { codesign --force --sign - "$@"; }

# Inside out: helper programs and nested code first, then the app itself.
sign "$APP/Contents/Resources/bin/ffmpeg"
find "$APP/Contents" -name "*.framework" -prune -print0 | while IFS= read -r -d '' f; do sign "$f"; done
sign "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ATC Studio" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ "$IDENTITY" == "-" ]]; then
  echo "Built $DMG (ad-hoc signed, not notarized)"
  exit 0
fi

codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --wait \
  --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Built $DMG (signed and notarized)"
