#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Configuration -----------------------------------------------------------
# Defaults (safe: ad-hoc signing, unrestricted entitlements only)
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-ch.ingmar.havm}"
ENABLE_USB_ACCESSORY="${ENABLE_USB_ACCESSORY:-NO}"
ENABLE_BRIDGE_NETWORKING="${ENABLE_BRIDGE_NETWORKING:-NO}"

# Override from build.xcconfig if present
XCCONFIG="resources/build.xcconfig"
if [ -f "$XCCONFIG" ]; then
    while IFS='= ' read -r key value; do
        [[ -z "$key" || "$key" == "//"* || "$key" == "#"* || "$key" == \#include* ]] && continue
        value="${value%%#*}"                          # strip trailing comment
        value="${value%"${value##*[![:space:]]}"}"   # trim trailing whitespace
        value="${value#"${value%%[![:space:]]*}"}"   # trim leading whitespace
        case "$key" in
            DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|BUNDLE_IDENTIFIER|ENABLE_USB_ACCESSORY|ENABLE_BRIDGE_NETWORKING)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$XCCONFIG"
fi

# Resolve booleans
usb_enabled=false; bridge_enabled=false
case "$(echo "$ENABLE_USB_ACCESSORY" | tr '[:upper:]' '[:lower:]')" in yes|true|1) usb_enabled=true ;; esac
case "$(echo "$ENABLE_BRIDGE_NETWORKING" | tr '[:upper:]' '[:lower:]')" in yes|true|1) bridge_enabled=true ;; esac
has_restricted=false; $usb_enabled && has_restricted=true; $bridge_enabled && has_restricted=true

# Select entitlements file
if $usb_enabled && $bridge_enabled; then
    ENTITLEMENTS="resources/entitlements.plist"
elif $usb_enabled; then
    ENTITLEMENTS="resources/entitlements-dev.plist"
elif $bridge_enabled; then
    ENTITLEMENTS="resources/entitlements-bridge.plist"
else
    ENTITLEMENTS="resources/entitlements-base.plist"
fi

# If no team and using restricted entitlements, fall back to ad-hoc
if [ -z "$DEVELOPMENT_TEAM" ] && $has_restricted; then
    echo "Warning: Restricted entitlements require DEVELOPMENT_TEAM. Falling back to ad-hoc."
    CODE_SIGN_IDENTITY="-"
    ENTITLEMENTS="resources/entitlements-base.plist"
    has_restricted=false; usb_enabled=false; bridge_enabled=false
fi

CONFIG="${1:-release}"

echo "==> Building havm ($CONFIG)..."
echo "    Team:      ${DEVELOPMENT_TEAM:-(none)}"
echo "    Identity:  $CODE_SIGN_IDENTITY"
echo "    USB:       $usb_enabled"
echo "    Bridge:    $bridge_enabled"
echo "    Entitlements: $(basename "$ENTITLEMENTS")"

# --- Build -------------------------------------------------------------------
if [ "$CONFIG" = "release" ]; then
    swift build -c release --product havm
    BINARY=".build/release/havm"
else
    swift build --product havm
    BINARY=".build/debug/havm"
fi

# Wrap in a minimal .app bundle so restricted entitlements get a provisioning
# profile. With ad-hoc signing + unrestricted entitlements, skip the bundle.
if $has_restricted; then
    APP_DIR=".build/Havm.app"
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS"
    cp "$BINARY" "$APP_DIR/Contents/MacOS/havm"

    # Find a managed provisioning profile for our bundle ID.
    for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
        [ -f "$f" ] || continue
        if security cms -D -i "$f" 2>/dev/null | grep -q "$BUNDLE_IDENTIFIER"; then
            cp "$f" "$APP_DIR/Contents/embedded.provisionprofile"
            echo "    Profile:   $(basename "$f")"
            break
        fi
    done
    if [ ! -f "$APP_DIR/Contents/embedded.provisionprofile" ]; then
        echo "    Warning: no provisioning profile found for $BUNDLE_IDENTIFIER."
        echo "    Open havm-connect.xcodeproj in Xcode, build once with your"
        echo "    team, and the profile will be generated automatically."
    fi

    cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>havm</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleName</key>
    <string>Havm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

    codesign --sign "$CODE_SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --force \
        "$APP_DIR" 2>&1 | grep -v "replacing" || true

    # Symlink so .build/release/havm resolves to the signed bundle binary.
    ln -sf "$PWD/$APP_DIR/Contents/MacOS/havm" "$BINARY"
else
    # Unrestricted entitlements only — sign the bare binary with ad-hoc.
    codesign --sign - \
        --entitlements "$ENTITLEMENTS" \
        --force \
        "$BINARY" 2>&1 | grep -v "replacing" || true
fi

echo "==> Done: $BINARY"
"$BINARY" version
