#!/bin/bash
# Builds btrfs4mac.app, signs it ad hoc (no Apple account, no notarization) and
# installs it to /Applications (or ~/Applications). Usage: scripts/build.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.3.0}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/btrfs4mac"

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-dirty"
APP="build/btrfs4mac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/btrfs4mac"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.btrfs4mac</string>
  <key>CFBundleName</key><string>btrfs4mac</string>
  <key>CFBundleExecutable</key><string>btrfs4mac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>Btrfs4MacCommit</key><string>$COMMIT</string>
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
  rm -rf "$DEST/btrfs4mac.app" "$HOME/Applications/btrfs4mac.app" "$DEST/GDrive.app" "$HOME/Applications/GDrive.app"
  cp -R "$APP" "$DEST/btrfs4mac.app"
  echo "Installed: $DEST/btrfs4mac.app"
fi
