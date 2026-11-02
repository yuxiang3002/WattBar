#!/bin/bash
# 編譯 WattBar 並打包成 .app，再複製到「應用程式」資料夾
set -e
cd "$(dirname "$0")"

APP="build/WattBar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "找不到 swiftc，請先執行：xcode-select --install"
  exit 1
fi

ARCH="$(uname -m)"
echo "編譯中 (${ARCH})..."
swiftc -O -parse-as-library \
  -target "$ARCH-apple-macos13.0" \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/WattBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WattBar</string>
  <key>CFBundleDisplayName</key><string>WattBar</string>
  <key>CFBundleIdentifier</key><string>local.wattbar</string>
  <key>CFBundleExecutable</key><string>WattBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 本機自簽（ad-hoc），自己編的檔案不會有下載隔離標記
codesign --force --deep --sign - "$APP"

pkill -x WattBar 2>/dev/null || true
rm -rf /Applications/WattBar.app
cp -R "$APP" /Applications/
echo "完成，已安裝到 /Applications/WattBar.app"
open /Applications/WattBar.app
