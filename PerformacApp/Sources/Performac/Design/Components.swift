// Components.swift: the shared vocabulary from DESIGN.md §Components, built as recorded
// 4pt severity spine, mandatory why-line, at most one link-out.
import SwiftUI
import AppKit

/// The load-bearing component. Headline + evidence + at most one link-out, which navigates or
/// reveals but never performs the fix.
struct FindingCard: View {
    let finding: Finding
    var onQuit: (String) -> Void = { _ in }
    var onIgnore: ((String) -> Void)? = nil
    var onLink: (FindingLink) -> Void = { _ in }
    var onDisableAgent: (String) -> Void = { _ in }
    @State private var confirming = false
    @State private var confirmingDisable = false

    /// The link says where it goes; the tooltip says what it will actually show you.
    private func linkHelp(_ link: FindingLink) -> String {
        switch link {
        case .reveal(let path):
            return "Select \((path as NSString).lastPathComponent) in Finder"
        case .activityMonitor: return "Open Activity Monitor"
        case .clean:           return "Go to the Clean screen"
        case .loginSettings:   return "Open System Settings → General → Login Items"
        case .disableAgent(let path): return "Unload and Trash \((path as NSString).lastPathComponent)"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(finding.severity.tint).frame(width: 4)   // severity spine
            HStack(alignment: .top, spacing: PC.s2) {
                Image(systemName: finding.severity.symbol)
                    .font(.system(size: 14)).foregroundStyle(finding.severity.tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: PC.s1) {
                    Text(finding.headline).font(.pcTitle).foregroundStyle(PC.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(finding.why).font(.pcBody).foregroundStyle(PC.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: PC.gutter) {
                        if let link = finding.link {
                            // `.disableAgent` acts rather than navigates, so it is confirmed
                            // first: same shape as the quit button below, never bare onLink.
                            Button(link.label) {
                                if case .disableAgent = link { confirmingDisable = true }
                                else { onLink(link) }
                            }
                            .buttonStyle(.plain)
                            .font(.pcLabel).foregroundStyle(PC.accent)
                            .help(linkHelp(link))
                        }
                        // Offered only when the process is live and passes every refusal.
                        if let target = finding.quitTarget {
                            Button("Quit \(target)") { confirming = true }
                                .buttonStyle(.plain)
                                .font(.pcLabel).foregroundStyle(PC.red)
                            if let onIgnore {
                                Button("Ignore") { onIgnore(target) }
                                    .buttonStyle(.plain)
                                    .font(.pcLabel).foregroundStyle(PC.meta)
                                    .help("Stop reporting \(target). Undo in Settings.")
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(PC.gutter)
        }
        .pcCard()
        .sheet(isPresented: $confirming) {
            if let target = finding.quitTarget {
                QuitSheet(name: target,
                          onCancel: { confirming = false },
                          onQuit: { confirming = false; onQuit(target) })
            }
        }
        .sheet(isPresented: $confirmingDisable) {
            if case .disableAgent(let path) = finding.link {
                DisableAgentSheet(plistPath: path,
                                  onCancel: { confirmingDisable = false },
                                  onDisable: { confirmingDisable = false; onDisableAgent(path) })
            }
        }
    }
}

/// The confirmation. Quitting is not deletion, but it can still lose work that was never
/// saved, so the sheet says exactly that rather than implying it is free.
struct QuitSheet: View {
    let name: String
    var onCancel: () -> Void
    var onQuit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quit \(name)?").font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, PC.s2)
            HStack(alignment: .top, spacing: PC.gutter) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14)).foregroundStyle(PC.amber)
                Text("Performac asks the app to quit, the same way Cmd-Q does, if it has unsaved work it will prompt you first. It is not forced.")
                    .font(.pcSmall).foregroundStyle(PC.ink2).lineSpacing(2)
            }
            .padding(.horizontal, 24).padding(.bottom, PC.stack)
            HStack(spacing: PC.s2 + 2) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Quit \(name)", action: onQuit).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 460)
        .pcGlassPanel(PC.rXl)
    }
}

/// The confirmation for disabling a LaunchAgent. Per DESIGN.md's destructive-confirmation
/// rule: the primary button stays accent-coloured (not red) because the action is
/// recoverable, Cancel is the default focus, the full path is shown, and recoverability is
/// stated plainly rather than implied.
struct DisableAgentSheet: View {
    let plistPath: String
    var onCancel: () -> Void
    var onDisable: () -> Void
    private var name: String { (plistPath as NSString).lastPathComponent }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Disable \(name)?").font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, PC.s2)
            Text(plistPath).font(.pcSmall).foregroundStyle(PC.ink2)
                .textSelection(.enabled)
                .padding(.horizontal, 24).padding(.bottom, PC.s2)
            HStack(alignment: .top, spacing: PC.gutter) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14)).foregroundStyle(PC.accent)
                Text("Performac unloads it from launchd, then moves this file to the Trash: it is not deleted. You can put it back from Finder, or restore it there, until you empty the Trash.")
                    .font(.pcSmall).foregroundStyle(PC.ink2).lineSpacing(2)
            }
            .padding(.horizontal, 24).padding(.bottom, PC.stack)
            HStack(spacing: PC.s2 + 2) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Disable", action: onDisable).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 460)
        .pcGlassPanel(PC.rXl)
    }
}

