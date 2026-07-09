#!/usr/bin/env bash
#
# dev-cert.sh — create a stable self-signed "MoDict Dev" code-signing identity.
#
# WHY THIS EXISTS
# ---------------
# macOS TCC (Privacy & Security) identifies an app by the "designated
# requirement" derived from its code signature. An ad-hoc signature
# (`codesign -s -`) has a designated requirement built from the CDHash, which
# changes on every rebuild. The result: macOS forgets the Microphone,
# Accessibility and Input Monitoring grants each time you rebuild MoDict, and you
# re-approve all three constantly.
#
# Signing with a STABLE identity fixes the designated requirement to the
# certificate (not the CDHash), so the grants persist across rebuilds. For a
# local open-source project that identity is a one-time self-signed "Code
# Signing" certificate in your login keychain. The Makefile picks it up
# automatically (IDENTITY ?= "MoDict Dev").
#
# This script tries to create that certificate from the command line. If any
# step fails (CLI certificate creation is finicky and version-dependent), it
# prints the exact Keychain Access steps to do it by hand.

set -u

CERT_NAME="MoDict Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

print_gui_instructions() {
    cat <<'EOF'

Create the certificate by hand in Keychain Access (one time):

  1. Open Keychain Access (Applications > Utilities).
  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate…
  3. Name:            MoDict Dev
     Identity Type:   Self-Signed Root
     Certificate Type: Code Signing
     Tick "Let me override defaults" and click Continue through the panels
     (the defaults are fine); on the last panel choose the "login" keychain.
  4. Create the certificate and quit the assistant.
  5. Find "MoDict Dev" in the login keychain, double-click it, expand Trust,
     and set "Code Signing" to "Always Trust". Close the window (you may be
     asked for your login password).

Verify it is usable:

    security find-identity -v -p codesigning

You should see a line containing "MoDict Dev". After that, `make sign` uses it
automatically. The first `codesign` may ask to use the key — click Always Allow.
EOF
}

# Already present? Nothing to do.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "A code-signing identity named \"$CERT_NAME\" already exists. Nothing to do."
    exit 0
fi

echo "Creating a self-signed \"$CERT_NAME\" code-signing certificate…"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no

[ dn ]
CN = MoDict Dev

[ codesign ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

fail() {
    echo "note: automatic CLI creation did not complete ($1)."
    print_gui_instructions
    exit 0
}

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -config "$TMP/openssl.cnf" >/dev/null 2>&1 || fail "openssl req failed"

openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -out "$TMP/cert.p12" -passout pass: >/dev/null 2>&1 \
    || openssl pkcs12 -export \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$CERT_NAME" -out "$TMP/cert.p12" -passout pass: >/dev/null 2>&1 \
    || fail "openssl pkcs12 failed"

# Import key + certificate into the login keychain and allow codesign to use it.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign >/dev/null 2>&1 \
    || fail "security import failed"

# Trust the certificate for code signing (user domain; may prompt for auth).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 \
    || echo "note: could not set trust automatically; set \"Code Signing: Always Trust\" in Keychain Access."

# Let codesign use the private key without prompting on every build. This needs
# the login keychain password; skipping is fine (codesign will prompt once).
echo
echo "Optional: to stop codesign prompting on every build, your login keychain"
echo "password can authorize key access now. Leave blank to skip."
printf "Login keychain password (hidden): "
read -rs KCPW
echo
if [ -n "${KCPW:-}" ]; then
    if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "Key access authorized for codesign."
    else
        echo "note: could not authorize key access; codesign may prompt once (click Always Allow)."
    fi
else
    echo "note: skipped; codesign may prompt once on the first build (click Always Allow)."
fi

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "Done. \"$CERT_NAME\" is ready. 'make sign' will use it automatically."
    exit 0
else
    echo "The identity is not showing up as usable yet."
    print_gui_instructions
    exit 0
fi
