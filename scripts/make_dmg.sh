#!/bin/bash
# Build a drag-and-drop DMG (app + Applications symlink) from a built .app.
# Usage: bash scripts/make_dmg.sh <path-to-Usage Meter Pure.app> <output-dir> <name-without-extension>
# Uses only POSIX-friendly syntax, but the shebang is bash (like build_macos.sh).
# Does NOT sign or notarize anything. DMG files must never be committed.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <app-path> <output-dir> <name-without-extension>" >&2
  exit 2
fi
APP="${1%/}"
OUT_DIR="$2"
NAME="$3"
TARGET="$OUT_DIR/$NAME.dmg"

# Validate inputs; never create the output dir and never overwrite a DMG.
[ -f "$APP/Contents/Info.plist" ] || { echo "error: not an app bundle: $APP" >&2; exit 1; }
[ -d "$OUT_DIR" ] || { echo "error: output dir does not exist: $OUT_DIR" >&2; exit 1; }
if [ -e "$TARGET" ] || [ -e "$TARGET.sha256" ]; then
  echo "error: $TARGET (or its .sha256) already exists; refusing to overwrite" >&2
  exit 1
fi

# Staging folder outside the repo, always removed on exit.
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/usage-meter-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

# ditto keeps the code signature and extended attributes intact.
ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Usage Meter Pure" -srcfolder "$STAGING" -ov -format UDZO "$TARGET"

# Checksum in standard `shasum -a 256` format (relative file name, so -c works in OUT_DIR).
(cd "$OUT_DIR" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

# Report signing state of the app (informational only).
# Capture first: grep -q closing the pipe early would trip pipefail.
SIGINFO=$(codesign -dvv "$APP" 2>&1 || true)
if printf '%s\n' "$SIGINFO" | grep -q 'Signature=adhoc'; then
  echo "NOTE: app is ad-hoc signed only (not Developer ID, not notarized)."
else
  AUTH=$(printf '%s\n' "$SIGINFO" | grep '^Authority=' | head -1 || true)
  echo "App signing identity: ${AUTH:-none (unsigned?)}"
fi

echo "DMG: $TARGET"
cat "$TARGET.sha256"
