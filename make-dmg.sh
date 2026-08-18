#!/bin/bash
# Build a drag-to-Applications DMG around an app bundle.
#   ./make-dmg.sh <app-path> <dmg-path> <volume-name>
#
# Split out of release.sh so notarize.sh can rebuild the DMG *after* the app has
# been stapled — otherwise the copy of the app inside the DMG carries no ticket.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <dmg> <volname>}"
DMG="${2:?usage: make-dmg.sh <app> <dmg> <volname>}"
VOLNAME="${3:?usage: make-dmg.sh <app> <dmg> <volname>}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
               -ov -format UDZO "$DMG" >/dev/null
