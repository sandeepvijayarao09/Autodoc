#!/bin/bash
# Full "as Apple ships it" release pipeline:
#   test → compile → icon → bundle → Hardened Runtime sign (+entitlements) → verify → DMG
#
# The version comes from ./VERSION and is stamped into Info.plist at build time,
# so there is exactly one place to bump it.
#
# Uses a real "Developer ID Application" identity automatically if one exists in
# your keychain; otherwise falls back to an ad-hoc hardened signature so the
# artifact is byte-for-byte the same shape Apple expects — only the certificate
# (and the later notarization ticket) differ.
#
# For a distributable build, run ./notarize.sh afterwards: it notarizes and
# staples the app, then rebuilds and notarizes the DMG around the stapled app.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Autodoc"
BUNDLE_ID="io.github.sandeepvijayarao09.Autodoc"
VERSION="$(tr -d ' \t\n\r' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"

echo "▶︎ 0/7  tests…"
swift test 2>&1 | tail -3

echo "▶︎ 1/7  compile (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "▶︎ 2/7  app icon…"
swift makeicon.swift build/${APP_NAME}.iconset >/dev/null
iconutil -c icns build/${APP_NAME}.iconset -o build/${APP_NAME}.icns

echo "▶︎ 3/7  assemble ${APP}  (v${VERSION}, build ${BUILD_NUMBER})…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"                    "$APP/Contents/MacOS/${APP_NAME}"
cp build/${APP_NAME}.icns   "$APP/Contents/Resources/${APP_NAME}.icns"
cp PrivacyInfo.xcprivacy    "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
# Stamp the single-sourced version into the bundle.
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD_NUMBER}/" \
    Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶︎ 4/7  codesign (Hardened Runtime)…"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep 'Developer ID Application' | head -1 | awk '{print $2}' || true)"
if [ -n "${IDENTITY:-}" ]; then
    echo "    using Developer ID: $IDENTITY"
    codesign --force --options runtime --timestamp \
             --entitlements Autodoc.entitlements \
             --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
    SIGNED_REAL=1
else
    echo "    no Developer ID cert found → ad-hoc Hardened Runtime signature"
    echo "    (enroll in the Apple Developer Program to sign + notarize for real)"
    codesign --force --options runtime \
             --entitlements Autodoc.entitlements \
             --identifier "$BUNDLE_ID" --sign - "$APP"
    SIGNED_REAL=0
fi

echo "▶︎ 5/7  verify…"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo "    gatekeeper assessment:"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/      /' || \
    echo "      (rejected — expected until notarized with a real Developer ID)"

echo "▶︎ 6/7  DMG (drag-to-install)…"
./make-dmg.sh "$APP" "$DMG" "$APP_NAME"
if [ "$SIGNED_REAL" = "1" ]; then codesign --force --sign "$IDENTITY" "$DMG"; fi

echo "▶︎ 7/7  done"
echo "  app : $APP"
echo "  dmg : $DMG   ($(du -h "$DMG" | awk '{print $1}'))"
if [ "$SIGNED_REAL" = "1" ]; then
    echo "  next: ./notarize.sh   (notarize + staple the app, rebuild + notarize the DMG)"
else
    echo "  next: enroll → get a Developer ID cert → re-run → ./notarize.sh"
fi
