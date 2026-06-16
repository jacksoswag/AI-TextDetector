#!/bin/zsh
# Create a stable, self-signed code-signing certificate in the login keychain,
# used so TCC permission grants (Accessibility, Screen Recording) survive
# rebuilds. Run once. For real distribution, use a Developer ID identity instead.
set -euo pipefail

IDENTITY="AICF Local Dev Signing"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "'$IDENTITY' already exists — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=$IDENTITY" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
# -legacy: macOS's importer rejects OpenSSL 3's default PKCS12 encryption.
openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:temp
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P temp -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
rm -rf "$TMP"

echo "Created '$IDENTITY'. You can now run scripts/install.sh."
