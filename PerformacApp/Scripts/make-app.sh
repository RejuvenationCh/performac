#!/bin/bash
# Scripts/make-app.sh: assemble Performac.app by hand from the swift build output.
# No Xcode, no xcodebuild: SwiftPM compiles, this script bundles, codesign ad-hoc.
# Gatekeeper: the first launch needs right-click → Open (ad-hoc signature).
set -euo pipefail
cd "$(dirname "$0")/.."

# UNIVERSAL=1 builds Intel and Apple Silicon into one binary (needs Xcode, not just the
# Command Line Tools). Release builds use it; a local build does not need to.
ARCH_FLAGS=""
[ "${UNIVERSAL:-0}" = 1 ] && ARCH_FLAGS="--arch arm64 --arch x86_64"
swift build -c release $ARCH_FLAGS
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/Performac"

# One place to bump: the VERSION file at the repo root. The update check compares GitHub's
# latest tag against this, so a release tagged without bumping it will offer itself forever.
VERSION="$(tr -d '[:space:]' < ../VERSION)"

APP="build/Performac.app"
# removal scope: this exact regenerable build output only, never user data
# (the app's only deletion path is FileManager.trashItem; build artifacts are rebuilt here)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Performac"

cat > "$APP/Contents/Info.plist" <<PLIST
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
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Sign with a stable self-signed identity, NOT ad-hoc. macOS ties Full Disk Access to the
# app's signing identity; with ad-hoc that identity is the binary hash, so every code change
# looked like a brand-new app and TCC silently dropped every grant. A certificate keeps the
# identity constant across rebuilds, so the grant is made once and sticks.
# Falls back to ad-hoc if the certificate is missing, so the build never breaks.
SIGN_ID="Performac Dev"
security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 || SIGN_ID="-"
codesign --force --sign "$SIGN_ID" "$APP"
echo "built $APP $VERSION (signed: $SIGN_ID)"

# SKIP_INSTALL=1 stops here with the bundle in build/, which is what release.sh zips.
[ "${SKIP_INSTALL:-0}" = 1 ] && exit 0

# Install to ~/Applications so the Dock has a stable target: build/ is wiped on every
# rebuild, so pinning that path would break each time. rsync --delete replaces the
# installed bundle in place (build artifact, never user data).
INSTALL="$HOME/Applications/Performac.app"
mkdir -p "$HOME/Applications"
rsync -a --delete "$APP/" "$INSTALL/"
codesign --force --sign "$SIGN_ID" "$INSTALL"
echo "installed $INSTALL"
