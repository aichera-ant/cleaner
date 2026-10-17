#!/usr/bin/env bash
# Cleaner.app üretir: xcodegen + xcodebuild. Çıktı: build/Cleaner.app (ad-hoc imzalı; dağıtım İP4).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

command -v xcodegen >/dev/null || { echo "xcodegen yok (brew install xcodegen)" >&2; exit 1; }

( cd App && xcodegen generate --quiet )

rm -rf build/Cleaner.app
mkdir -p build
LOG=build/xcodebuild.log
if ! xcodebuild \
  -project App/Cleaner.xcodeproj \
  -scheme Cleaner \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
  build >"$LOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -n 30 >&2
  echo "Derleme başarısız. Ayrıntı: $LOG" >&2
  exit 1
fi
grep -E "warning:|BUILD SUCCEEDED" "$LOG" | sort -u | head -n 10 || true

cp -R build/DerivedData/Build/Products/Release/Cleaner.app build/Cleaner.app
codesign --force --deep --sign - build/Cleaner.app >/dev/null
codesign --verify --verbose=1 build/Cleaner.app
echo "Hazır: $ROOT/build/Cleaner.app"
