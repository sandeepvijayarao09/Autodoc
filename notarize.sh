#!/bin/bash
# Notarize and staple for distribution. This is the ONLY step that requires a
# paid Apple Developer account.
#
# Ordering matters. The app must be notarized and stapled BEFORE the DMG is
# built, otherwise the copy of the app inside the DMG has no ticket of its own
# and only benefits from the DMG's. So:
#
#   1. zip the app → notarize the app → staple the app
#   2. rebuild the DMG around the stapled app
#   3. notarize the DMG → staple the DMG
#
# One-time credential setup (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials autodoc-notary \
#       --apple-id "you@example.com" --team-id "ABCDE12345" --password "xxxx-xxxx-xxxx-xxxx"
#
# Then just:  ./notarize.sh              (uses profile "autodoc-notary")
#         or  ./notarize.sh <profile>
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${1:-autodoc-notary}"
APP_NAME="Autodoc"
VERSION="$(tr -d ' \t\n\r' < VERSION)"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"
ZIP="build/${APP_NAME}-${VERSION}.zip"

[ -d "$APP" ] || { echo "✗ $APP not found — run ./release.sh first"; exit 1; }

# Refuse to waste a submission on an ad-hoc signature.
if codesign -dvv "$APP" 2>&1 | grep -q 'Signature=adhoc'; then
    echo "✗ $APP is ad-hoc signed. Notarization needs a real 'Developer ID"
    echo "  Application' certificate. Enroll at developer.apple.com, install the"
    echo "  cert, re-run ./release.sh, then this script."
    exit 1
fi

echo "▶︎ 1/5  submitting the app for notarization (profile: $PROFILE)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"

echo "▶︎ 2/5  stapling the app…"
xcrun stapler staple "$APP"

echo "▶︎ 3/5  rebuilding the DMG around the stapled app…"
./make-dmg.sh "$APP" "$DMG" "$APP_NAME"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
codesign --force --sign "$IDENTITY" "$DMG"

echo "▶︎ 4/5  notarizing + stapling the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "▶︎ 5/5  verifying Gatekeeper acceptance…"
spctl --assess --type execute --verbose=4 "$APP"
xcrun stapler validate "$DMG"

echo "✓ notarized + stapled. $DMG is ready to distribute."
