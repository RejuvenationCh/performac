# Changelog

Newest first. Each heading is a version that matches a `vX.Y.Z` tag.

## Releasing

1. Bump `VERSION` (one line, semver) and add a `## X.Y.Z` section below. Commit.
2. Run `PerformacApp/Scripts/release.sh`. It builds a universal app, signs it with the
   `Performac Dev` certificate, tags, and publishes a GitHub release with that section as the
   notes and `Performac.zip` attached.

Installed copies pick it up within a day and install it themselves. Only a release signed with
that same certificate will install, so keep it: losing it strands every existing install on
its current version.

## 0.1.0

- First public version: Overview, Disk, Clean and Duplicates.
- One line install from Terminal, no Xcode needed. Universal: Apple Silicon and Intel.
- Updates install themselves, and the previous version goes to the Trash.
