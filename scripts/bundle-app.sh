#!/bin/bash
# Wraps the release binary in build/Evlat.app. No Dock icon.
#
# Signing: ad-hoc by default, so `make bundle` / `make run` stay offline and
# never touch the keychain. EVLAT_SIGN_IDENTITY (e.g. "Developer ID
# Application: …") signs with that identity instead, with the hardened runtime
# and a secure timestamp — both are required by notarization (`make release`).
# No entitlements: the app is not sandboxed, uses no JIT, and the hardened
# runtime does not restrict spawning `claude`, `ssh` or `curl`.
#
# Updates: EVLAT_FEED_URL and EVLAT_ED_KEY (Sparkle's public key) go into
# Info.plist together or not at all. `make release` passes both; a bundle
# without them has no updater (`Updater.feed`), so a development build never
# offers to replace itself with the release.
#
# Version: EVLAT_VERSION (x.y.z) and EVLAT_BUILD (an integer) are written into
# Info.plist; `make release` passes them. Without them the bundle says 0.0.0
# (0), so a development build can never be mistaken for a release.
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

# The string tables (Resources/*.lproj/Evlat.strings) are checked before
# the bundle is torn down: one broken line drops a whole table at runtime.
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

# Sparkle. `ditto` keeps the framework's Versions/Current symlinks. The XPC
# services are only for sandboxed hosts, and Evlat is not one: removed, they
# are two fewer things to sign and notarize. SwiftPM links the binary against
# @rpath but only looks next to it (@loader_path); in the bundle the framework
# is in ../Frameworks. install_name_tool breaks the linker's signature — the
# signing below replaces it.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto ".build/release/Sparkle.framework" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/B/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Evlat"
for l in Resources/*.lproj; do [ -d "$l" ] && cp -R "$l" "$APP/Contents/Resources/"; done

# The app icon is drawn by scripts/make-icon.swift — its only source; no image
# is checked in. Redrawn only when the script is newer than the cached .icns,
# so an ordinary `make bundle` pays nothing.
ICON=".build/AppIcon.icns"
if [ ! -f "$ICON" ] || [ scripts/make-icon.swift -nt "$ICON" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICON"
  rm -rf "$(dirname "$ICONSET")"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

find "$APP" -name '.DS_Store' -delete

VERSION="${EVLAT_VERSION:-0.0.0}"
BUILD="${EVLAT_BUILD:-0}"
UPDATES=""
if [ -n "${EVLAT_FEED_URL:-}" ] || [ -n "${EVLAT_ED_KEY:-}" ]; then
  if [ -z "${EVLAT_FEED_URL:-}" ] || [ -z "${EVLAT_ED_KEY:-}" ]; then
    echo "EVLAT_FEED_URL and EVLAT_ED_KEY go together" >&2
    exit 1
  fi
  UPDATES="  <key>SUFeedURL</key><string>$EVLAT_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$EVLAT_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.kalaomer.evlat</string>
  <key>CFBundleName</key><string>Evlat</string>
  <key>CFBundleDisplayName</key><string>Evlat</string>
  <key>CFBundleExecutable</key><string>Evlat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Evlat</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
$UPDATES
</dict>
</plist>
PLIST

# The exit status is NOT swallowed. This call binds Info.plist and Resources
# into the seal — it is the reason .DS_Store is deleted above. A silent failure
# ships a half-sealed bundle that still launches today, and turns into a launch
# or TCC failure the moment a catalogue or an entitlement is added, with nothing
# pointing back here.
IDENTITY="${EVLAT_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
fi
# Inside out: each nested executable before what contains it, the app last.
# `--deep` would sign them all with the app's options, which Apple advises
# against for anything that is shipped.
for item in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
  "${SIGN[@]}" "$item" || { echo "codesign failed on $item" >&2; exit 1; }
done
if ! "${SIGN[@]}" "$APP"; then
  echo "codesign failed; the bundle is not sealed" >&2
  exit 1
fi
echo "Ready: $APP"
echo "Run: open $APP"
