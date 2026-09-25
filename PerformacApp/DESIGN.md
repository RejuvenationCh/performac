# Design: Performac v2

The shipped app is the source of truth. Every value below is read out of `Tokens.swift`,
`ViewModels.swift` and the views themselves, not out of intentions.

The first version of this screen set was recorded from a web mockup. That provenance is gone
now: three passes of defect fixes, a repalette, a screen merge and a glass audit have
replaced nearly everything it specified. But it is worth naming what a web mockup cost a
native app: a blue-tinted ground, a lettermark badge where an SF Symbol belongs, and glass
used as decoration rather than reserved for what actually floats above content.

## World

A quiet instrument panel. Most days it says nothing; Overview's empty state is a green seal
reading "Nothing worth doing." When it speaks, it is because something changed over time,
and it says so in one sentence with the evidence attached.

Performac is a **windowed app with a Dock icon**, one size class: 900×600 minimum, a 76pt
rail down the left edge, content to its right. There is no second, smaller surface anymore;
see §No menu bar.

## Colour

Neutral macOS greys, defined once in `Tokens.swift` as light/dark pairs and never hard-coded
at a call site:

| token | light | dark | role |
|---|---|---|---|
| `canvas` | `#F5F5F7` | `#1A1A1C` | window background, the darkest thing in light mode / lightest step down in dark |
| `surface` | `#FFFFFF` | `#242426` | every card, row group, sheet |
| `fill1`–`fill4` | `#EFEFF2` → `#D6D6DC` | `#2C2C2F` → `#424247` | tiles, bars, hover and selected states, stepping monotonically away from `surface` |
| `ink` | `#1D1D1F` | `.labelColor` | headlines, values |
| `ink2` | `#48484A` | `.secondaryLabelColor` | why-lines, descriptions |
| `meta` | `#8E8E93` | `.tertiaryLabelColor` | captions, unselected rail labels |
| `hairline` | black 10% | white 12% | every separator, 1px |

The dark values for `canvas`/`surface` are explicit hex, not the semantic
`.windowBackgroundColor`/`.controlBackgroundColor` pair: both of those resolve to `#1E1E1E`
in dark aqua, identical, which made every card vanish into the page with only a hairline left
to find it.

**Accent is `.controlAccentColor` in both modes.** The app deliberately carries no brand
colour of its own, so it always matches whatever accent the user picked in System Settings
rather than shipping a hardcoded blue. Severity uses the system semantic colours directly:
`.systemOrange` (warning), `.systemRed` (critical), `.systemGreen` (the "nothing wrong" seal).

Colour carries exactly two jobs: **severity** on cards and badges, and **file-type identity**
in the treemap and its legend (video · image · audio · cache/app data · document ·
other/system, `FileKind.color`, a fixed categorical palette, deliberately excluded from this
pass). Nothing else is coloured. No gradients, no coloured shadows, no gradient text.

`FileKind` itself (`Core/FileKind.swift`) is measured, not guessed: a file is classified by
its lowercased extension, or by `.cache` when its path runs through `Library/Caches` or a
`Cache`/`Caches` directory, never by folder name. The original heuristic read the enclosing
folder's name for keywords like "movie" or "photo", which matched none of this user's
project-shorthand folders (`UC`, `Render`, `ALP Juna`, ...) and put everything in "Other /
System" regardless of what it actually held. A directory's colour is whichever kind holds the
most bytes beneath it, tallied once during the scan; a tie, or a directory with nothing
classifiable, is `.other` rather than an arbitrary pick.

## Type

SF Pro throughout, via `.system`. Six sizes, all in `Tokens.swift`, plus their
monospaced-digit variants for figures:

| token | size / weight | used for |
|---|---|---|
| `pcDisplay` | 20 / semibold | page titles |
| `pcHeadline` | 16 / semibold | section headings |
| `pcTitle` | 14 / semibold | card headlines, row names |
| `pcBody` | 13 / regular | body text, why-lines, list rows |
| `pcSmall` | 12 / regular | meta, captions, path text |
| `pcLabel` | 11 / medium | column headers, badges, link-outs, treemap tile names |
| `pcNum` / `pcNumLg` | 13 / 20, `.monospacedDigit()` | every figure in the app |

**Nothing in the app goes below 11pt**: that is under any macOS system text size, and text
that small stops being a design choice and starts being an accessibility failure. The
treemap's tile labels were the last holdout at 9–10pt; they are `pcLabel` and 11pt-mono now,
gated on tile size (`width > 60, height > 24` for the name; `height > 36` to also fit the
size line) so a label only draws where it can render uncropped. A clipped label is worse
than none.

