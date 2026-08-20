# Performac

An advisory-only macOS performance coach: an always-on local sampler + rule engine that turns
system-health signals into plain-language cards with evidence (staleness, trends, counts). It
**never deletes, quits, or modifies anything** — every card explains *why*, and defers action to
the tools you already own (Purge, Activity Monitor, Finder).

Zero dependencies. Node ≥ 26 stdlib only (`node:sqlite`, `node:http`, `node:child_process`,
`node:crypto`). One `index.html`, one `app.js`, one SVG sprite, one service worker. No build step.

## Setup

```bash
npm test                                     # 88 tests, all green = good state

# 1. always-on server (the sampler must run even when the app is closed)
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.chris.performac.plist

# 2. the app: open in Safari, File → Add to Dock
open http://localhost:7420

# node path note: the plist uses /opt/homebrew/bin/node (copied from the
# attention-dashboard agent). If your node lives elsewhere, edit the plist.
```

## One-time setup

The plist expects the repo at `~/Data C (General)/Projects/Personal/Performac/`. Logs:
`/tmp/performac.log`. Database: `performac.db` (gitignored) next to `server.js`.

## Permissions (what prompts, and when)

Performac deliberately asks for nothing at launch. Three prompts exist, each tied to a feature
you trigger:

| Prompt | When | What breaks if denied |
|---|---|---|
| Files & Folders (Downloads/Desktop) | First hourly drift walk | The drift card is replaced by a card explaining the grant |
| Automation (System Events) | Only when you press "Scan login items" in Settings | That scan errors; everything else is unaffected |
| Removable Volumes | First dedupe scan that includes an external drive | The scan skips the drive |

Prompts from a background LaunchAgent can be silently denied — if a permission prompt seems
missing, run the server once in the foreground (`npm start`) and trigger the feature there.

## Guardrails (grep-able)

- The strings `rm `, `unlink`, `rmdir`, `trash`, `kill(`, `SIGKILL`, `SIGTERM` do not appear in
  any code path. The only filesystem writes are `performac.db*` and `/tmp/performac.log`.
- All subprocesses go through `execFile` with argv arrays — never a shell string.
- Spawned binaries allowlist: `ps`, `df`, `lsappinfo`, `pmset`, `ioreg`, `tmutil`, `diskutil`,
  `mdfind`, `osascript` (notifications + read-only login-items query), `open`
  (`-b io.getpurge.app`, `-a Activity Monitor`, `-R <path>` only). Nothing else.
- Server binds `127.0.0.1` only; `*.db*` is never served; `POST` endpoints are same-origin JSON
  with an allowlist and `existsSync`/`statSync` checks.

## Ops

```bash
launchctl kickstart -k gui/$UID/com.chris.performac   # restart (e.g. after editing the plist)
launchctl bootout gui/$UID/com.chris.performac        # stop + disable until next login
npm start                                             # manual run, if the agent is stopped
tail -f /tmp/performac.log
```

## Settings

Everything is a calibration knob: Settings → thresholds per feature, tier-3 toggles (off by
default), backup watch paths (`path|maxDays` per line), dedupe roots, notification master switch.
Thresholds apply to new findings immediately; sampler cadence changes need an agent restart.

## Weekly digest coach intro (optional)

The Digest view's intro paragraph is templated by default. To get a warmer, Claude-written intro
(Money Dashboard's pattern), install `insights/refresh_digest.js` as its own LaunchAgent —
mirroring `com.example.finance-insights`. Save as
`~/Library/LaunchAgents/com.example.performac-insights.plist`, then
`launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.example.performac-insights.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.performac-insights</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/node</string>
    <string>/Users/you/Data C (General)/Projects/Personal/Performac/insights/refresh_digest.js</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>1</integer>
    <key>Hour</key><integer>9</integer>
    <key>Minute</key><integer>5</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/performac-insights.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/performac-insights.err</string>
</dict>
</plist>
```

Runs Monday 09:05 (adjust Weekday/Hour/Minute as you like). The script calls the Claude CLI
headlessly (`claude -p` — log in once with `claude` then `/login`), writes `seed/digest.json`,
and the app adopts it while it is less than 8 days old. Without this opt-in agent, nothing
calls the network — ever.
