#!/usr/bin/env bash
# Hepp Cleaner.app üretir: xcodegen + xcodebuild + sabit yerel imza. Çıktı: build/Hepp Cleaner.app
# İmza: varsayılan "Hepp Cleaner Local" (scripts/make-signing-cert.sh). SIGN_IDENTITY=- ile ad-hoc.
# Ayrıntı ve hardened runtime kararı: docs/DAGITIM.md
#
# Ortam değişkenleri:
#   CONFIG=Debug        --snapshot (PNG üretimi) etkin derleme; varsayılan Release.
#   SIGN_IDENTITY=...   imza kimliği (varsayılan "Hepp Cleaner Local"; "-" ad-hoc).
#   BUILD_NUMBER=N      CURRENT_PROJECT_VERSION'ı ezer (yalnız deneme; yayında project.yml'dakini artırın).
#   FEED_URL=...        SUFeedURL'yi ezer (yalnız yerel güncelleme denemesi).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Hepp Cleaner"
APP="build/$APP_NAME.app"
CONFIG="${CONFIG:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Hepp Cleaner Local}"

command -v xcodegen >/dev/null || { echo "xcodegen yok (brew install xcodegen)" >&2; exit 1; }

if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
  echo "İmza kimliği bulunamadı: \"$SIGN_IDENTITY\"" >&2
  echo "Bir kez çalıştırın: scripts/make-signing-cert.sh  (ya da ad-hoc için SIGN_IDENTITY=- $0)" >&2
  exit 1
fi

( cd App && xcodegen generate --quiet )

EXTRA=()
[[ -n "${BUILD_NUMBER:-}" ]] && EXTRA+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
[[ -n "${FEED_URL:-}" ]] && EXTRA+=("SPARKLE_FEED_URL=$FEED_URL")

rm -rf "$APP"
mkdir -p build
LOG=build/xcodebuild.log
# xcodebuild, yerel paket kökündeki Package.resolved'a uygulamanın bağımlılıklarını (Sparkle) yazıyor;
# `swift test` sonra geri siliyor. Depodaki dosya CLI/çekirdek paketine ait: derleme sonunda eski hâline döner.
# (Sparkle sürümü App/project.yml'da exact sabit.)
cp Package.resolved build/Package.resolved.keep
trap 'cp build/Package.resolved.keep Package.resolved' EXIT
# Xcode ad-hoc imzalar; asıl imza aşağıda içten dışa atılır.
if ! xcodebuild \
  -project App/Cleaner.xcodeproj \
  -scheme Cleaner \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  build >"$LOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -n 30 >&2
  echo "Derleme başarısız. Ayrıntı: $LOG" >&2
  exit 1
fi
grep -E "warning:|BUILD SUCCEEDED" "$LOG" | sort -u | head -n 10 || true

# ditto: framework sembolik bağlarını ve genişletilmiş öznitelikleri korur.
ditto "build/DerivedData/Build/Products/$CONFIG/$APP_NAME.app" "$APP"

# İç içe kod içten dışa imzalanır (--deep yerine). Hardened runtime açık (--options runtime): DYLD ile
# kitaplık eklenerek uygulamanın Tam Disk Erişimi / Otomasyon izninin devralınmasını engeller (docs/DAGITIM.md).
ENTITLEMENTS="App/Cleaner.entitlements"
sign() {
  local out
  out="$(codesign --force --timestamp=none --options runtime --sign "$SIGN_IDENTITY" "$@" 2>&1)" || { echo "$out" >&2; return 1; }
}

FW="$APP/Contents/Frameworks"
if [[ -d "$FW/Sparkle.framework" ]]; then
  SP="$FW/Sparkle.framework/Versions/B"
  sign "$SP/XPCServices/Installer.xpc"
  # Downloader.xpc'nin entitlement'ı varsa korunur (Sparkle sürümüne göre değişebilir).
  sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
  sign "$SP/Autoupdate"
  sign "$SP/Updater.app"
  sign "$FW/Sparkle.framework"
fi
# Diğer framework ve dylib'ler (varsa).
if [[ -d "$FW" ]]; then
  find "$FW" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) ! -name "Sparkle.framework" -print0 |
    while IFS= read -r -d '' f; do sign "$f"; done
fi
sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=1 "$APP"
RT_RE='flags=0x[0-9a-f]+\([^)]*runtime'
[[ "$(codesign -dv "$APP" 2>&1)" =~ $RT_RE ]] || { echo "Hardened runtime bayrağı yok: $APP" >&2; exit 1; }
codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => /designated: /p'
echo "Hazır: $ROOT/$APP"
