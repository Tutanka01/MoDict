#!/bin/bash
#
# Post-signing sanity check for the hand-assembled MoDict.app. `make verify-bundle`
# runs it with --launch-check; CI runs it before packaging a release.
#
# MoDict is not built by Xcode, so nothing else proves the bundle is
# self-contained. The failure modes covered here have all been real:
#
#   1. Cmlx.framework (MLX, linked through @rpath) missing from
#      Contents/Frameworks, or the @executable_path/../Frameworks rpath missing:
#      dyld aborts before main().
#   2. Hardened Runtime + ad-hoc/self-signed identity: dyld refuses the embedded
#      framework ("mapping process and mapped file (non-platform) have
#      different Team IDs") unless the bundle carries
#      com.apple.security.cs.disable-library-validation.
#   3. default.metallib missing from the embedded Cmlx.framework: the app
#      launches but MLX cannot run kernels.
#   4. Info.plist drifting from the Makefile version.
#
# usage: scripts/verify-bundle.sh [--launch-check] <path/to/MoDict.app> [version]
#
# --launch-check runs the executable with MODICT_LAUNCH_CHECK=1, which exits the
# instant dyld has resolved every library — it never reaches the UI, the model,
# or the network.

set -euo pipefail

launch_check=0
if [ "${1:-}" = "--launch-check" ]; then
    launch_check=1
    shift
fi

app="${1:-}"
expected_version="${2:-}"
executable="$app/Contents/MacOS/MoDict"

fail() {
    echo "error: verify-bundle: $*" >&2
    exit 1
}

check() { echo "  ok   $*"; }

[ -n "$app" ] || fail "usage: verify-bundle.sh [--launch-check] <MoDict.app> [version]"
[ -d "$app" ] || fail "$app not found"
[ -x "$executable" ] || fail "$executable not found or not executable"

# --- Info.plist identity and version ------------------------------------------
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || fail "missing $plist"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

bundle_id=$(plist_get CFBundleIdentifier)
[ "$bundle_id" = "com.modict.app" ] || \
    fail "CFBundleIdentifier is '$bundle_id', expected com.modict.app"

if [ -n "$expected_version" ]; then
    plist_version=$(plist_get CFBundleShortVersionString)
    [ "$plist_version" = "$expected_version" ] || \
        fail "CFBundleShortVersionString is '$plist_version', expected '$expected_version' (stale Info.plist?)"
fi

min_os=$(plist_get LSMinimumSystemVersion)
[ "$min_os" = "15.0" ] || fail "LSMinimumSystemVersion is '$min_os', expected 15.0"

check "Info.plist: com.modict.app ${expected_version:-*} (macOS $min_os+)"

# --- embedded frameworks and @rpath resolution ---------------------------------
frameworks_dir="$app/Contents/Frameworks"
embedded=$(ls "$frameworks_dir" 2>/dev/null | grep -E '\.framework$|\.dylib$' || true)

if [ -n "$embedded" ]; then
    otool -l "$executable" | grep -q "@executable_path/../Frameworks" || \
        fail "the executable has no @executable_path/../Frameworks rpath but the bundle embeds: $(echo "$embedded" | tr '\n' ' ')"
fi

unresolved=""
while IFS= read -r dep; do
    case "$dep" in
        @rpath/*)
            rel="${dep#@rpath/}"
            if [ ! -e "$frameworks_dir/$rel" ] && [ ! -e "$app/Contents/MacOS/$rel" ]; then
                unresolved="$unresolved $dep"
            fi
            ;;
        @loader_path/*)
            rel="${dep#@loader_path/}"
            [ -e "$app/Contents/MacOS/$rel" ] || unresolved="$unresolved $dep"
            ;;
    esac
done < <(otool -L "$executable" | tail -n +2 | awk '{print $1}')

[ -z "$unresolved" ] || fail "dependencies the bundle does not contain:$unresolved"

if [ -n "$embedded" ]; then
    check "@rpath dependencies resolve inside the bundle ($(echo "$embedded" | tr '\n' ' '))"
else
    check "no embedded frameworks"
fi

# --- MLX Metal kernels ---------------------------------------------------------
if [ -d "$frameworks_dir/Cmlx.framework" ]; then
    metallib=$(find "$frameworks_dir/Cmlx.framework" -name 'default.metallib' -print -quit)
    [ -n "$metallib" ] || fail "Cmlx.framework is embedded but default.metallib is missing inside it"
    check "Cmlx.framework ships default.metallib"
fi

# --- signature -----------------------------------------------------------------
codesign --verify --strict --deep --verbose=2 "$app" >/dev/null 2>&1 || \
    fail "codesign --verify --strict --deep failed (run it by hand for details)"
check "signature valid (codesign --verify --strict --deep)"

# --- Hardened Runtime vs embedded third-party libraries ------------------------
# codesign prints the flags on the CodeDirectory line, e.g.
# "CodeDirectory ... flags=0x10002(adhoc,runtime) ...".
signature_flags=$(codesign -dv --verbose=4 "$app" 2>&1 | grep -m1 'flags=' || true)
if [ -n "$embedded" ] && printf '%s' "$signature_flags" | grep -q 'runtime'; then
    entitlements=$(codesign -d --entitlements - "$app" 2>/dev/null \
        || codesign -d --entitlements :- "$app" 2>/dev/null || true)
    printf '%s' "$entitlements" | grep -q 'disable-library-validation' || \
        fail "a Hardened Runtime app with embedded frameworks needs com.apple.security.cs.disable-library-validation, or dyld refuses Cmlx.framework"
    check "library validation disabled for the embedded framework"
fi

# --- launch check --------------------------------------------------------------
if [ "$launch_check" = "1" ]; then
    output_file=$(mktemp)
    trap 'rm -f "$output_file"' EXIT

    # 15 s alarm so a build without the env hook (which would start the real app)
    # cannot hang CI. perl ships with macOS and replaces itself via exec.
    if command -v perl >/dev/null 2>&1; then
        if MODICT_LAUNCH_CHECK=1 perl -e 'alarm shift; exec @ARGV' 15 "$executable" >"$output_file" 2>&1; then
            status=0
        else
            status=$?
        fi
    elif MODICT_LAUNCH_CHECK=1 "$executable" >"$output_file" 2>&1; then
        status=0
    else
        status=$?
    fi
    launch_output=$(cat "$output_file")

    [ "$status" -eq 0 ] || fail "launch check failed (exit $status): $launch_output"
    printf '%s' "$launch_output" | grep -q 'MODICT_LAUNCH_CHECK' || \
        fail "launch check env hook missing or the app did not reach it: $launch_output"
    check "launch check: dyld resolved every library"
fi

echo "verify-bundle: $app is self-contained."
