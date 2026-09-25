#!/bin/bash
# install.sh: put Performac in ~/Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/RejuvenationCh/performac/main/install.sh | bash
#
# Downloads the latest release, already built. No compiler, no Xcode. Because curl (not a
# browser) fetches it, macOS does not quarantine it and there is no "damaged app" dialog.
#
#   ./install.sh --source
#
# Builds from a clone instead. Every failure below is turned into a sentence saying what to do,
# because a failed build used to end in a wall of Swift compiler errors and no explanation.
set -uo pipefail

say()  { printf '\n%s\n' "$*"; }
fail() { printf '\n%s\n\n' "$*" >&2; exit 1; }

APP="$HOME/Applications/Performac.app"
ZIP_URL="${PERFORMAC_ZIP_URL:-https://github.com/RejuvenationCh/performac/releases/latest/download/Performac.zip}"

# ---------------------------------------------------------------- macOS version
MIN_MAJOR=14
VERSION="$(sw_vers -productVersion)"
MAJOR="${VERSION%%.*}"

if [ "$MAJOR" -lt "$MIN_MAJOR" ]; then
    fail "Performac needs macOS ${MIN_MAJOR} (Sonoma) or later.
This Mac is on ${VERSION}.

There is no workaround: the app uses APIs that do not exist on older systems."
fi

say "Performac"
say "  macOS      ${VERSION}"

if [ "${1:-}" = "--source" ]; then
    cd "$(dirname "$0")"
    [ -d PerformacApp ] || fail "--source builds from a clone. Run it from inside one:

    git clone https://github.com/RejuvenationCh/performac.git
    cd performac && ./install.sh --source"

    # ---------------------------------------------------------------- toolchain
    if ! xcode-select -p >/dev/null 2>&1; then
        fail "Apple's Command Line Tools are not installed, so there is no Swift compiler.

Run this, let it finish, then run ./install.sh --source again:

    xcode-select --install"
    fi

    if ! command -v swift >/dev/null 2>&1; then
        fail "The Command Line Tools are installed but 'swift' is not on your PATH.

Try:

    sudo xcode-select --switch /Library/Developer/CommandLineTools"
    fi

    SWIFT_VERSION="$(swift --version 2>&1 | head -1)"

    say "  toolchain  ${SWIFT_VERSION}"

    # ---------------------------------------------------------------- build
    say "Building. The first build compiles everything and takes a couple of minutes."

    # Quiet unless it fails. A successful build prints pages of compiler warnings, which reads
    # like something went wrong to anyone who has not seen it before.
    LOG="$(mktemp -t performac-build)"
    if ! ./PerformacApp/Scripts/make-app.sh > "$LOG" 2>&1; then
        printf '\n--- build output (last 40 lines) ---\n' >&2
        tail -40 "$LOG" >&2
        fail "The build failed. Full output: $LOG

If the errors mention a missing module or an unavailable API, the Command Line Tools are
probably older than the app needs. Updating macOS, or reinstalling the tools with

    sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install

usually fixes it. If they say something else, that output is the useful part: send it on."
    fi
    rm -f "$LOG"
    [ -d "$APP" ] || fail "The build reported success but $APP is not there. Something is wrong."
else
    TMP="$(mktemp -d -t performac)"
    say "Downloading the latest release."
    curl -fL --progress-bar -o "$TMP/Performac.zip" "$ZIP_URL" \
        || fail "The download failed. Check the connection and try again.

If it keeps failing, build it yourself instead:

    git clone https://github.com/RejuvenationCh/performac.git
    cd performac && ./install.sh --source"
    ditto -x -k "$TMP/Performac.zip" "$TMP" || fail "The download is not a readable zip. Nothing was installed."
    codesign --verify --deep --strict "$TMP/Performac.app" 2>/dev/null \
        || fail "The download's signature does not check out, so it may be damaged. Nothing was installed."

    # Quit a running copy first, then set the old one aside rather than deleting it. It
    # lands in a temporary folder macOS clears on its own.
    if pgrep -qf "$APP/Contents/MacOS/Performac"; then
        osascript -e 'tell application id "com.chris.performac.v2" to quit' >/dev/null 2>&1
        for _ in $(seq 50); do pgrep -qf "$APP/Contents/MacOS/Performac" || break; sleep 0.2; done
        # macOS refuses to quit an app while it shows a dialog, and replacing it underneath a
        # running copy would leave the old one on screen.
        pgrep -qf "$APP/Contents/MacOS/Performac" \
            && fail "Performac did not quit, usually because a dialog is open in it. Close the dialog, quit Performac, and run this again. Nothing was changed."
    fi
    mkdir -p "$HOME/Applications"
    [ -d "$APP" ] && mv "$APP" "$TMP/previous.app"
    mv "$TMP/Performac.app" "$APP" || fail "Could not move Performac into ~/Applications."
fi

say "Installed: $APP"
open "$APP"

cat <<'NEXT'

Two things before it is useful:

  1. It is open now. Next time it is in ~/Applications and Spotlight. It updates itself.

  2. Give it Full Disk Access, or scans will quietly miss whatever it cannot read:
     System Settings > Privacy & Security > Full Disk Access > add Performac.

Disk and Duplicates need a scan before they can tell you anything. The Overview screen
needs a few days of history before its trends mean much. Nothing is broken if it looks
quiet on the first run.

NEXT
