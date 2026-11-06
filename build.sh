#!/bin/bash
# Builds build/SimBar.app (universal arm64 + x86_64, macOS 15+, with Sparkle). Installs nothing:
# use scripts/install-local.sh for that, and scripts/release.sh to ship.
#
# Signing: ad-hoc by default, so anyone can build from source. For distribution set
#   SIMBAR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
# to sign with the hardened runtime and a secure timestamp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
source scripts/sparkle.sh

APP=build/SimBar.app
MIN_MACOS=15.0   # the app relies on /usr/bin/jq, which ships with macOS 15+
BUNDLE_ID=com.motystudio.simbar
FEED_URL=https://github.com/motystudio/SimLease/releases/latest/download/appcast.xml
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
IDENTITY=${SIMBAR_SIGN_IDENTITY:--}

if [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
  echo "error: signing identity not found in the keychain: $IDENTITY" >&2
  echo "       list yours with: security find-identity -v -p codesigning" >&2
  exit 1
fi

fetch_sparkle

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" build/obj

# --- compile: one slice per architecture, then lipo ---------------------------------------
for arch in arm64 x86_64; do
  echo "Compiling $arch..."
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos$MIN_MACOS" \
    -F "$SPARKLE_DIR" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -module-cache-path build/obj/ModuleCache \
    app/*.swift -o "build/obj/SimBar-$arch"
done
lipo -create build/obj/SimBar-arm64 build/obj/SimBar-x86_64 -output "$APP/Contents/MacOS/SimBar"

# --- Info.plist ------------------------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>SimBar</string>
  <key>CFBundleDisplayName</key><string>SimBar</string>
  <key>CFBundleExecutable</key><string>SimBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) Moty Studio LLC.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

PUBLIC_KEY=""
[[ -f packaging/sparkle-public-key.txt ]] && PUBLIC_KEY=$(tr -d '[:space:]' < packaging/sparkle-public-key.txt)
if [[ -n "$PUBLIC_KEY" ]]; then
  plutil -insert SUPublicEDKey -string "$PUBLIC_KEY" "$APP/Contents/Info.plist"
else
  echo "warning: packaging/sparkle-public-key.txt is missing or empty; SUPublicEDKey omitted," >&2
  echo "         so this build cannot verify Sparkle updates (fine for local builds)." >&2
fi
plutil -lint -s "$APP/Contents/Info.plist"

# --- resources and frameworks ----------------------------------------------------------------
# what SimBar's Setup menu installs into ~/.claude
cp bin/sim-lease CLAUDE.snippet.md "$APP/Contents/Resources/"

# app icon: every size macOS asks for, from the 1024 px master
ICONSET=build/obj/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s packaging/icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) packaging/icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# --- signing, inside-out (no --deep), as Sparkle documents for builds outside Xcode -----------
if [[ "$IDENTITY" == "-" ]]; then
  SIGN=(codesign --force --sign -)
  echo "Signing ad-hoc (set SIMBAR_SIGN_IDENTITY for a distributable build)"
else
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
  echo "Signing with $IDENTITY (hardened runtime)"
fi

FW="$APP/Contents/Frameworks/Sparkle.framework"
for xpc in "$FW"/Versions/B/XPCServices/*.xpc; do
  [[ -e "$xpc" ]] || continue
  if [[ "$(basename "$xpc")" == Downloader.xpc ]]; then
    "${SIGN[@]}" --preserve-metadata=entitlements "$xpc"
  else
    "${SIGN[@]}" "$xpc"
  fi
done
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" "$APP"

codesign --verify --strict --deep "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
