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

```bash
git clone https://github.com/RejuvenationCh/performac.git
cd performac
./install.sh
```

That is the whole thing. It checks your macOS version and toolchain first and tells you what to
do if either is missing, then builds and installs to `~/Applications/Performac.app`.

**Requirements:** macOS 14 (Sonoma) or later, and Apple's Command Line Tools. If you have never
installed the tools, `install.sh` will say so and give you the command (`xcode-select --install`).

On macOS 26 and later the rail and sheets use Liquid Glass. Below that they fall back to opaque
surfaces, which is what the rest of the app already uses.

**Why build it yourself rather than download a disk image?** Because macOS only quarantines apps
that arrive over the network. An app you compiled locally has no quarantine flag, so Gatekeeper
does not block it and there is no "damaged app" dialog to work around. It also means no one has
to trust a binary from a stranger.

## Full Disk Access

Without it, Performac cannot read every folder, so scans quietly come out smaller than your disk
really is. Settings shows whether the grant is in place and links straight to the right pane.

**System Settings → Privacy & Security → Full Disk Access → add `~/Applications/Performac.app`**

### One wrinkle worth knowing

macOS ties that grant to the app's **signing identity**. `make-app.sh` signs with a stable
self-signed certificate called `Performac Dev` when one exists in your keychain, so the identity
stays constant and the grant survives rebuilds.

If you do not have that certificate, the script falls back to ad-hoc signing, where the identity
is the binary's hash. That works fine, but it means **every rebuild looks like a brand-new app to
macOS and you have to grant Full Disk Access again.** If you plan to rebuild often, create a
self-signed code-signing certificate named `Performac Dev` in Keychain Access
(*Certificate Assistant → Create a Certificate → Code Signing*) and the problem goes away.

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
| Database | `~/Library/Application Support/com.chris.performac.v2/performac.db` |
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
