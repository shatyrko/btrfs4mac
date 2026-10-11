#!/bin/bash
# Builds GDrive.app, signs it ad hoc (no Apple account, no notarization) and
# installs it to /Applications (or ~/Applications). Usage: scripts/build.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/GDrive"

APP="build/GDrive.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GDrive"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.g-drive</string>
  <key>CFBundleName</key><string>G-Drive</string>
  <key>CFBundleExecutable</key><string>GDrive</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"

if [ "${1:-}" != "--no-install" ]; then
  # /Applications is writable for admin users; fall back to ~/Applications otherwise
  DEST=/Applications
  [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  rm -rf "$DEST/GDrive.app" "$HOME/Applications/GDrive.app"
  cp -R "$APP" "$DEST/GDrive.app"
  echo "Installed: $DEST/GDrive.app"
fi
