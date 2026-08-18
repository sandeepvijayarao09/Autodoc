#!/bin/bash
# Build Autodoc.app: compile, wrap into a .app bundle (with icon), and codesign.
#
# Signing identity preference:  Developer ID  →  "Autodoc Local Signing"
# (stable, self-signed — run ./make-signing-cert.sh once to create it)  →  ad-hoc.
# A STABLE identity is what stops macOS from re-asking for Screen Recording and
# Keychain access on every rebuild. Set AUTODOC_ADHOC=1 to force an ad-hoc build.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Autodoc.app"
CONFIG="${1:-release}"

echo "▶︎ swift build ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Autodoc"

echo "▶︎ app icon…"
swift makeicon.swift build/Autodoc.iconset >/dev/null
iconutil -c icns build/Autodoc.iconset -o build/Autodoc.icns

echo "▶︎ assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"                  "$APP/Contents/MacOS/Autodoc"
# Stamp the single-sourced version (Info.plist ships with placeholders).
VERSION="$(tr -d ' \t\n\r' < VERSION)"
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/dev/" \
    Info.plist > "$APP/Contents/Info.plist"
cp build/Autodoc.icns     "$APP/Contents/Resources/Autodoc.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY=""
if [ "${AUTODOC_ADHOC:-}" != "1" ]; then
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
                | grep 'Developer ID Application' | head -1 | awk '{print $2}' || true)"
    [ -z "$IDENTITY" ] && IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
                | grep 'Autodoc Local Signing' | head -1 | awk '{print $2}' || true)"
fi

if [ -n "$IDENTITY" ]; then
    echo "▶︎ codesign (stable identity ${IDENTITY:0:12}…)"
    echo "   note: on the FIRST signed build macOS asks to let codesign use the key —"
    echo "         click “Always Allow”. Permissions then persist across rebuilds."
    codesign --force --options runtime --entitlements Autodoc.entitlements \
             --identifier io.github.sandeepvijayarao09.Autodoc --sign "$IDENTITY" "$APP"
else
    echo "▶︎ codesign (ad-hoc — Screen Recording resets on each rebuild;"
    echo "   run ./make-signing-cert.sh once to fix that)"
    codesign --force --options runtime --entitlements Autodoc.entitlements \
             --identifier io.github.sandeepvijayarao09.Autodoc --sign - "$APP"
fi

echo "✓ built $APP"
echo "  run:  open $APP"
