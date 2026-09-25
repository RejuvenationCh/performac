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

## 0.2.0

**Coming from 0.1.0? Install once more by hand**, because this version cannot update itself
over 0.1.0 (the reason is below):

```bash
curl -fsSL https://raw.githubusercontent.com/RejuvenationCh/performac/main/install.sh | bash
```

- New bundle ID, `io.github.rejuvenationch.performac`. The old one carried the author's name
  into your Library. History and preferences move across on first launch. An update is only
  accepted when its bundle ID matches, which is why 0.1.0 cannot take this one, and macOS ties
  Full Disk Access and Launch at login to the ID, so grant those once more in Settings.
- An app icon.
- Notifications come from Performac itself instead of Script Editor, and show while the app is
  in front. Settings has a Send Test button, so you can check them.
- A new install shows what Performac is doing on its first day, instead of a screen of cards
  with no explanation.

## 0.1.0

- First public version: Overview, Disk, Clean and Duplicates.
- One line install from Terminal, no Xcode needed. Universal: Apple Silicon and Intel.
- Updates install themselves, and the previous version goes to the Trash.
