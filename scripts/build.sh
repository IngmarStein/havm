#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Configuration -----------------------------------------------------------
# Set via environment or resources/build.xcconfig:
#   DEVELOPMENT_TEAM    — your Apple Developer Team ID
#   CODE_SIGN_IDENTITY  — "Apple Development" (requires team) or "-" (ad-hoc)

# Capture env overrides before setting defaults.
_env_team="${DEVELOPMENT_TEAM+set}"
_env_identity="${CODE_SIGN_IDENTITY+set}"
_env_tier="${ENTITLEMENTS_TIER+set}"

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
ENTITLEMENTS_TIER="${ENTITLEMENTS_TIER:-3}"
if [ -f "resources/build.xcconfig" ]; then
    while IFS='= ' read -r key value; do
        [[ -z "$key" || "$key" == "//"* || "$key" == "#"* ]] && continue
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        case "$key" in
            DEVELOPMENT_TEAM)   [ -z "$_env_team" ]    && DEVELOPMENT_TEAM="$value" ;;
            CODE_SIGN_IDENTITY) [ -z "$_env_identity" ] && CODE_SIGN_IDENTITY="$value" ;;
            ENTITLEMENTS_TIER)  [ -z "$_env_tier" ]     && ENTITLEMENTS_TIER="$value" ;;
        esac
    done < "resources/build.xcconfig"
fi

CONFIG="${1:-release}"

# Entitlement tiers: 3 = full (bridge + USB), 2 = USB only, 1 = base
ENTITLEMENTS_TIER="${ENTITLEMENTS_TIER:-3}"
case "$ENTITLEMENTS_TIER" in
    1) ENTITLEMENTS="resources/entitlements-tier1.plist" ;;
    2) ENTITLEMENTS="resources/entitlements-tier2.plist" ;;
    *) ENTITLEMENTS="resources/entitlements.plist" ;;
esac

echo "==> Building havm ($CONFIG) [tier $ENTITLEMENTS_TIER]..."
echo "    Team:      ${DEVELOPMENT_TEAM:-(none)}"
echo "    Identity:  $CODE_SIGN_IDENTITY"

# --- Build -------------------------------------------------------------------
# Remove symlink from old build.sh versions that linked the binary into the
# .app bundle. swift build would follow it and write into a directory we need
# to rm -rf below.
if [ "$CONFIG" = "release" ]; then
    BINARY=".build/release/havm"
else
    BINARY=".build/debug/havm"
fi
[ -L "$BINARY" ] && rm -f "$BINARY"

if [ "$CONFIG" = "release" ]; then
    swift build -c release --product havm
else
    swift build --product havm
fi

# --- Sign --------------------------------------------------------------------
SIGN_IDENTITY="$CODE_SIGN_IDENTITY"

# Always create .app bundle for consistent output structure.
APP_DIR=".build/Havm.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY" "$APP_DIR/Contents/MacOS/havm"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>havm</string>
    <key>CFBundleIdentifier</key>
    <string>ch.ingmar.havm</string>
    <key>CFBundleName</key>
    <string>Havm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

if [ -n "$DEVELOPMENT_TEAM" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    # Real identity: embed provisioning profile for restricted entitlements.
    PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    FOUND_PROFILE=""

    if echo "$SIGN_IDENTITY" | grep -q "Developer ID"; then
        for f in "$PROFILE_DIR"/*.provisionprofile; do
            [ -f "$f" ] || continue
            PROFILE_XML=$(security cms -D -i "$f" 2>/dev/null || true)
            if echo "$PROFILE_XML" | grep -q "ch.ingmar.havm" && \
               echo "$PROFILE_XML" | grep -q "ProvisionsAllDevices"; then
                FOUND_PROFILE="$f"
                break
            fi
        done
    fi

    if [ -z "$FOUND_PROFILE" ]; then
        for f in "$PROFILE_DIR"/*.provisionprofile; do
            [ -f "$f" ] || continue
            if security cms -D -i "$f" 2>/dev/null | grep -q "ch.ingmar.havm"; then
                FOUND_PROFILE="$f"
                break
            fi
        done
    fi

    if [ -n "$FOUND_PROFILE" ]; then
        cp "$FOUND_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
        echo "    Profile:   $(basename "$FOUND_PROFILE")"
    fi

    codesign --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --force \
        --options runtime --timestamp \
        "$APP_DIR" 2>&1 | grep -v "replacing" || true
else
    # Ad-hoc signing — restricted entitlements are stripped.
    echo "    (ad-hoc signing — restricted entitlements unavailable)"
    codesign --sign - \
        --entitlements "$ENTITLEMENTS" \
        --force \
        --options runtime --timestamp \
        "$APP_DIR" 2>&1 | grep -v "replacing" || true
fi

ln -sf "$PWD/$APP_DIR/Contents/MacOS/havm" "$BINARY"
echo "==> Done: $BINARY ($APP_DIR)"
"$BINARY" version
