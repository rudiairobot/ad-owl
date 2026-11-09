#!/bin/bash
# Builds Ad-Owl.app (release, ad-hoc signed) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Assets/AppIcon.icns ] || ./scripts/make-icon.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/HostShield"
APP="build/Ad-Owl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ad-Owl"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Ad-Owl</string>
  <key>CFBundleIdentifier</key><string>com.dintigger.hostshield</string>
  <key>CFBundleName</key><string>Ad-Owl</string>
  <key>CFBundleDisplayName</key><string>Ad-Owl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
