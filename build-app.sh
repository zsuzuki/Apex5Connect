#!/bin/zsh
set -euo pipefail

swift build -c release

APP="Apex5Connect.app"
EXECUTABLE=".build/release/Apex5Connect"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/Apex5Connect"

if [ -x "$APP/Contents/MacOS/blueutil" ]; then
  :
elif [ -x "/opt/homebrew/bin/blueutil" ]; then
  cp "/opt/homebrew/bin/blueutil" "$APP/Contents/MacOS/blueutil"
elif [ -x "/usr/local/bin/blueutil" ]; then
  cp "/usr/local/bin/blueutil" "$APP/Contents/MacOS/blueutil"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Apex5Connect</string>
  <key>CFBundleIconFile</key>
  <string>applet.icns</string>
  <key>CFBundleIdentifier</key>
  <string>com.y-suzuki.apex5connect</string>
  <key>CFBundleName</key>
  <string>Apex5Connect</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>APEX5の登録削除とペアリングを実行するためにBluetoothへアクセスします。</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$APP/Contents/MacOS/Apex5Connect"
