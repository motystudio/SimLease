#!/bin/bash
# Builds SimBar.app and installs it in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SimBar.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos14 -parse-as-library \
  app/SimBar.swift -o "$APP/Contents/MacOS/SimBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.motystudio.simbar</string>
  <key>CFBundleName</key><string>SimBar</string>
  <key>CFBundleExecutable</key><string>SimBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# what SimBar's Setup menu installs into ~/.claude
mkdir -p "$APP/Contents/Resources"
cp bin/sim-lease CLAUDE.snippet.md "$APP/Contents/Resources/"

codesign --force --sign - "$APP"

# a real copy (not a symlink into ~/Documents), so SimBar never triggers the Documents privacy prompt
mkdir -p "$HOME/.claude/bin"
rm -f "$HOME/.claude/bin/sim-lease"
install -m 755 bin/sim-lease "$HOME/.claude/bin/sim-lease"

mkdir -p "$HOME/Applications"
pkill -x SimBar 2>/dev/null || true
rm -rf "$HOME/Applications/SimBar.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed $HOME/Applications/SimBar.app"
