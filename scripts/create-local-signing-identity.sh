#!/bin/bash
# Create the persistent local identity used to sign UsageMenuBar rebuilds.
set -euo pipefail

IDENTITY_NAME="UsageMenuBar Local Signing"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -Fq "\"$IDENTITY_NAME\""; then
  echo "Signing identity already exists: $IDENTITY_NAME"
  exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/usage-menubar-signing.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

CERTIFICATE_PATH="$TEMP_DIR/certificate.pem"
PRIVATE_KEY_PATH="$TEMP_DIR/private-key.pem"
ARCHIVE_PATH="$TEMP_DIR/identity.p12"
PASSWORD_PATH="$TEMP_DIR/archive-password"

echo "Creating local code-signing identity..."
/usr/bin/openssl req \
  -new \
  -newkey rsa:3072 \
  -x509 \
  -sha256 \
  -nodes \
  -days 3650 \
  -subj "/CN=$IDENTITY_NAME/O=UsageMenuBar Local Development" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$PRIVATE_KEY_PATH" \
  -out "$CERTIFICATE_PATH" \
  >/dev/null 2>&1

/usr/bin/openssl rand -hex -out "$PASSWORD_PATH" 32
/usr/bin/openssl pkcs12 \
  -export \
  -name "$IDENTITY_NAME" \
  -inkey "$PRIVATE_KEY_PATH" \
  -in "$CERTIFICATE_PATH" \
  -out "$ARCHIVE_PATH" \
  -passout "file:$PASSWORD_PATH"

# Limit trust to code signing in the current user's trust store. A self-signed
# development certificate is otherwise excluded from valid signing identities.
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN_PATH" \
  "$CERTIFICATE_PATH"

ARCHIVE_PASSWORD="$(tr -d '\n' < "$PASSWORD_PATH")"
security import "$ARCHIVE_PATH" \
  -k "$KEYCHAIN_PATH" \
  -f pkcs12 \
  -P "$ARCHIVE_PASSWORD" \
  -x \
  -T /usr/bin/codesign
unset ARCHIVE_PASSWORD

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -Fq "\"$IDENTITY_NAME\""; then
  echo "The identity was imported but macOS does not consider it valid for code signing." >&2
  echo "Open Keychain Access, trust '$IDENTITY_NAME' for Code Signing, then run this script again." >&2
  exit 1
fi

echo "Created signing identity: $IDENTITY_NAME"
