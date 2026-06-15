#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building havm..."

xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
    -scheme havm \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Release \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM=ADVP2P7SJK \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_ENTITLEMENTS=resources/entitlements-dev.plist \
    2>&1 | grep -E "BUILD|error|Signing" | grep -v "DVTDownloadable\|IDELogStore\|IDERunDestination\|trusted\|Selecting\|PIF\|signing\|note:|SwiftUICore"

BIN_DIR=".build/release"
mkdir -p "$BIN_DIR"
SRC=$(find ~/Library/Developer/Xcode/DerivedData/av-cli-*/Build/Products/Release \
    -name havm -type f ! -path "*.dSYM*" 2>/dev/null | tail -1)
if [ -n "$SRC" ] && [ -f "$SRC" ]; then
    cp "$SRC" "$BIN_DIR/havm"
fi

echo "==> Done: $BIN_DIR/havm"
"$BIN_DIR/havm" version