## Geometry

Radii are deliberately small, which is what makes it read as desktop rather than mobile:
**2px default · 4px (`lg`) cards and buttons · 8px (`xl`) modals · 12px (`full`) pills.**

Spacing scale: **4 · 8 · 12 (gutter) · 16 (stack/margin)**. Sidebar rail is **76px** fixed:
width follows the longest rail label ("Duplicates") at the 11pt floor, not the other way round.

## Navigation

Four screens on the rail, **Overview, Disk, Clean, Duplicates**, with **Settings pinned
below a spacer**, the way Mail and Xcode place their settings affordance apart from the
content list. The rail is the only navigation; there is no second tab row anywhere.

Overview absorbed what used to be two screens, Dashboard and Digest: both rendered the same
findings list through the same card, one worst-first and one chronological, which spent two
of six rail slots on a single list sorted two ways. One screen now: four measured facts, a
summary line, the free-space trend, then findings ranked worst-first.

## Units

Every size shown in the UI is **bytes**, formatted only through `Fmt.bytes`. This rule exists
because ignoring it cost real, measured accuracy twice:

- `statfs` reports space in blocks; converting that to a decimal-GB label while a sibling
  screen printed raw GiB made two screens disagree about the same free space by **7.4%**.
  `EngineStore.spaceBytes` now returns bytes (`blocks × f_bsize`) and nothing downstream
  converts again.
- The `cache_samples`/`dup_groups` tables store `size_mb`, and MiB is not decimal-MB:
  converting that column with `× 1_000_000` under-reported every cache and duplicate by
  **4.8%**. The conversion is `× 1_048_576`, done once at the database boundary
  (`EngineStore`), never in a view.

Both conversions happen at the edge where the raw unit enters the store. No view multiplies
or divides a size; every view just calls `Fmt.bytes`.

## Components

**FindingCard** (`FindingCard`), the load-bearing component:

```
surface · 4px radius · 1px hairline border · small shadow · 12px pad (16 left)
├─ 4px full-height severity spine on the left edge   ← the severity signal
└─ row: filled severity icon + column:
     headline    pcTitle, ink
     why-line    pcBody, ink2                  ← mandatory, never omitted
     link-out    pcLabel, accent               ← at most one, optional
```

The link-out carries `FindingLink`, an enum holding its destination (`reveal(path)`,
`.activityMonitor`, `.clean`, `.loginSettings`, `.disableAgent(path)`), not just a label: it
was a dead accent-coloured button until this pass, because the view read only the link's kind
and had nothing to act on. See §Rules, "a control must do something." Every case but
`.disableAgent` navigates; that one performs an action, so `FindingCard` intercepts it for
confirmation instead of routing it through `EngineStore.openLink`, the same shape as the
Quit button beside it.

Others as built: `SizeRow` (name · item count · size · proportional bar, hover-revealed
actions) · `CacheRow` (checkbox · name · size · last-written age · safety pill · why-line) ·
`Pill` (severity/safety badges) · `StorageBar` (turns red past capacity) · `TreeMap` + legend
(squarified, so small items keep a clickable aspect ratio) · `CrumbBar` (the path trail with
back/forward controls above the current folder) · `IconButtonAction` (a hover-revealed icon
button that always carries a real action; see §Rules) · `ScanProgress` (indeterminate bar,
running totals, elapsed, Cancel) · `Sparkline` (the free-space trend line).

Overview's empty state ("Nothing worth doing.") is an inline row, a green seal and one
sentence, not a standalone component; it does not need one for something this small.

**Cards do not nest.** Tiles inside a card use a fill token, never a second shadowed card.

## The trash confirmation

The one irreversible-feeling moment. This is not up for revisiting:

- The primary button is **accent-coloured, not red.** The action is recoverable; colouring it
  red teaches fear of a safe operation.
- **Cancel is the default focus**: the safe option is the default.
- Every item lists **full path and size**, with a `pcTitle` total line ("18.0 GB total").
- A permanent reassurance block with a filled trash icon:
  *"These go to the Trash, not deleted. You can put them back from Finder until you empty it."*

## No menu bar

Performac is a windowed app with a Dock icon. The menu bar icon, the small window it used to
open, and everything that rendered inside that window are gone. Vorssaint (installed
alongside) owns the menu bar now. Closing the window does **not** quit the app: the sampler
is the engine, and the window is just a way to look at what it has measured, so
`applicationShouldTerminateAfterLastWindowClosed` returns `false` and the Dock icon stays
running with no window open.

