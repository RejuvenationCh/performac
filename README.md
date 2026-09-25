# Performac

A native macOS app that answers four questions about your Mac:

- **Where did the disk go?** A real scan with a drill-down browser, a treemap and bubbles.
- **What can I safely delete?** Allowlisted caches only, each row explaining what refills it.
- **What do I have twice?** Exact byte-for-byte duplicates, with the differing part of each path highlighted.
- **What changed?** Free space over time, drives that keep reconnecting, caches that are growing.

Everything it removes goes to the **Trash**. There is no other deletion path in the codebase:
`unlink`, `removeItem` and `rm` are banned, and `FileManager.trashItem` is the only route. If
Performac takes something you wanted, Put Back in Finder gets it back.

Zero dependencies. SwiftPM only, no Xcode project, no packages.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/RejuvenationCh/performac/main/install.sh | bash
```

It downloads the latest release, puts it in `~/Applications` and opens it. No Xcode, no
compiling. Runs on Apple Silicon and Intel, macOS 14 (Sonoma) or later.

**Updates install themselves.** Performac checks GitHub once a day (or right away from Settings,
Check Now), installs a newer release in the background, and asks you to restart. The previous
version goes to the Trash, so going back is one Put Back away. An update is accepted only if it
is signed by the same certificate as the copy you have.

**Why no "damaged app" warning?** macOS quarantines apps that a browser downloads, and
Gatekeeper then blocks anything without a paid Apple Developer ID. `curl` and the app's own
updater do not set that flag, so neither path is blocked. Downloading the zip from the releases
page in a browser *does* get it quarantined, so use the command above.

### Building it yourself

```bash
git clone https://github.com/RejuvenationCh/performac.git
cd performac
./install.sh --source
```

This needs Apple's Command Line Tools (`install.sh` says so and gives you the command if they
are missing). A copy you build yourself does not update itself: it is signed with your own
identity, not the release certificate, so it offers the release page instead.

On macOS 26 and later the rail and sheets use Liquid Glass. Below that they fall back to opaque
surfaces, which is what the rest of the app already uses.

## Full Disk Access

Without it, Performac cannot read every folder, so scans quietly come out smaller than your disk
really is. Settings shows whether the grant is in place and links straight to the right pane.

**System Settings → Privacy & Security → Full Disk Access → add `~/Applications/Performac.app`**

## Notifications

Only for things that need you: a drive that keeps dropping, a missed backup, space running out.
macOS asks the first time one is sent. If you said no, or want to check, Settings has a Send Test
button, and the switch is under System Settings, Notifications, Performac.

macOS ties that grant to the app's **signing identity**. Releases are all signed with the same
certificate, so the grant survives every update.

### If you build from source

`make-app.sh` signs with a self-signed certificate called `Performac Dev` when one exists in your
keychain, and falls back to ad hoc signing when it does not, where the identity is the binary's
hash. Ad hoc works, but **every rebuild looks like a brand-new app to macOS and you have to grant
Full Disk Access again.** If you rebuild often, create a self-signed code-signing certificate
named `Performac Dev` in Keychain Access (*Certificate Assistant, Create a Certificate, Code
Signing*) and the problem goes away.

## Using it

**Overview** is the summary: four measured facts, free space over time (hover the chart for the
value at any point), then findings worst-first. Each card carries its evidence and at most one
remedy, and every remedy is confirmed and reversible.

**Disk** needs a scan before it can tell you anything. Pick a target (your home folder, any
mounted volume, or a folder you choose), press Scan, and results stream in as it walks. Scans are
kept per drive, so switching targets is free and does not rescan. A full home scan is minutes of
disk activity.

**Clean** lists caches on a reviewed allowlist. Click a row to select it, shift-click for a range,
and expand any row to see what the size is actually made of. Anything off the allowlist is shown
and measured but marked Protected and cannot be selected.

**Duplicates** finds exact matches by hashing files over the size threshold in Settings. There is
no bulk action, deliberately: with duplicates one copy has to survive, so removing every copy can
never be one misclick. Each copy has its own reveal and trash.

Closing the window does not quit the app. The sampler keeps running so history keeps accruing,
and the Dock icon brings the window back. Quit with Cmd-Q.

## Keyboard

| | |
|---|---|
| `Cmd-R` | Scan or rescan (Disk) |
| `Cmd-Shift-R` | Re-measure findings |
| `Cmd-[` / `Cmd-]` | Back and forward in the disk browser |
| `Cmd-Opt-F` | Fill the screen, staying in the current Space |
| `Cmd-Opt-Shift-F` | Restore the previous size |
| `Cmd-Ctrl-F` | Full screen |

The mouse's back and forward buttons, and a two-finger horizontal swipe, also navigate the disk
browser.

## Where it keeps things

| | |
|---|---|
| Database | `~/Library/Application Support/io.github.rejuvenationch.performac/performac.db` |
| Appearance and window state | `UserDefaults` |
| Everything else | in that one SQLite file |

Settings shows the database size and can reveal it in Finder. History retention is configurable;
the default is 180 days for disk and cache samples, 14 for per-process samples.

## Development

```bash
swift build                  # compile
swift run Performac check    # the full self-check suite
./Scripts/make-app.sh        # build, bundle, sign, install
```

There is no XCTest: Command Line Tools ships neither swift-testing nor XCTest, so checks are
assert-based and live in `Sources/Performac/Check/`. `Performac check` runs every suite and
prints a total. Keep it at zero failures.

`PerformacApp/DESIGN.md` is the design system and the reasoning behind it, including several
rules that exist because something went wrong once. Read it before changing the UI.

### Other subcommands

```bash
swift run Performac scan <path>     # headless scan with timings
swift run Performac parity <db> <nowMs>   # dump findings as JSON, for diffing against v1
```

## About the v1 Node app

The repository still contains the original Node implementation (`server.js`, `sampler.js`,
`rules.js` and friends) that the Swift app was ported from. It is not needed to run Performac and
is kept for reference.

## License

MIT. See `LICENSE`.
