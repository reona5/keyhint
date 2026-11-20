#!/usr/bin/env bash
# Builds Keyhint.app into ./build. Accessibility permission is tied to the code signature,
# so with ad-hoc signing you have to re-grant it after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app=build/Keyhint.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Keyhint "$app/Contents/MacOS/Keyhint"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.reona5.keyhint</string>
  <key>CFBundleName</key><string>Keyhint</string>
  <key>CFBundleExecutable</key><string>Keyhint</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "${KEYHINT_SIGN_IDENTITY:--}" "$app"
echo "built $app"
