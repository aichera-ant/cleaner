#!/usr/bin/env bash
# "Hepp Cleaner Local" adlı kendinden imzalı Kod İmzalama kimliğini üretir ve login anahtar zincirine koyar.
# Amaç: her derlemede aynı imza → aynı designated requirement → Tam Disk Erişimi ve Otomasyon izni düşmez.
# Idempotent: geçerli kimlik varsa hiçbir şey yapmaz. Özel anahtar yalnız geçici dizinde durur, sonra silinir.
# Ayrıntı: docs/DAGITIM.md
set -euo pipefail

NAME="${SIGN_IDENTITY_NAME:-Hepp Cleaner Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=7300   # ~20 yıl
# macOS'un `security import`'u yeni p12 şifrelemesini (AES/PBKDF2) okuyamayabilir; sistem LibreSSL'i 3DES/SHA1 ile yazar.
OPENSSL=/usr/bin/openssl

valid_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""
}

if valid_identity; then
  echo "Kimlik zaten var: $NAME"
  security find-identity -v -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hepp-cert.XXXXXX")"
chmod 700 "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  # Sertifika ve anahtar daha önce eklenmiş ama güven ayarı yapılmamış: yalnız güveni tamamla.
  echo "Sertifika anahtar zincirinde var ama geçerli kimlik değil; güven ayarı yapılıyor."
  security find-certificate -c "$NAME" -p "$KEYCHAIN" >"$TMP/cert.pem"
else
  cat >"$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
O = Aichera
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
    -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  # p12 parolası yalnız bu çalıştırmalık; dosya ile birlikte silinir.
  P12PASS="$("$OPENSSL" rand -hex 16)"
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$P12PASS"
  rm -f "$TMP/key.pem"
  # -T: yalnız codesign anahtarı sormadan kullanabilsin (başka araç, ör. security, anahtarı dışa veremesin).
  security import "$TMP/id.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12PASS" \
    -T /usr/bin/codesign >/dev/null
  unset P12PASS
  echo "Sertifika ve özel anahtar login anahtar zincirine eklendi."
fi

# Kullanıcı düzeyinde güven (yalnız kod imzalama için). macOS parola ya da Touch ID isteyebilir.
echo "Güven ayarı: macOS parola isterse onaylayın."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if valid_identity; then
  echo "Hazır:"
  security find-identity -v -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
  cat <<EOF
Not: codesign ilk kullanımda anahtar erişimi sorarsa "Her Zaman İzin Ver" deyin. Sormadan çalışsın isterseniz:
  security set-key-partition-list -S apple:,codesign: -s -l "Imported Private Key" "$KEYCHAIN"
(login parolanızı ister).
EOF
else
  echo "Kimlik geçerli görünmüyor; Anahtar Zinciri Erişimi'nde '$NAME' sertifikasının güven ayarına bakın." >&2
  exit 1
fi
