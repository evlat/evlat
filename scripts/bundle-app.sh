#!/bin/bash
# Release ikilisini build/Evlat.app içine sarar. Dock ikonu yok, ad-hoc imzalı.
#
# v1'in betiğinden portlandı. DÜŞENLER ve neden:
#   - Resources/pets kopyası ve tools/ budaması — v2'de pet yok.
#   - Beş *UsageDescription plist anahtarı — v2 izin istemiyor.
#   - Kararlı imza kimliği bloğu — tek gerekçesi TCC klasör izinlerinin her
#     derlemede sıfırlanmasıydı; v2'de o yüzey yok. Düşmesi aynı zamanda
#     codesign'ın anahtarlık izin kutusunda süresiz asılma riskini de kaldırır:
#     `codesign --sign -` kutu açmaz.
# KALANLAR ve neden:
#   - plutil -lint paket YIKILMADAN önce: bozuk tablo yarım .app bırakmasın.
#   - .DS_Store silme imzadan ÖNCE: sonradan silinen dosya mührü geçersiz kılar.
#   - LSUIElement: Dock ikonu ve Cmd-Tab girişi olmasın.
set -euo pipefail
cd "$(dirname "$0")/.."

# Dil tabloları henüz yok (004); geldiğinde bu döngü onları paket yıkılmadan
# önce denetler.
shopt -s nullglob
for f in Resources/*.lproj/*.strings; do
  plutil -lint -s "$f" || { echo "Bozuk dil tablosu: $f"; exit 1; }
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

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Hazır: $APP"
echo "Çalıştır: open $APP"
