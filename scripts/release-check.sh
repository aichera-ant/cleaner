#!/usr/bin/env bash
# Yayın öncesi denetim: derlenmiş uygulama gerçek yayına uygun mu (deneme ayarlarıyla derlenmemiş mi)?
# scripts/release.sh çağırır; anahtar zincirine dokunmadığı için tek başına da çalıştırılabilir.
# Kullanım: scripts/release-check.sh [app yolu] [indirme öneki]
# Çıktı: her sorun için bir satır (stdout). Sorun yoksa sessiz, çıkış kodu 0; varsa 1.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="aichera-ant/cleaner"
APP="${1:-build/Hepp Cleaner.app}"
DOWNLOAD_BASE="${2:-https://github.com/$REPO/releases/download/}"
PROD_FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
DEFAULT_IDENTITY="Hepp Cleaner Local"
PLIST="$APP/Contents/Info.plist"

problems=()
p() { problems+=("$1"); }

# Deneme amaçlı ezmeler (build-app.sh'a geçer).
[[ -z "${FEED_URL:-}" ]] || p "FEED_URL ezilmiş: $FEED_URL"
[[ -z "${BUILD_NUMBER:-}" ]] || p "BUILD_NUMBER ezilmiş: $BUILD_NUMBER"
[[ -z "${SIGN_IDENTITY:-}" || "$SIGN_IDENTITY" == "$DEFAULT_IDENTITY" ]] || p "SIGN_IDENTITY ezilmiş: $SIGN_IDENTITY"

if [[ ! -f "$PLIST" ]]; then
  p "Info.plist yok: $PLIST"
else
  plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
  feed="$(plist SUFeedURL)"
  [[ "$feed" == "$PROD_FEED" ]] || p "SUFeedURL üretim adresi değil: ${feed:-<yok>}"
  # SKIP_BUILD ile eski bir deneme derlemesi kullanılırsa: sürüm project.yml'dakiyle aynı olmalı.
  yml() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" App/project.yml | head -n 1; }
  want_build="$(yml CURRENT_PROJECT_VERSION)"
  want_ver="$(yml MARKETING_VERSION)"
  [[ "$(plist CFBundleVersion)" == "$want_build" ]] ||
    p "CFBundleVersion ($(plist CFBundleVersion)) project.yml'daki CURRENT_PROJECT_VERSION ($want_build) değil"
  [[ "$(plist CFBundleShortVersionString)" == "$want_ver" ]] ||
    p "CFBundleShortVersionString ($(plist CFBundleShortVersionString)) project.yml'daki MARKETING_VERSION ($want_ver) değil"
fi

[[ "$DOWNLOAD_BASE" == "https://github.com/$REPO/"* ]] || p "DOWNLOAD_BASE https://github.com/$REPO/ ile başlamıyor: $DOWNLOAD_BASE"

if [[ -d "$APP" ]]; then
  dr="$(codesign -d -r- "$APP" 2>&1 || true)"
  [[ "$dr" == *"designated => "*"certificate root"* ]] ||
    p "Designated requirement sertifikaya bağlı değil (ad-hoc ya da imzasız): $(tail -n 1 <<<"$dr")"
  info="$(codesign -dv "$APP" 2>&1 || true)"
  RT_RE='flags=0x[0-9a-f]+\([^)]*runtime'
  [[ "$info" =~ $RT_RE ]] || p "Hardened runtime bayrağı yok"
else
  p "Uygulama yok: $APP"
fi

if ((${#problems[@]})); then
  printf '%s\n' "${problems[@]}"
  exit 1
fi
