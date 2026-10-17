#!/usr/bin/env bash
# İmzalı build/Hepp Cleaner.app'ten sürüm adlı DMG üretir: build/Hepp-Cleaner-<sürüm>.dmg
# İçinde uygulama ve Uygulamalar kısayolu var; DMG de aynı kimlikle imzalanır.
# Kullanım: scripts/make-dmg.sh [app yolu]   (önce scripts/build-app.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Hepp Cleaner.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Hepp Cleaner Local}"
OUT_DIR="${OUT_DIR:-build}"

[[ -d "$APP" ]] || { echo "Uygulama yok: $APP (önce scripts/build-app.sh)" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "Uygulamanın imzası geçersiz: $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$OUT_DIR/Hepp-Cleaner-$VERSION.dmg"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hepp-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Hepp Cleaner.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -quiet -volname "Hepp Cleaner $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"

codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --verbose=1 "$DMG"
echo "DMG: $(pwd)/$DMG ($VERSION, yapı $BUILD)"
