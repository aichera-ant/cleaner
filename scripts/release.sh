#!/usr/bin/env bash
# Sürüm hazırlar: build-app.sh → make-dmg.sh → Sparkle sign_update + appcast.xml.
# Çıktı: build/release/Hepp-Cleaner-<sürüm>.dmg ve build/release/appcast.xml (EdDSA imzalı öğe).
# YAYINLAMAZ: GitHub Release'i yönetici açar; sonda çalıştırılacak `gh release create` komutu yazdırılır.
# Sürüm: App/project.yml MARKETING_VERSION ve CURRENT_PROJECT_VERSION (her yayında yapı numarası +1).
#
# Ortam değişkenleri (yalnız yerel deneme için):
#   DOWNLOAD_BASE=...   indirme URL öneki (varsayılan GitHub Release asset'i: .../releases/download/v<sürüm>/)
#   RELEASE_NOTES=dosya sürüm notu (HTML parçası, appcast'e gömülür); yoksa notsuz.
#   SKIP_BUILD=1        build/Hepp Cleaner.app'i yeniden derlemeden kullan.
#   (FEED_URL, BUILD_NUMBER, SIGN_IDENTITY build-app.sh'a geçer.)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
REPO="aichera-ant/cleaner"
APP="build/Hepp Cleaner.app"
REL="build/release"

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  scripts/build-app.sh
fi

SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle araçları yok: $SPARKLE_BIN (önce scripts/build-app.sh)" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "CFBundleVersion tam sayı olmalı: $BUILD" >&2; exit 1; }
TAG="v$VERSION"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/$TAG/}"
[[ "$DOWNLOAD_BASE" == */ ]] || DOWNLOAD_BASE="$DOWNLOAD_BASE/"

# Her yayının appcast'i yalnız kendi öğesini taşır: SUFeedURL "latest/download/appcast.xml" hep son yayını gösterir.
rm -rf "$REL"
mkdir -p "$REL"
OUT_DIR="$REL" scripts/make-dmg.sh "$APP"
DMG="$REL/Hepp-Cleaner-$VERSION.dmg"
DMG_NAME="$(basename "$DMG")"

# generate_appcast kullanılmaz: DMG'yi bağlayarak okuyor ve macOS bu bağlamada kullanıcının ekranında
# "uygulama yüklensin mi?" penceresi açabiliyor. Burada DMG hiç bağlanmaz: sürüm bilgisi .app'ten,
# imza sign_update'ten gelir. Özel EdDSA anahtarı login anahtar zincirinden okunur; macOS erişim izni sorabilir.
echo "EdDSA imzası: anahtar zinciri erişimi sorulursa \"Her Zaman İzin Ver\" deyin."
SIG_ATTRS="$("$SPARKLE_BIN/sign_update" "$DMG" 2>&1)" || true   # sparkle:edSignature="..." length="..."
if [[ "$SIG_ATTRS" != *'sparkle:edSignature="'*'length="'* ]]; then
  echo "sign_update başarısız: $SIG_ATTRS" >&2
  exit 1
fi

HW=""
if [[ "$(lipo -archs "$APP/Contents/MacOS/Hepp Cleaner")" == "arm64" ]]; then
  HW="            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
fi
NOTES=""
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  NOTES="            <description><![CDATA[$(cat "$RELEASE_NOTES")]]></description>"
fi
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

{
  cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Hepp Cleaner</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <link>https://github.com/$REPO</link>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
EOF
  if [[ -n "$HW" ]]; then echo "$HW"; fi
  if [[ -n "$NOTES" ]]; then echo "$NOTES"; fi
  cat <<EOF
            <enclosure url="${DOWNLOAD_BASE}${DMG_NAME}" type="application/octet-stream" $SIG_ATTRS/>
        </item>
    </channel>
</rss>
EOF
} >"$REL/appcast.xml"

xmllint --noout "$REL/appcast.xml"
# İmzayı, uygulamanın Info.plist'teki SUPublicEDKey'i ile doğrula (Sparkle'ın yaptığı denetim; anahtar zinciri gerekmez).
SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_ATTRS")"
PUB_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
VTMP="$(mktemp -d "${TMPDIR:-/tmp}/hepp-verify.XXXXXX")"
{ printf '302a300506032b6570032100' | xxd -r -p; base64 -D <<<"$PUB_PLIST"; } >"$VTMP/pub.der"
base64 -D <<<"$SIG" >"$VTMP/sig.bin"
# Sistem LibreSSL'i Ed25519 doğrulayamaz; Homebrew OpenSSL 3+ gerekir.
OSSL="$(command -v /opt/homebrew/bin/openssl || command -v /usr/local/bin/openssl || command -v openssl)"
if ! "$OSSL" version | grep -q '^OpenSSL [3-9]'; then
  rm -rf "$VTMP"
  echo "Uyarı: OpenSSL 3+ yok (brew install openssl); EdDSA imzası yerelde doğrulanmadı." >&2
elif "$OSSL" pkeyutl -verify -pubin -keyform DER -inkey "$VTMP/pub.der" -rawin -in "$DMG" -sigfile "$VTMP/sig.bin" >/dev/null 2>&1; then
  rm -rf "$VTMP"
else
  rm -rf "$VTMP"
  echo "EdDSA imzası SUPublicEDKey ile doğrulanamadı (anahtar zincirindeki anahtar Info.plist'tekiyle aynı mı?)" >&2
  exit 1
fi

echo
echo "Hazır: $ROOT/$REL"
echo "  $DMG_NAME  sürüm $VERSION, yapı $BUILD"
echo "  appcast.xml  indirme: ${DOWNLOAD_BASE}${DMG_NAME}  (EdDSA imzası doğrulandı)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "Uyarı: çalışma ağacında commit edilmemiş değişiklik var." >&2
fi
cat <<EOF

Yayın için (bu betik çalıştırmaz):
  gh release create $TAG \\
    "$DMG" \\
    "$REL/appcast.xml" \\
    --repo $REPO --title "Hepp Cleaner $VERSION" --notes "Hepp Cleaner $VERSION (yapı $BUILD)" --latest
EOF
