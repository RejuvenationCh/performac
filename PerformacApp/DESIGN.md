# Design — Performac v2

Recorded from the Stitch artifact (8 screens: menu bar popover, disk browser, disk scan in
progress, today quiet state, clean view, duplicates browser, trash confirmation modal,
settings). Every value below is one the generated HTML actually uses — read out of its
Tailwind config and markup, not from intentions.

**One caveat this file exists to resolve.** The artifact is a *web* mockup: Tailwind via CDN,
**Inter** from Google Fonts, **Material Symbols** icons, and Material Design 3 colour token
names (`surface-container-lowest`, `on-surface-variant`, `tertiary-container`). The shipping
app is native macOS. The values are right; three of the mechanisms are not. §Translation
below is binding — build to that, not to the HTML.

## World

A quiet instrument panel. Most days it says nothing; the Today screen's default state is a
green seal reading "Nothing worth doing." When it speaks, it is because something changed
over time, and it says so in one sentence with the evidence attached.

Two densities, because there are two surfaces: a **popover that answers in one glance**
(380×520), and a **window dense enough to browse a filesystem** (1200×800, 64pt rail).

## Colour — as used

| role | hex | used for |
|---|---|---|
| page ground | `#f7f9ff` | window and popover background |
| card surface | `#ffffff` | every card, row group, modal |
| tinted fills | `#ecf4ff` · `#e6effa` · `#e0e9f5` · `#dae3ef` | tiles, bar tracks, hover states (lightest→darkest) |
| primary text | `#141c25` | headlines, values |
| secondary text | `#434654` | why-lines, descriptions |
| outline | `#747686` · `#c3c5d7` | borders, disabled |
| hairline | `rgba(0,0,0,0.1)` | every separator, 1px |
| accent / link | `#0045c5` | link-outs, selected rail item |
| accent fill | `#2f5fe0` | primary buttons, progress bars |
| **amber (warning)** | `#b24800` fill · `#ffe4d9` soft | warning severity spine, "Check first" pill |
| **red (critical)** | `#ba1a1a` fill · `#ffdad6` soft | critical severity spine, over-threshold storage |
| neutral chip | `#dfe3eb` | inactive badges |

Colour carries exactly two jobs: **severity** on cards and badges, and **file-type identity**
in the treemap legend (video · image · cache/app data · document · other/system). Nothing
else is coloured. No gradients, no coloured shadows, no gradient text.

## Type — as used

Inter in the artifact; **SF Pro in the build** (see §Translation). Scale is unchanged.

| token | size / line / weight | used for |
|---|---|---|
| display-sm | 20 / 28 / 600, −0.01em | page titles, popover metric values |
| headline-sm | 16 / 24 / 600, −0.01em | section headings ("Cache Files", "Duplicates") |
| title-sm | 14 / 20 / 600 | card headlines, row names, summary totals |
| body-md | 13 / 18 / 400 | body, why-lines, list rows |
| body-sm | 12 / 16 / 400 | meta, reassurance text, path captions |
| label-md | 11 / 14 / 500, +0.02em | column headers, badges, link-outs, metric labels |
| mono-numeric | 13 / 18 / 400 | all figures — **always with tabular figures** |

Every size, count, percentage and duration uses tabular figures. The artifact applies
`tabular-nums`; the build uses `.monospacedDigit()`.

## Geometry — as used

Radii are deliberately small, which is what makes it read as desktop rather than mobile:
**2px default · 4px (`lg`) cards and buttons · 8px (`xl`) modals · 12px (`full`) pills.**

Spacing scale: **4 · 8 · 12 (gutter) · 16 (stack/margin)**. Sidebar rail is **64px** fixed.

## Components — anatomy as built

**CoachCard** — the load-bearing component:

```
white surface · 4px radius · 1px rgba(0,0,0,.1) border · small shadow · 12px pad (16 left)
├─ 4px full-height severity spine on the left edge   ← the severity signal
└─ row: filled severity icon + column:
     headline    title-sm, primary text
     why-line    body-md, secondary text        ← mandatory, never omitted
     link-out    label-md, accent               ← at most one, optional
```

**MetricStrip** (popover header): four equal cells split by 1px vertical hairlines; each is a
`label-md` uppercase label above a `mono-numeric` value.

