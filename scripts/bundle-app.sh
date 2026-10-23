#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD_DIR="${CAMP_BUILD_DIR:-$ROOT/.build}"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
swift build --scratch-path "$BUILD_DIR" -c release
BIN_DIR="$(swift build --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
APP="$ROOT/dist/Camp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/templates" "$APP/Contents/Resources/Camp/stack" "$APP/Contents/Resources/Camp/scripts"
ICONSET="$BUILD_DIR/Camp.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/draw-icon.swift" "$BUILD_DIR/Camp-icon-1024.png"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$BUILD_DIR/Camp-icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$BUILD_DIR/Camp-icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/Camp.icns"
cp "$BIN_DIR/Camp" "$APP/Contents/MacOS/Camp"
cp "$BUILD_DIR/Camp.icns" "$APP/Contents/Resources/Camp.icns"
cp "$ROOT/stack/templates/"* "$APP/Contents/Resources/templates/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/stack/versions.env" "$APP/Contents/Resources/Camp/stack/versions.env"
cp "$ROOT/stack/templates/"* "$APP/Contents/Resources/Camp/stack/"
cp "$ROOT/scripts/build-stack.sh" "$APP/Contents/Resources/Camp/scripts/build-stack.sh"
printf '%s\n' "$ROOT" > "$APP/Contents/Resources/source-root.txt"
xattr -cr "$APP"
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Camp</string>
  <key>CFBundleDisplayName</key>
  <string>Camp</string>
  <key>CFBundleIdentifier</key>
  <string>com.nelmez.camp</string>
  <key>CFBundleIconFile</key>
  <string>Camp</string>
  <key>CFBundleExecutable</key>
  <string>Camp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>VERSION_TOKEN</string>
  <key>CFBundleVersion</key>
  <string>VERSION_TOKEN</string>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
echo "Built $APP"
