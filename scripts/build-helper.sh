#!/bin/bash
# Build havm-helper.app bundle from the SPM target.
# Signs with ad-hoc or provisioning profile.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
SIGN_MODE="${2:-dev}"

echo "==> Building havm-helper ($CONFIG)..."

if [ "$CONFIG" = "release" ]; then
    swift build -c release --product havm-helper
    BINARY=".build/release/havm-helper"
else
    swift build --product havm-helper
    BINARY=".build/debug/havm-helper"
fi

APP_DIR=".build/havm-helper.app"
rm -rf "$APP_DIR"

# Create .app bundle structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/havm-helper"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>havm-helper</string>
    <key>CFBundleIdentifier</key>
    <string>dev.havm.helper</string>
    <key>CFBundleName</key>
    <string>havm-helper</string>
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
    xcodebuild -scheme havm-helper \
        -workspace .swiftpm/xcode/package.xcworkspace 2>/dev/null && true
    ENTITLEMENTS="resources/entitlements-helper.plist"
else
    ENTITLEMENTS="resources/entitlements-helper.plist"
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
echo "    Xcode, configure the havm-helper target with Personal Team"
echo "    signing and the Accessory Access capability, then build from"
echo "    Xcode. Copy the resulting .app from DerivedData."