struct Pill: View {
    let text: String, tint: Color, soft: Color
    var body: some View {
        Text(text).font(.pcLabel).foregroundStyle(tint)
            .padding(.horizontal, PC.s2).padding(.vertical, 3)
            .background(soft, in: Capsule())
    }
}

struct StorageBar: View {
    let freeBytes: Int64, totalBytes: Int64

    /// nil until there is a real capacity to divide by.
    ///
    /// This crashed the app. Metrics start at zero and the first sample lands two seconds
    /// after launch, so opening Disk inside that window divided by a zero total: 1 - 0/0 is
    /// NaN, and Int(NaN) is a trap, not a zero. Swift's Double-to-Int conversion has no
    /// saturating behaviour to fall back on: it terminates the process. A width of NaN would
    /// have taken the layout down on its own too.
    private var usedFrac: Double? {
        guard totalBytes > 0 else { return nil }
        return min(max(1 - Double(freeBytes) / Double(totalBytes), 0), 1)
    }
    private var tint: Color {
        guard let f = usedFrac else { return PC.meta }
        return f > 0.92 ? PC.red : f > 0.85 ? PC.amber : PC.accentFill
    }

    var body: some View {
        // Single line so it centres with the controls beside it: the old two-line stack made
        // the toolbar taller than its own contents and pushed everything off-centre.
        HStack(spacing: PC.s2) {
            if let frac = usedFrac {
                Text(Fmt.bytes(freeBytes)).font(.pcNum).fontWeight(.semibold).foregroundStyle(tint)
                Text("free of \(Fmt.bytes(totalBytes))").font(.pcSmall).foregroundStyle(PC.ink2)
                ZStack(alignment: .leading) {
                    Capsule().fill(PC.fill3)
                    Capsule().fill(tint).frame(width: 96 * frac)
                }
                .frame(width: 96, height: 5)
                Text("\(Int(frac * 100))%").font(.pcNum).foregroundStyle(tint)
            } else {
                // no capacity yet: say so rather than draw a bar out of nothing
                Text("measuring…").font(.pcSmall).foregroundStyle(PC.meta)
            }
        }
        .help(usedFrac == nil ? "Disk capacity not measured yet"
              : "\(Fmt.bytes(freeBytes)) free of \(Fmt.bytes(totalBytes)): \(Int(usedFrac! * 100))% full")
    }
}

