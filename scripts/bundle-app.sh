#!/bin/bash
# Wraps the release binary in build/Evlat.app. No Dock icon, ad-hoc signed.
#
# Ported from v1's script. DROPPED, and why:
#   - the Resources/pets copy and the tools/ pruning — v2 has no pets.
#   - five *UsageDescription plist keys — v2 asks for no permissions.
#   - the stable signing-identity block — its only reason was TCC folder
#     permissions resetting on every build, and v2 has no such surface. Dropping
#     it also removes the risk of codesign hanging forever on the keychain
#     prompt: `codesign --sign -` opens no dialog.
# KEPT, and why:
#   - plutil -lint BEFORE the bundle is torn down: a broken table must not leave
#     half an .app behind.
#   - deleting .DS_Store BEFORE signing: a file removed afterwards invalidates
#     the seal.
#   - LSUIElement: no Dock icon and no Cmd-Tab entry.
set -euo pipefail
cd "$(dirname "$0")/.."

# There are no string tables yet (004); when they arrive this loop checks them
# before the bundle is torn down.
shopt -s nullglob
for f in Resources/*.lproj/*.strings; do
  plutil -lint -s "$f" || { echo "Broken string table: $f"; exit 1; }
done
shopt -u nullglob

swift build -c release
BIN=".build/release/Evlat"
APP="build/Evlat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Evlat"
for l in Resources/*.lproj; do [ -d "$l" ] && cp -R "$l" "$APP/Contents/Resources/"; done

find "$APP" -name '.DS_Store' -delete

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.kalaomer.evlat</string>
  <key>CFBundleName</key><string>Evlat</string>
  <key>CFBundleDisplayName</key><string>Evlat</string>
  <key>CFBundleExecutable</key><string>Evlat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Evlat</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict>
</plist>
PLIST

# The exit status is NOT swallowed. This call binds Info.plist and Resources
# into the seal — it is the reason .DS_Store is deleted above. A silent failure
# ships a half-sealed bundle that still launches today, and turns into a launch
# or TCC failure the moment 004 adds a catalogue or an entitlement, with nothing
# pointing back here.
if ! codesign --force --sign - "$APP"; then
  echo "codesign failed; the bundle is not sealed" >&2
  exit 1
fi
echo "Ready: $APP"
echo "Run: open $APP"
