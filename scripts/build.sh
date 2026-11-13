#!/bin/zsh
# Builds DiskView.app and installs it into /Applications. Usage: scripts/build.sh [--run]
# The app is relaunched automatically if it was running.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use the full Xcode toolchain (SwiftUI macros aren't in the Command Line Tools).
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DiskView"

APP=build/DiskView.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskView"

if [[ ! -f build/AppIcon.icns || scripts/make_icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DiskView</string>
  <key>CFBundleDisplayName</key><string>DiskView</string>
  <key>CFBundleIdentifier</key><string>local.diskview.app</string>
  <key>CFBundleExecutable</key><string>DiskView</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign with your Apple Development certificate when there is one. macOS ties privacy grants
# (Full Disk Access) to the signer, so a stable certificate keeps them across rebuilds;
# an ad-hoc signature changes every build and silently drops them.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/"(Apple Development|Developer ID Application):/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier local.diskview.app --timestamp=none "$APP" >/dev/null
  echo "Signed with Apple Development certificate"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad-hoc (Full Disk Access will need re-granting after each rebuild)"
fi
echo "Built $PWD/$APP"

# Install: replace the copy in /Applications (quitting it first if it's running).
INSTALLED=/Applications/DiskView.app
WAS_RUNNING=0
if pgrep -x DiskView >/dev/null; then
  WAS_RUNNING=1
  osascript -e 'quit app "DiskView"' 2>/dev/null || true
  for _ in {1..20}; do pgrep -x DiskView >/dev/null || break; sleep 0.25; done
  pkill -x DiskView 2>/dev/null || true
fi
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
echo "Installed $INSTALLED"

if [[ "${1:-}" == "--run" || $WAS_RUNNING == 1 ]]; then
  open "$INSTALLED"
fi
