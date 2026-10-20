#!/bin/zsh
# Builds FanPilot.app into ./build
set -e
cd "$(dirname "$0")"
APP=build/FanPilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

clang -O2 -Wall -framework IOKit -framework CoreFoundation Sources/smc.c Sources/fanctl.c -o "$APP/Contents/MacOS/fanctl"
swiftc -O -parse-as-library -target arm64-apple-macos14 Sources/*.swift -o "$APP/Contents/MacOS/FanPilot"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FanPilot</string>
  <key>CFBundleIdentifier</key><string>local.fanpilot</string>
  <key>CFBundleExecutable</key><string>FanPilot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

codesign --force --deep --sign - "$APP"
echo "Built $APP"

# ./build.sh install  → copy into /Applications (needed for "Open at login") and launch it.
if [[ "$1" == "install" ]]; then
  pkill -x FanPilot 2>/dev/null || true
  rm -rf /Applications/FanPilot.app
  cp -R "$APP" /Applications/
  open /Applications/FanPilot.app
  echo "Installed /Applications/FanPilot.app"
fi