Others as built: `SizeRow` (name · item count · size · proportional bar, hover-revealed
actions) · `CacheRow` (checkbox · name · size · last-written age · safety pill · why-line) ·
`SafetyPill` ("Safe to clean" green / "Check first" amber) · `StorageBar` (red past 92%) ·
`TreeMap` + legend · `Breadcrumb` · `ProgressRow` (indeterminate bar, running totals,
elapsed, Cancel) · `QuietState` (green seal, headline, sentence, four neutral tiles).

**Cards do not nest.** Tiles inside a card use a tinted fill, never a second shadowed card.

## The trash confirmation — verified in the artifact

The one irreversible-feeling moment, and the artifact gets it right. Do not "fix" any of this:

- The primary button is **`#2f5fe0` blue, not red.** The action is recoverable; colouring it
  red teaches fear of a safe operation.
- **Cancel carries `autofocus`** — the safe option is the default.
- Every item lists **full path and size**, with a `title-sm` total line ("18.0 GB total").
- A permanent reassurance block with a filled trash icon:
  *"These go to the Trash, not deleted. You can put them back from Finder until you empty it."*

## Translation — web artifact → native build (binding)

| artifact | build |
|---|---|
| Inter (Google Fonts) | **SF Pro** via `.system` — no bundled or webfonts |
| Material Symbols | **SF Symbols**, `.regular`, 16pt rows / 18pt rail |
| Tailwind utility classes | SwiftUI modifiers; tokens above as a `Color`/`Font` extension |
| `tabular-nums` | `.monospacedDigit()` |
| `rgba(0,0,0,0.1)` hairlines | `Divider()` / `.separatorColor` |
| px | pt, 1:1 at these sizes |
| flat popover background | **`NSVisualEffectView`, `.popover` material** — a flat popover reads as a screenshot pasted on the desktop |
| `html class="light"` only | **Light, dark, or the system's choice.** Settings › General › Appearance, stored in `UserDefaults` (not the settings table — it is applied before the database opens, and a late preference means the window paints light and then flips). Defaults to matching the system. |

## Do not carry over

Present in the artifact, wrong for this app:

1. **`Support · Privacy Policy · License` footer** on the duplicates screen. There is no
   support desk; this is a personal local tool.
2. **"System Status: Optimal"** in that same footer — an evidence-free reassurance, exactly
   what this app must never say. It would also be wrong the moment something fails.
3. **Top tabs (`All Files · Applications · System Data`)** on duplicates and settings — a
   second navigation competing with the 64pt rail. The rail is the only navigation.
4. **The "speed" wordmark** that replaced "Performac" on two screens.
5. **Checkboxes on individual duplicate copies.** With exact duplicates at least one copy must
   survive; per-row trash actions only, so deleting every copy can never be one misclick.
6. The treemap is drawn as vertical strips. Build a **squarified** treemap so small items keep
   a clickable aspect ratio.

## Dark mode

Both values live on every token in `Tokens.swift`, and `AppearanceCheck` resolves them under
`.aqua` and `.darkAqua` rather than reading the source, because the one real failure here was
invisible in the code: `.windowBackgroundColor` and `.controlBackgroundColor` **both resolve to
`#1E1E1E`** in dark aqua. This layout is cards on a ground, so the semantic pair made every card
vanish into the page with only a hairline left to find it.

So the dark surfaces are explicit, and continue the fill ladder as one sequence:

| token | dark | role |
|---|---|---|
| `canvas` | `#161719` | the page, the darkest thing on screen |
| `surface` | `#202226` | a card, one step above the page |
| `fill1`–`fill4` | `#2a2c30` · `#303338` · `#36393f` · `#3d4147` | tiles and hover states inside a card |

The checks assert what that ladder has to be true of, in **both** modes: a card is
distinguishable from its page, the fills step monotonically away from the card, and every text
and severity colour keeps its distance from the surface it is printed on.

The menu bar is the system's, not the app's. `statusItem.button.appearance` is pinned to `nil`
so the template glyph always matches the menu bar it sits in — forcing the app dark under a
light system would otherwise render it white on white.

## The all-drives root

The Disk target picker offers **All drives** whenever more than one is mounted. It scans each
root in turn — drives are separate devices, and eight concurrent stat threads already saturate
a USB bus — and lands on `/`.

