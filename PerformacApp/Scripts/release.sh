#!/bin/bash
# Scripts/release.sh: publish VERSION as a GitHub release with a prebuilt universal app.
#
# Installed copies update themselves from the Performac.zip attached here, and accept it only
# if it is signed by the same certificate they were. So this refuses to ship anything not
# signed with "Performac Dev": an ad hoc release would install for nobody.
set -euo pipefail
cd "$(dirname "$0")/../.."

V="$(tr -d '[:space:]' < VERSION)"
TAG="v$V"
die() { echo "release: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || die "uncommitted changes. The release is built from HEAD, commit first."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "$TAG already exists. Bump VERSION."
security find-certificate -c "Performac Dev" >/dev/null 2>&1 || die "no 'Performac Dev' certificate in the keychain."
NOTES="$(awk -v v="$V" '/^## /{n=($2==v); next} n' CHANGELOG.md)"
[ -n "$NOTES" ] || die "CHANGELOG.md has no '## $V' section."

(cd PerformacApp && UNIVERSAL=1 SKIP_INSTALL=1 ./Scripts/make-app.sh)
APP=PerformacApp/build/Performac.app
codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf' || die "the bundle is not signed with the certificate."
lipo -archs "$APP/Contents/MacOS/Performac" | grep -q x86_64 || die "the binary is not universal."

ZIP=PerformacApp/build/Performac.zip
ditto -c -k --keepParent "$APP" "$ZIP"

git push origin HEAD
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Performac $V" --notes "$NOTES"
