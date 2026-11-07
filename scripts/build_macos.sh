#!/bin/bash
set -euo pipefail
PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RELEASE_DIR="${1:-$PLUGIN_DIR/release}"
APP_DIR="$RELEASE_DIR/Usage Meter Pure.app"
# Rebuild the bundle from a clean directory so stale resources and metadata
# cannot invalidate the code signature.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "${TMPDIR:-/tmp}/usage-meter-swift-cache" \
  -framework AppKit -framework IOKit -framework SystemConfiguration \
  "$PLUGIN_DIR/macos/UsageMeter.swift" -o "$APP_DIR/Contents/MacOS/UsageMeter"
cp "$PLUGIN_DIR/macos/Resources/"* "$APP_DIR/Contents/Resources/"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Usage Meter Pure</string>
  <key>CFBundleDisplayName</key><string>Usage Meter Pure</string>
  <key>CFBundleIdentifier</key><string>cz.pure.usagemeter</string>
  <key>CFBundleExecutable</key><string>UsageMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.6.2</string>
  <key>CFBundleVersion</key><string>13</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>cs</string><string>en</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Usage Meter Pure otevře Terminál a spustí Claude Code, když kliknete na Obnovit Claude.</string>
</dict></plist>
PLIST
dot_clean -m "$APP_DIR"

# This project lives in a FileProvider-backed Documents directory.  That
# provider can add FinderInfo to a freshly created .app asynchronously; it is
# forbidden by codesign.  Clean only the release bundle and sign it in the
# same attempt.  A failure is never hidden: after the bounded retries this
# script exits non-zero.
has_disallowed_xattrs() {
  xattr -lr "$APP_DIR" 2>/dev/null | grep -qE 'com\.apple\.(FinderInfo|ResourceFork)'
}

signed=0
for attempt in 1 2 3 4 5 6 7 8; do
  xattr -cr "$APP_DIR"
  if has_disallowed_xattrs; then
    sleep 0.2
    continue
  fi

  if codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP_DIR" \
    && codesign --verify --deep --strict --verbose=4 "$APP_DIR" \
    && ! has_disallowed_xattrs; then
    signed=1
    break
  fi
  sleep 0.2
done

if [[ "$signed" -ne 1 ]]; then
  echo "codesign --force --deep --sign ${CODESIGN_IDENTITY:--} failed: FileProvider kept com.apple.FinderInfo on the release bundle" >&2
  exit 1
fi
printf '%s\n' "$APP_DIR"
