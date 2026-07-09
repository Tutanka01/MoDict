#!/usr/bin/env bash
#
# Inspect MoDict.app signing posture. The default mode is diagnostic and tries
# to explain what kind of build you have. --release fails closed for pre-prod:
# Developer ID, hardened runtime, secure timestamp, and required entitlements.

set -u

release_mode=0
if [ "${1:-}" = "--release" ]; then
    release_mode=1
    shift
fi

APP="${1:-build/MoDict.app}"
CONTENTS="$APP/Contents"
PLIST="$CONTENTS/Info.plist"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

failures=0
warnings=0

section() {
    printf '\n== %s ==\n' "$1"
}

warn() {
    warnings=$((warnings + 1))
    printf 'warning: %s\n' "$1"
}

fail() {
    failures=$((failures + 1))
    printf 'error: %s\n' "$1"
}

plist_get() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
}

contains_true_entitlement() {
    key="$1"
    [ -n "${ENTITLEMENTS_FILE:-}" ] || return 1
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS_FILE" 2>/dev/null || true)
    [ "$value" = "true" ]
}

section "Bundle"
printf 'App: %s\n' "$APP"
if [ ! -d "$APP" ]; then
    fail "bundle does not exist; run 'make sign' or 'make developer-id' first."
fi

if [ ! -f "$PLIST" ]; then
    fail "missing Contents/Info.plist."
fi

executable=""
binary=""
if [ -f "$PLIST" ]; then
    executable=$(plist_get CFBundleExecutable)
    bundle_id=$(plist_get CFBundleIdentifier)
    version=$(plist_get CFBundleShortVersionString)
    build=$(plist_get CFBundleVersion)
    min_system=$(plist_get LSMinimumSystemVersion)
    lsui=$(plist_get LSUIElement)
    mic_copy=$(plist_get NSMicrophoneUsageDescription)

    printf 'Bundle identifier: %s\n' "${bundle_id:-<missing>}"
    printf 'Version/build: %s (%s)\n' "${version:-<missing>}" "${build:-<missing>}"
    printf 'Minimum macOS: %s\n' "${min_system:-<missing>}"
    printf 'LSUIElement: %s\n' "${lsui:-<missing>}"
    printf 'Executable: %s\n' "${executable:-<missing>}"

    if [ -z "$bundle_id" ]; then fail "CFBundleIdentifier is missing."; fi
    if [ -z "$version" ]; then fail "CFBundleShortVersionString is missing."; fi
    if [ -z "$build" ]; then fail "CFBundleVersion is missing."; fi
    if [ -z "$executable" ]; then fail "CFBundleExecutable is missing."; fi
    if [ "$lsui" != "true" ]; then warn "LSUIElement is not true; MoDict may appear as a normal Dock app."; fi
    if [ -z "$mic_copy" ]; then fail "NSMicrophoneUsageDescription is missing; microphone access can crash or fail."; fi

    if [ -n "$executable" ]; then
        binary="$CONTENTS/MacOS/$executable"
        if [ ! -x "$binary" ]; then
            fail "Contents/MacOS/$executable is missing or not executable."
        fi
    fi
fi

if [ -n "$binary" ] && [ -f "$binary" ]; then
    section "Binary"
    lipo -info "$binary" 2>/dev/null || file "$binary"
fi

section "Code signature"
codesign_info=""
if [ -d "$APP" ]; then
    if codesign_info=$(codesign -dv --verbose=4 "$APP" 2>&1); then
        printf '%s\n' "$codesign_info" | sed -n \
            -e '/^Identifier=/p' \
            -e '/^Format=/p' \
            -e '/^CodeDirectory/p' \
            -e '/^Signature=/p' \
            -e '/^Authority=/p' \
            -e '/^TeamIdentifier=/p' \
            -e '/^Runtime Version=/p' \
            -e '/^Timestamp=/p'
    else
        fail "codesign cannot read the app signature."
    fi

    if codesign --verify --strict --deep --verbose=2 "$APP" >"$tmpdir/codesign-verify.log" 2>&1; then
        printf 'codesign verify: ok\n'
    else
        fail "codesign --verify --strict --deep failed:"
        sed 's/^/  /' "$tmpdir/codesign-verify.log"
    fi
fi

