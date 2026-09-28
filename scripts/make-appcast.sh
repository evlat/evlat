#!/bin/bash
# Writes Sparkle's appcast for one release: a single item, because the feed is
# served from GitHub's `releases/latest/download/appcast.xml`, which always
# names the newest release — the newest item is the only one ever read.
#
#   scripts/make-appcast.sh <app> <zip> <download-url> <out>
#
# The version and build are read back from the app's own Info.plist, so the
# feed can never disagree with what it points at. The zip is signed with the
# EdDSA key in the login keychain (Sparkle's `generate_keys`); `sign_update`
# prints the enclosure's `sparkle:edSignature` and `length` attributes.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"; ZIP="$2"; URL="$3"; OUT="$4"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "No $SIGN_UPDATE; run swift package resolve" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
MINIMUM=$(plutil -extract LSMinimumSystemVersion raw "$PLIST")
SIGNATURE=$("$SIGN_UPDATE" "$ZIP")
case "$SIGNATURE" in
  *sparkle:edSignature=*) ;;
  *) echo "sign_update gave no signature: $SIGNATURE" >&2; exit 1 ;;
esac
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Evlat</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT"
echo "Appcast: $OUT ($VERSION, build $BUILD)"
