#!/bin/bash
# Builds build/btrfs4mac-<version>.dmg (the app and a shortcut to /Applications, to drag it across)
# and its SHA-256 file. Usage: VERSION=0.3.0 scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-0.3.0}"

scripts/build.sh --no-install

STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R build/btrfs4mac.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

OUT="build/btrfs4mac-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "btrfs4mac" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
(cd build && shasum -a 256 "btrfs4mac-$VERSION.dmg" > "btrfs4mac-$VERSION.dmg.sha256")
echo "Built $OUT"
cat "build/btrfs4mac-$VERSION.dmg.sha256"
