#!/bin/bash
# install.sh: build Performac and put it in ~/Applications.
#
# This exists because the build failing on someone else's Mac produced a wall of Swift
# compiler errors and no explanation. Everything below is a check that turns a likely failure
# into a sentence telling you what to do about it.
set -uo pipefail
cd "$(dirname "$0")"

say()  { printf '\n%s\n' "$*"; }
fail() { printf '\n%s\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- macOS version
MIN_MAJOR=14
VERSION="$(sw_vers -productVersion)"
MAJOR="${VERSION%%.*}"

if [ "$MAJOR" -lt "$MIN_MAJOR" ]; then
    fail "Performac needs macOS ${MIN_MAJOR} (Sonoma) or later.
This Mac is on ${VERSION}.

There is no workaround: the app uses APIs that do not exist on older systems."
fi

# ---------------------------------------------------------------- toolchain
if ! xcode-select -p >/dev/null 2>&1; then
    fail "Apple's Command Line Tools are not installed, so there is no Swift compiler.

Run this, let it finish, then run ./install.sh again:

    xcode-select --install"
fi

if ! command -v swift >/dev/null 2>&1; then
    fail "The Command Line Tools are installed but 'swift' is not on your PATH.

Try:

    sudo xcode-select --switch /Library/Developer/CommandLineTools"
fi

SWIFT_VERSION="$(swift --version 2>&1 | head -1)"

say "Performac"
say "  macOS      ${VERSION}"
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

APP="$HOME/Applications/Performac.app"
[ -d "$APP" ] || fail "The build reported success but $APP is not there. Something is wrong."

say "Installed: $APP"

cat <<'NEXT'

Two things before it is useful:

  1. Open it. It is in ~/Applications, and it will also show up in Spotlight.

  2. Give it Full Disk Access, or scans will quietly miss whatever it cannot read:
     System Settings > Privacy & Security > Full Disk Access > add Performac.

Disk and Duplicates need a scan before they can tell you anything. The Overview screen
needs a few days of history before its trends mean much. Nothing is broken if it looks
quiet on the first run.

NEXT
