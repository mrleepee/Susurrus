#!/bin/zsh
# Create a local self-signed code-signing identity "Susurrus Dev" for Susurrus.
#
# Why: the binaries are ad-hoc signed by default, so their code hash changes on
# every build and macOS TCC silently revokes Microphone / Accessibility /
# Automation grants each time. A stable self-signed identity gives the app a
# stable designated requirement, so TCC grants persist across rebuilds.
#
# This script generates a self-signed certificate with the keyUsage / codeSigning
# bits macOS requires, imports it (key + cert) into the login keychain granting
# /usr/bin/codesign access, and marks it as a per-user trusted root (no sudo).
# After it runs, the Makefile's SIGN_IDENTITY auto-discovery finds "Susurrus Dev"
# and `make install` signs the .app with it.
#
# Re-runnable: any existing "Susurrus Dev" certificate is removed first.

set -euo pipefail

CN="Susurrus Dev"
LOGIN_KC="${HOME}/Library/Keychains/login.keychain-db"
[[ -f "$LOGIN_KC" ]] || LOGIN_KC="$(security default-keychain | awk '{print $1}' | tr -d '"')"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Removing any existing \"$CN\" certificate..."
while security delete-certificate -c "$CN" "$LOGIN_KC" 2>/dev/null; do :; done

echo "Generating self-signed code-signing certificate \"$CN\"..."
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/csr.pem" \
  -subj "/CN=$CN" >/dev/null 2>&1

# macOS code-signing policy requires BOTH keyUsage=digitalSignature and the
# codeSigning extended key usage. Missing digitalSignature produces
# "this identity cannot be used for signing code".
cat > "$WORK/ext.cnf" <<EOF
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOF
openssl x509 -req -in "$WORK/csr.pem" -signkey "$WORK/key.pem" \
  -days 3650 -extfile "$WORK/ext.cnf" -out "$WORK/cert.pem" >/dev/null 2>&1

echo "Importing into login keychain: $LOGIN_KC"
# -T /usr/bin/codesign adds an ACL entry so codesign can use the key silently.
security import "$WORK/key.pem"  -k "$LOGIN_KC" -T /usr/bin/codesign >/dev/null
security import "$WORK/cert.pem" -k "$LOGIN_KC" >/dev/null

echo "Marking as trusted root (per-user; no sudo needed)..."
security add-trusted-cert -r trustRoot -k "$LOGIN_KC" "$WORK/cert.pem" >/dev/null

echo
echo "Valid code-signing identities now:"
security find-identity -v -p codesigning "$LOGIN_KC"
echo
echo "Done. Build & install with:"
echo "    make install"
