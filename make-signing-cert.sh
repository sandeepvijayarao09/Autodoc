#!/bin/bash
# Create a STABLE self-signed code-signing identity in the login keychain.
# Signing Autodoc with this (instead of ad-hoc) gives it a code signature whose
# identity survives rebuilds — so macOS keeps your Screen Recording + Keychain
# grants instead of re-prompting every time you rebuild.
#
# No Apple Developer account needed. Gatekeeper still won't "trust" a self-signed
# app for distribution, but that's irrelevant for running it locally.
set -euo pipefail

NAME="Autodoc Local Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✓ signing identity “$NAME” already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# Use the system LibreSSL — Homebrew's OpenSSL 3.x writes a PKCS12 MAC that
# macOS's `security import` cannot verify.
SSL=/usr/bin/openssl

echo "▶︎ generating self-signed code-signing cert…"
"$SSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

"$SSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:autodoc -name "$NAME" 2>/dev/null

echo "▶︎ importing into login keychain (grants codesign access)…"
security import "$TMP/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P autodoc -T /usr/bin/codesign -A

rm -rf "$TMP"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✓ created identity “$NAME”. Re-run ./build.sh to sign with it."
else
    echo "✗ identity did not register — check keychain access."
    exit 1
fi
