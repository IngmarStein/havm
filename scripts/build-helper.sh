#!/bin/bash
# Build havm-connect.app bundle from the SPM target.
# Signs with ad-hoc or provisioning profile.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
SIGN_MODE="${2:-dev}"

echo "==> Building havm-connect ($CONFIG)..."

if [ "$CONFIG" = "release" ]; then
    swift build -c release --product havm-connect
    BINARY=".build/release/havm-connect"
else
    swift build --product havm-connect
    BINARY=".build/debug/havm-connect"
fi

APP_DIR=".build/havm-connect.app"
rm -rf "$APP_DIR"

# Create .app bundle structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/havm-connect"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>havm-connect</string>
    <key>CFBundleIdentifier</key>
    <string>ch.ingmar.havm</string>
    <key>CFBundleName</key>
    <string>havm-connect</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Built $APP_DIR"

# Sign
if [ "$SIGN_MODE" = "provisioning" ]; then
    echo "==> Signing with provisioning profile..."
    # Use the provisioning profile from Xcode's managed profiles
    # xcodebuild can sign it if the entitlement is granted
    xcodebuild -scheme havm-connect \
        -workspace .swiftpm/xcode/package.xcworkspace 2>/dev/null && true
    ENTITLEMENTS="havm-connect/entitlements-helper.plist"
else
    ENTITLEMENTS="havm-connect/entitlements-helper.plist"
    echo "==> Ad-hoc signing (USB passthrough will not work)..."
fi

codesign --sign - \
    --entitlements "$ENTITLEMENTS" \
    --force \
    "$APP_DIR" 2>&1 | grep -v "replacing" || true

echo "==> Done: $APP_DIR"
echo "    Note: USB passthrough requires a provisioning profile with"
echo "    com.apple.developer.accessory-access.usb. Ad-hoc signing cannot"
echo "    include this restricted entitlement."
echo ""
echo "    To build with a provisioning profile, open Package.swift in"
echo "    Xcode, configure the havm-connect target with Personal Team"
echo "    signing and the Accessory Access capability, then build from"
echo "    Xcode. Copy the resulting .app from DerivedData."
