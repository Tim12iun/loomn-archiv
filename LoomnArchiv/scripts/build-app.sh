#!/bin/bash
# Baut LoomnArchiv.app (Apple Silicon) nach build/LoomnArchiv.app und packt LoomnArchiv.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-1}"
UPDATE_REPO="${UPDATE_REPO:-}"   # "besitzer/repo" mit öffentlichen Releases, leer = keine Updates

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/LoomnArchiv"

APP="build/Loomn Archiv.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LoomnArchiv"
cp -R Resources/Fonts Resources/Loader "$APP/Contents/Resources/"

# App-Symbol
ICON_SRC=Resources/AppIcon.png
if [ -f "$ICON_SRC" ]; then
  SET=build/AppIcon.iconset
  rm -rf "$SET"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Loomn Archiv</string>
  <key>CFBundleDisplayName</key><string>Loomn Archiv</string>
  <key>CFBundleIdentifier</key><string>de.loomn.archiv</string>
  <key>CFBundleExecutable</key><string>LoomnArchiv</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Loomn</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Die Mediathek liegt auf deiner externen SSD.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Die Mediathek kann auf einem Netzlaufwerk liegen.</string>
  <key>LoomnUpdateRepo</key><string>${UPDATE_REPO}</string>
</dict>
</plist>
PLIST

# Ad-hoc signiert (ohne Developer-Account). Beim ersten Öffnen: Rechtsklick › Öffnen.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

(cd build && rm -f LoomnArchiv.zip && ditto -c -k --keepParent "Loomn Archiv.app" LoomnArchiv.zip)
echo "Fertig: $APP"