`/` is a real path, deliberately: breadcrumbs, back/forward, the trash allowlist and
`scan_entries` all keep working with no special case. The only thing that needs handling is
what its children are called. Each drive is stored under `/` with its path minus the leading
slash as the **name** (`Users/you`, `Volumes/External SSD`), so appending it to `/`
rebuilds the real path; `SizeEntry.label` carries the readable version (`Home`, `External SSD`)
and `display` is what rows render. **`name` stays the navigation key everywhere — never render
it, never navigate by `display`.**

This view is the first place a whole drive appears as a row with a Move to Trash beside it.
`Trash.isRootLike` refuses `/`, the home folder, and anything directly under `/Volumes`, and
it lives in `moveToTrash` rather than in the menu because that is the one function every
deletion in the app goes through. The context menu also stops offering the action, so the
refusal is a backstop rather than the user's first encounter with it.

## Scan results are kept per root

`scan_entries` holds every scanned root at once, not one at a time. `buildTree` removes only
the rows under the root it is replacing, so scanning the T7 leaves Home's tree alone and
switching target in the picker browses the stored result with no rescan — the Scan button
refreshes what is shown, it is not how you get to see it. Each root carries its own timestamp
in `diskScanTimes`, and the picker prints the age beside every target so it is obvious which
ones are already there.

Two rules this must keep:

1. **An empty scan never replaces a tree that has rows.** A drive that comes back with nothing
   is a bug or a permissions wall far more often than an empty drive — that is exactly how the
   unscannable-T7 defect turned into a deleted Home scan. `buildTree` returns the roots it
   actually wrote so a refused one keeps its old rows *and* its old timestamp.
2. **The combined root reports its stalest member.** `lastScanAt` for `/` is the `min` of the
   drive timestamps, never the newest — a stale number wearing a fresh label is worse than no
   number.

Prefix matching uses `substr(parent, 1, n) = ?`, not `LIKE` or `GLOB`: a volume name may
contain `%`, `_`, `[` or `*`, and both of those would treat them as wildcards.

## Liquid Glass

Adopted for the **interface layer only**, per Apple's guidance that Liquid Glass belongs to
what floats above content, not to content itself. This app is mostly dense tabular data, so
the split is strict:

| glass | opaque |
|---|---|
| the 64pt rail | table rows (SizeRow, CacheRow, OutlineRow, CompactRow) |
| page headers | coach cards |
| the Disk toolbar (target picker, Scan, mode switch) | treemap and bubbles |
| the menu bar popover | the metric strip inside it |
| every sheet (trash, uninstall, Get Info, quit) | list and detail panes |
| primary controls (`.glass`, `.glassProminent`) | badges and pills |

Two rules with the same weight as the placement:

1. **Never stack glass on glass.** Nested layers read as muddy grey rather than depth, which
   is why a sheet is glass but its rows are not.
2. **Legibility outranks the effect.** Anything carrying a number a decision rests on stays
   on an opaque surface.

The popover's `NSVisualEffectView` was replaced by `.glassEffect`; the deployment target is
`macOS 26` (`Package.swift` uses the string form, the enum has no `.v26`).

## Rules the next change must keep

1. **Native, dense, macOS.** If a change would look at home on a phone, it is wrong here.
   No bottom tabs, no FABs, no oversized touch targets, no second navigation.
2. **Colour only for severity or treemap file type.** Everything else is neutral.
3. **The why-line is mandatory.** A card showing a size without its evidence does not ship.
4. **All figures are tabular.**
5. **Icons are SF Symbols. No emoji**, in UI or in copy.
6. **One action per card, and it never performs the fix** — except the Clean view, whose one
   action is always and only **"Move to Trash"**, never "Clean", "Optimize", or "Free up".
7. **Destructive confirmations stay blue, with Cancel focused**, and always state recoverability.
8. **Cards do not nest.**
9. **Every token carries both values** — never hard-code a bare hex or a bare `.white` at a call site. The one sanctioned exception is the treemap, whose tile fills are a fixed palette by design, so the black label and white hairline drawn on them are correct in either mode.
10. **Glass is chrome, never content.** If a surface carries a figure the user will act on, it is opaque. Never nest glass inside glass.
10. **Never state a status the app cannot evidence.**