**The trap for whoever reconsiders this:** the app must stay `NSApplication.shared
.setActivationPolicy(.regular)` for its entire life. The old build demoted itself to
`.accessory` on window close, which was only survivable because a menu bar icon was still
there to reopen it from. There is no menu bar icon anymore. Reintroducing the `.accessory`
demotion without one strands a process with no Dock icon, no menu, and no way back in short
of Force Quit. If a menu bar ever comes back, it belongs to Vorssaint, not here.

## Liquid Glass

Adopted for exactly two places, both places content genuinely floats above something:

- **the 76pt rail**: a sidebar at the window edge is Apple's own glass pattern on macOS 26.
- **every sheet** (`TrashSheet`, `RowTrashSheet`, `RowInfoSheet`, `QuitSheet`,
  `DisableAgentSheet`), via `pcGlassPanel`: a sheet floats over the window behind it by
  definition.

Everywhere else is opaque: title rows, toolbars, table rows, cards, badges, the treemap.
Title rows and toolbars looked like candidates too, and were glass for a while, but both
were wrong for the same two reasons:

1. Nothing scrolls under a `Page` title row or the Disk toolbar, content begins below them,
   not underneath, so the glass sat on an opaque canvas and rendered as a flat tint instead
   of depth.
2. Both rows hold real `.bordered`/`.borderedProminent` buttons (Refresh, Scan, Cancel), and
   those buttons **are themselves Liquid Glass on macOS 26.** Wrapping glass chrome around a
   glass button is glass stacked on glass: muddy, not layered.

Two rules that matter as much as the placement:

1. **Never stack glass on glass.** Nested layers read as muddy grey rather than depth.
2. **Legibility outranks the effect.** Anything carrying a number a decision rests on stays
   on an opaque surface.

## Dark mode

Both values live on every token in `Tokens.swift`, and `AppearanceCheck` resolves them under
`.aqua` and `.darkAqua` rather than reading the source, because the one real failure here was
invisible in the code: `.windowBackgroundColor` and `.controlBackgroundColor` **both resolve to
`#1E1E1E`** in dark aqua. This layout is cards on a ground, so the semantic pair made every card
vanish into the page with only a hairline left to find it.

So the dark surfaces are explicit, and continue the fill ladder as one sequence; see the
dark column in §Colour above. The checks assert what that ladder has to be true of, in
**both** modes: a card is distinguishable from its page, the fills step monotonically away
from the card, and every text and severity colour keeps its distance from the surface it is
printed on.

## The all-drives root

The Disk target picker offers **All drives** whenever more than one is mounted. It scans each
root in turn (drives are separate devices, and eight concurrent stat threads already saturate
a USB bus) and lands on `/`.

`/` is a real path, deliberately: breadcrumbs, back/forward, the trash allowlist and
`scan_entries` all keep working with no special case. The only thing that needs handling is
what its children are called. Each drive is stored under `/` with its path minus the leading
slash as the **name** (`Users/you`, `Volumes/External SSD`), so appending it to `/`
rebuilds the real path; `SizeEntry.label` carries the readable version (`Home`, `External SSD`)
and `display` is what rows render. **`name` stays the navigation key everywhere: never render
it, never navigate by `display`.**

This view is the first place a whole drive appears as a row with a Move to Trash beside it.
`Trash.isRootLike` refuses `/`, the home folder, and anything directly under `/Volumes`, and
it lives in `moveToTrash` rather than in the menu because that is the one function every
deletion in the app goes through. The context menu also stops offering the action, so the
refusal is a backstop rather than the user's first encounter with it.

## Scan results are kept per root

`scan_entries` holds every scanned root at once, not one at a time. `buildTree` removes only
the rows under the root it is replacing, so scanning the T7 leaves Home's tree alone and
switching target in the picker browses the stored result with no rescan: the Scan button
refreshes what is shown, it is not how you get to see it. Each root carries its own timestamp
in `diskScanTimes`, and the picker prints the age beside every target so it is obvious which
ones are already there.

Two rules this must keep:

1. **An empty scan never replaces a tree that has rows.** A drive that comes back with nothing
   is a bug or a permissions wall far more often than an empty drive: that is exactly how the
   unscannable-T7 defect turned into a deleted Home scan. `buildTree` returns the roots it
   actually wrote so a refused one keeps its old rows *and* its old timestamp.
2. **The combined root reports its stalest member.** `lastScanAt` for `/` is the `min` of the
   drive timestamps, never the newest: a stale number wearing a fresh label is worse than no
   number.

Prefix matching uses `substr(parent, 1, n) = ?`, not `LIKE` or `GLOB`: a volume name may
contain `%`, `_`, `[` or `*`, and both of those would treat them as wildcards.

