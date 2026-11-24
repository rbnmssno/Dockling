#!/bin/bash
# Creates a local self-signed code-signing identity for Dockling, in its own keychain inside the
# project (signing/dockling.keychain-db), so the login keychain is not touched.
#
# Why: an ad-hoc signature changes with every build, and macOS then treats each build as a new app
# and forgets its permissions (Desktop folder, Calendar, Microphone, Speech Recognition). A fixed
# certificate keeps one identity across builds.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=signing
KC="$PWD/$DIR/dockling.keychain-db"
PASS=dockling-local
NAME="Dockling Local Signing"

if [ -f "$KC" ]; then
  echo "Already there: $KC"
  exit 0
fi
mkdir -p "$DIR"
TMP=$(mktemp -d "$PWD/$DIR/tmp.XXXXXX")

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:$PASS 2>/dev/null

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

cp "$TMP/cert.pem" "$DIR/certificate.pem"
rm -f "$TMP"/key.pem "$TMP"/id.p12 "$TMP"/cert.pem "$TMP"/cert.cnf
rmdir "$TMP"
echo "Created $NAME in $KC"