/// One row of the disk browser: name, item count, size, proportional bar.
struct SizeRow: View {
    let entry: SizeEntry, maxBytes: Int64
    var onOpen: () -> Void = {}
    var onReveal: () -> Void = {}
    var onTrash: () -> Void = {}
    @State private var hover = false
    private var isFolder: Bool { entry.symbol == "folder.fill" }
    var body: some View {
        HStack(spacing: PC.gutter) {
            Image(systemName: entry.symbol).font(.system(size: 13)).foregroundStyle(entry.kind.color)
                .frame(width: 16)
            Text(entry.name).font(.pcBody).foregroundStyle(PC.ink).lineLimit(1)
            if isFolder {
                Image(systemName: "chevron.right").font(.system(size: 8))
                    .foregroundStyle(hover ? PC.accent : PC.meta.opacity(0.5))
            }
            Spacer(minLength: PC.s2)
            if hover {
                HStack(spacing: 2) {
                    IconButtonAction("magnifyingglass", help: "Reveal in Finder", action: onReveal)
                    IconButtonAction("trash", help: "Move to Trash…", action: onTrash)
                }
                .transition(.opacity)
            }
            Text(entry.mtime > 0
                 ? Ago.text(Date(timeIntervalSince1970: Double(entry.mtime) / 1000))
                 : "-")
                .font(.pcNum).foregroundStyle(PC.meta)
                .frame(width: 84, alignment: .trailing).lineLimit(1)
            Text(Fmt.count(entry.items)).font(.pcNum).foregroundStyle(PC.meta)
                .frame(width: 64, alignment: .trailing)
            Text(Fmt.bytes(entry.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                .frame(width: 72, alignment: .trailing)
            ProportionBar(fraction: Double(entry.bytes) / Double(max(maxBytes, 1)),
                          width: 90, height: 4)
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, 7)
        .background(hover ? PC.fill1 : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isFolder { onOpen() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(isFolder ? "Double-click to open \(entry.name)" : entry.name)
    }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.pcLabel).tracking(0.6).foregroundStyle(PC.meta)
    }
}


/// Relative time that actually ticks. A static "just now" is still on screen ten minutes
/// later, which is worse than no timestamp: it reads as current when it is not.
enum Ago {
    /// Precision drops as the age grows: seconds matter for something a moment old and are
    /// noise on something from last Tuesday. At most two units, never a smaller one than the
    /// scale warrants.
    static func text(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 1 { return "now" }
        if s < 60 { return "\(s)s ago" }                                   // 42s ago
        if s < 3600 { return "\(s / 60)m ago" }                            // 7m ago
        if s < 86_400 {                                                     // 3h 20m ago
            let h = s / 3600, m = s % 3600 / 60
            return m == 0 ? "\(h)h ago" : "\(h)h \(m)m ago"
        }
        if s < 604_800 {                                                    // 2d 5h ago
            let d = s / 86_400, h = s % 86_400 / 3600
            return h == 0 ? "\(d)d ago" : "\(d)d \(h)h ago"
        }
        // Weeks stop being readable somewhere around two months: a disk browser full of
        // archives was printing "39w 6d ago" and "44w ago", which nobody converts in their
        // head. Past eight weeks the scale is months.
        if s < 4_838_400 {                                                  // 3w 2d ago
            let w = s / 604_800, d = s % 604_800 / 86_400
            return d == 0 ? "\(w)w ago" : "\(w)w \(d)d ago"
        }
        let mo = s / 2_629_800, w = s % 2_629_800 / 604_800                 // 9mo 2w ago
        return w == 0 ? "\(mo)mo ago" : "\(mo)mo \(w)w ago"
    }
}

/// Re-renders once a second so the relative time is never stale on screen.
struct TickingAgo: View {
    let date: Date?
    var prefix: String = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(date.map { prefix + Ago.text($0, now: ctx.date) } ?? (prefix + "never"))
        }
    }
}


/// A column header that is also the sort control. The label IS the button: a separate
/// sort menu would be a second place to look for something the header already implies.
struct SortHeader: View {
    let title: String
    let key: SortKey
    @Binding var state: SortState
    var width: CGFloat? = nil
    var alignment: Alignment = .leading
    @State private var hover = false

    private var active: Bool { state.key == key }

    var body: some View {
        Button {
            state.toggle(key)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title).font(.pcLabel)
                    .foregroundStyle(active ? PC.ink : (hover ? PC.ink2 : PC.meta))
                // only the active column shows a direction; an arrow on every one is noise
                Image(systemName: state.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(active ? PC.accent : .clear)
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Sort by \(title.lowercased())")
    }
}
