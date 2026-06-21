#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
IDENTITY="Apple Development"
TEAM="ADVP2P7SJK"
ENTITLEMENTS="resources/entitlements-dev.plist"

echo "==> Building havm ($CONFIG)..."

if [ "$CONFIG" = "release" ]; then
    swift build -c release --product havm
    BINARY=".build/release/havm"
else
    swift build --product havm
    BINARY=".build/debug/havm"
fi

# Wrap in a minimal .app bundle so Xcode's provisioning profile covers
# the restricted entitlements (accessory-access.usb needs a bundle).
APP_DIR=".build/Havm.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY" "$APP_DIR/Contents/MacOS/havm"

# Find the managed provisioning profile that covers our bundle ID.
# Xcode stores these in UserData/Provisioning Profiles.
PROFILE=""
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
    [ -f "$f" ] || continue
    if security cms -D -i "$f" 2>/dev/null | grep -q "ch.ingmar.havm-connect"; then
        PROFILE="$f"
        break
    fi
done
if [ -n "$PROFILE" ]; then
    cp "$PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
    echo "  Embedded profile: $(basename "$PROFILE")"
else
    echo "  Warning: no provisioning profile for ch.ingmar.havm-connect."
    echo "  Build HAVM Connect in Xcode once to generate one."
fi

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>havm</string>
    <key>CFBundleIdentifier</key>
    <string>ch.ingmar.havm-connect</string>
    <key>CFBundleName</key>
    <string>Havm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

codesign --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --force \
    "$APP_DIR" 2>&1 | grep -v "replacing" || true

# Symlink the signed binary for convenience — it must stay inside the
# .app bundle for restricted entitlements to work.
ln -sf "$PWD/$APP_DIR/Contents/MacOS/havm" "$BINARY"

echo "==> Done: $APP_DIR (symlinked at $BINARY)"
"$BINARY" version
