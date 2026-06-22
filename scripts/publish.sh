#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$PWD"

# havm publish — Build, sign, notarize, and create a GitHub release.
#
# Prerequisites:
#   - Developer ID Application certificate in keychain
#   - notarytool credentials stored via:
#       xcrun notarytool store-credentials "AC_PASSWORD" \
#           --apple-id "your@email.com" --team-id "ADVP2P7SJK"
#   - gh CLI authenticated
#
# Usage:
#   ./scripts/publish.sh                # use current git tag / HEAD
#   ./scripts/publish.sh 0.2.0          # create tag v0.2.0 and release

NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Ingmar Stein (ADVP2P7SJK)}"

# --- Parse version -----------------------------------------------------------
if [ $# -ge 1 ]; then
    VERSION="$1"
    TAG="v${VERSION}"
else
    TAG=$(git describe --tags --exact-match 2>/dev/null || true)
    if [ -z "$TAG" ]; then
        echo "Error: no version specified and HEAD is not tagged."
        echo "Usage: ./scripts/publish.sh <version>"
        echo "Example: ./scripts/publish.sh 0.2.0"
        exit 1
    fi
    VERSION="${TAG#v}"
fi

echo "==> Publishing havm v${VERSION}..."

# --- Verify prerequisites ----------------------------------------------------
echo "==> Checking prerequisites..."

if ! security find-identity -v -p basic | grep -q "Developer ID Application"; then
    echo "Error: No Developer ID Application certificate found in keychain."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    echo "Error: notarytool profile '$NOTARY_PROFILE' not found."
    echo "Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "        --apple-id \"your@email.com\" --team-id \"ADVP2P7SJK\""
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI not authenticated."
    exit 1
fi

# --- Build -------------------------------------------------------------------
echo "==> Building havm v${VERSION} (tier 2, Developer ID)..."

# Ensure version is set correctly in source
CURRENT_VERSION=$(grep 'static let current' Sources/Havm/main.swift | sed 's/.*"\(.*\)".*/\1/')
if [ "$CURRENT_VERSION" != "$VERSION" ]; then
    echo "    Updating version: $CURRENT_VERSION -> $VERSION"
    sed -i '' "s/static let current = \"$CURRENT_VERSION\"/static let current = \"$VERSION\"/" Sources/Havm/main.swift
fi

CODE_SIGN_IDENTITY="$DEVELOPER_ID" ENTITLEMENTS_TIER=2 ./scripts/build.sh release

BINARY=".build/release/havm"
APP_DIR=".build/Havm.app"

# Verify binary runs
echo "==> Verifying binary..."
"$BINARY" version

# Verify hardened runtime on the .app bundle
echo "==> Verifying code signature..."
SIGN_INFO=$(codesign -dvvv "$APP_DIR" 2>&1)
if ! echo "$SIGN_INFO" | grep -q "runtime"; then
    echo "Error: hardened runtime not enabled."
    echo "$SIGN_INFO"
    exit 1
fi
echo "    Hardened runtime: OK"

# Verify provisioning profile is embedded (needed for restricted entitlements)
if [ -f "$APP_DIR/Contents/embedded.provisionprofile" ]; then
    echo "    Provisioning profile: OK"
else
    echo "    Warning: No provisioning profile in .app bundle — USB passthrough won't work"
fi

# --- Package -----------------------------------------------------------------
echo "==> Packaging..."
ZIP=".build/release/havm.zip"

# Zip the entire .app bundle so the provisioning profile stays with the binary.
# Include a version file alongside to prevent Homebrew from cd-ing into
# the single-directory archive during staging.
echo "$VERSION" > .build/VERSION
rm -f "$ZIP"
(cd .build && zip -qr "$PROJECT_DIR/$ZIP" Havm.app VERSION)
rm -f .build/VERSION
echo "    $ZIP ($(wc -c < "$ZIP" | xargs) bytes)"

# --- Notarize ----------------------------------------------------------------
echo "==> Submitting for notarization..."
SUBMIT_OUTPUT=$(xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout 5m 2>&1)

if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
    echo "    Notarization: Accepted"
else
    echo "Error: notarization failed."
    echo "$SUBMIT_OUTPUT"
    # Try to get log
    SUBMIT_ID=$(echo "$SUBMIT_OUTPUT" | grep "id:" | head -1 | awk '{print $NF}')
    if [ -n "$SUBMIT_ID" ]; then
        echo "--- Notarization log ---"
        xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE"
    fi
    exit 1
fi

# --- GitHub release ----------------------------------------------------------
echo "==> Creating GitHub release..."

# Tag if needed
if ! git tag -l "$TAG" | grep -q "^$TAG$"; then
    echo "    Creating tag $TAG..."
    git tag "$TAG"
    git push origin "$TAG"
fi

# Check if release exists
if gh release view "$TAG" &>/dev/null; then
    echo "    Release $TAG exists, uploading asset..."
    # Delete existing havm.zip asset if present
    gh release delete-asset "$TAG" havm.zip --yes 2>/dev/null || true
    gh release upload "$TAG" "$ZIP"
else
    echo "    Creating release $TAG..."
    gh release create "$TAG" "$ZIP" \
        --title "havm v${VERSION}" \
        --generate-notes
fi

# --- Output ------------------------------------------------------------------
SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo ""
echo "===== Published havm v${VERSION} ====="
echo ""
echo "Formula snippet:"
echo ""
echo "  url \"https://github.com/IngmarStein/havm/releases/download/v${VERSION}/havm.zip\""
echo "  sha256 \"$SHA256\""
echo ""