## Drives arriving while the app is open

`mountedVolumes` is `@Published` and refreshed from `NSWorkspace`'s mount, unmount and rename
notifications. It used to be a computed property reading `/Volumes` on every render, which is
why a drive plugged in mid-session never appeared: nothing told SwiftUI the directory had
changed.

macOS mounts internal APFS volumes constantly and fires the same notification for them.
Rather than filter the notification, `apply(volumes:)` compares the recomputed list and
returns early when nothing changed: internal volumes live under `/System/Volumes` and so
never move it. Same lesson as v1's drive rule, reached the cheap way.

A new drive is an **offer, not an action**: a bar appears above the listing with the drive's
name and a Scan button, and nothing is measured until it is pressed. The offer withdraws
itself when that drive is unplugged, so the button can never point at something absent, and
if the drive being browsed disappears, the target falls back to Home.

## Scanning a spinning drive

`DiskScanner.concurrency` is eight, which is right for flash and wrong for rust: on a
mechanical disk eight workers make the head seek between eight regions instead of reading in
something like order, so more threads make the scan **slower**. `concurrency(forVolume:)`
asks `diskutil info -plist` (metadata only, it reads no files) and gives a volume 8 when it
reports `SolidState`, 2 when it does not. Verified on this machine: the T7 (SSD) gets 8, the
Transcend (USB mechanical) gets 2, and anything off `/Volumes` is the boot disk and gets 8.

**Stop is not abort.** The caller owns the `CancelFlag`, so stopping asks the walk to unwind
and hand back what it measured rather than tearing the stream down. A `ScanSummary` carries
`partial`, and two rules follow from it:

1. A partial result **never replaces a finished tree**: half a tree that looks whole is worse
   than an old tree that is honestly labelled. It is only stored when that root had nothing.
2. A root whose tree came from a stopped scan is recorded in `partialRoots`, and the picker
   prints "partial" beside its age rather than an age that implies the whole drive.

## Left to Vorssaint

Vorssaint (installed alongside) already does these, better, so Performac no longer does:
the **Apps** tab (uninstaller and its quit-first flow), the **Updates** tab (brew formulae
and casks), **live CPU / memory / network / temperature** graphs, the menu bar and its
readouts, the **battery health** rule, and the generic cleaner rows for **Homebrew
downloads, app logs, Xcode device support, Simulator caches and iOS backups**.
Do not bring them back. Performac's job is what Vorssaint cannot see: where the disk went,
duplicates, creative-app caches, and what changed over time.

## Rules the next change must keep

1. **Native, dense, macOS.** If a change would look at home on a phone, it is wrong here.
   No bottom tabs, no FABs, no oversized touch targets, no second navigation.
2. **Colour only for severity or treemap file type.** Everything else is neutral, and the
   app has no brand colour of its own: `.controlAccentColor` is the accent in both modes.
3. **The why-line is mandatory.** A card showing a size without its evidence does not ship.
4. **All figures are tabular**, and every size in the UI is bytes through `Fmt.bytes`; see
   §Units. Nothing converts a unit twice.
5. **Icons are SF Symbols. No emoji**, in UI or in copy.
6. **A card carries at most one remedy; every remedy is confirmed before it acts, and every
   remedy is reversible.** Quitting a process prompts for unsaved work first (`QuitSheet`);
   disabling a LaunchAgent unloads it and sends its plist to the Trash (`DisableAgentSheet`),
   never `unlink`/`removeItem`/`rm`. Two findings deliberately carry no remedy instead: the
   Trash-holding card only links out, because emptying the Trash is the one irreversible act
   in the app and must stay the user's own deliberate gesture; a drive-flap card has no
   button at all, because a loose cable is not something software can fix. The Clean view's
   one action is always and only **"Move to Trash"**, never "Clean", "Optimize", or "Free up".
7. **Destructive confirmations stay accent-coloured, with Cancel focused**, and always state
   recoverability.
8. **Cards do not nest.**
9. **Every token carries both values**: never hard-code a bare hex or a bare `.white` at a
   call site. The one sanctioned exception is the treemap, whose tile fills are a fixed
   palette by design, so the black label and white hairline drawn on them are correct in
   either mode.
10. **Glass is the rail and sheets, never content.** Headers, toolbars, rows, cards and the
    treemap are opaque. Never nest glass inside glass.
11. **Never state a status the app cannot evidence.**
12. **A control that cannot act must not be drawn.** The audit that started this pass found
    eight controls wired to empty closures, including the finding card's only link-out. An
    affordance with no effect is worse than no affordance: it teaches the user that buttons
    in this app might not do anything.
