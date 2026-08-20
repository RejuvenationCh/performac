#!/bin/bash
# Scripts/make-app.sh — assemble Performac.app by hand from the swift build output.
# No Xcode, no xcodebuild: SwiftPM compiles, this script bundles, codesign ad-hoc.
# Gatekeeper: the first launch needs right-click → Open (ad-hoc signature).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Performac.app"
# removal scope: this exact regenerable build output only — never user data
# (the app's only deletion path is FileManager.trashItem; build artifacts are rebuilt here)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Performac "$APP/Contents/MacOS/Performac"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.chris.performac.v2</string>
	<key>CFBundleName</key>
	<string>Performac</string>
	<key>CFBundleDisplayName</key>
	<string>Performac</string>
	<key>CFBundleExecutable</key>
	<string>Performac</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP (ad-hoc signed)"

# Install to ~/Applications so the Dock has a stable target: build/ is wiped on every
# rebuild, so pinning that path would break each time. rsync --delete replaces the
# installed bundle in place (build artifact, never user data).
INSTALL="$HOME/Applications/Performac.app"
mkdir -p "$HOME/Applications"
rsync -a --delete "$APP/" "$INSTALL/"
codesign --force --sign - "$INSTALL"
echo "installed $INSTALL"