is_adhoc=0
is_developer_id=0
has_runtime=0
has_timestamp=0
team_identifier=""

if [ -n "$codesign_info" ]; then
    printf '%s\n' "$codesign_info" | grep -q '^Signature=adhoc' && is_adhoc=1
    printf '%s\n' "$codesign_info" | grep -q '^Authority=Developer ID Application:' && is_developer_id=1
    printf '%s\n' "$codesign_info" | grep -q '^Runtime Version=' && has_runtime=1
    printf '%s\n' "$codesign_info" | grep -q '^Timestamp=' && has_timestamp=1
    team_identifier=$(printf '%s\n' "$codesign_info" | sed -n 's/^TeamIdentifier=//p' | head -n 1)
fi

if [ "$is_adhoc" -eq 1 ]; then
    warn "signature is ad-hoc. This is acceptable for CI/dev only; never ship it as pre-prod/release."
elif [ "$is_developer_id" -eq 1 ]; then
    printf 'signature class: Developer ID Application\n'
else
    warn "signature is not Developer ID. It may be fine for local dev, but it cannot be notarized for distribution."
fi

section "Entitlements"
ENTITLEMENTS_FILE="$tmpdir/entitlements.plist"

if [ -d "$APP" ]; then
    if codesign -d --entitlements :- "$APP" >"$ENTITLEMENTS_FILE" 2>"$tmpdir/entitlements.log"; then
        if [ -s "$ENTITLEMENTS_FILE" ]; then
            /usr/bin/plutil -p "$ENTITLEMENTS_FILE" 2>/dev/null || cat "$ENTITLEMENTS_FILE"
        else
            warn "signature has no explicit entitlements."
        fi
    else
        warn "could not read entitlements from signature."
        sed 's/^/  /' "$tmpdir/entitlements.log" 2>/dev/null || true
    fi
fi

if contains_true_entitlement "com.apple.security.device.audio-input"; then
    printf 'audio-input entitlement: ok\n'
else
    fail "missing com.apple.security.device.audio-input entitlement."
fi

if contains_true_entitlement "com.apple.security.device.microphone"; then
    printf 'legacy microphone entitlement: ok\n'
else
    if [ "$release_mode" -eq 1 ]; then
        fail "missing legacy com.apple.security.device.microphone entitlement."
    else
        warn "missing legacy com.apple.security.device.microphone entitlement."
    fi
fi

if contains_true_entitlement "com.apple.security.app-sandbox"; then
    fail "App Sandbox is enabled, but MoDict needs global input monitoring and synthetic paste events."
fi

section "Gatekeeper"
if command -v spctl >/dev/null 2>&1 && [ -d "$APP" ]; then
    if spctl --assess --type execute --verbose=4 "$APP" 2>"$tmpdir/spctl.log"; then
        printf 'spctl assessment: accepted\n'
        sed 's/^/  /' "$tmpdir/spctl.log"
    else
        warn "spctl assessment did not accept the app. Developer ID builds still need notarization before distribution."
        sed 's/^/  /' "$tmpdir/spctl.log"
    fi
else
    warn "spctl is unavailable; skipping Gatekeeper assessment."
fi

if [ "$release_mode" -eq 1 ]; then
    section "Release policy"
    if [ "$is_adhoc" -eq 1 ]; then
        fail "release validation forbids ad-hoc signatures."
    fi
    if [ "$is_developer_id" -ne 1 ]; then
        fail "release validation requires a Developer ID Application signature."
    fi
    if [ "$has_runtime" -ne 1 ]; then
        fail "release validation requires Hardened Runtime (--options runtime)."
    fi
    if [ "$has_timestamp" -ne 1 ]; then
        fail "release validation requires a secure timestamp."
    fi
    if [ -z "$team_identifier" ] || [ "$team_identifier" = "not set" ]; then
        fail "release validation requires a TeamIdentifier."
    fi
fi

section "Result"
if [ "$failures" -gt 0 ]; then
    printf 'failed: %s error(s), %s warning(s)\n' "$failures" "$warnings"
    exit 1
fi

if [ "$release_mode" -eq 1 ]; then
    printf 'release signing checks passed. Notarization is still required before distribution.\n'
else
    printf 'diagnostic completed with %s warning(s).\n' "$warnings"
fi
