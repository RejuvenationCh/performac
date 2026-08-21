// Components.swift — the shared vocabulary from DESIGN.md §Components, built as recorded
// from the Stitch artifact (4pt severity spine, mandatory why-line, at most one link-out).
import SwiftUI
import AppKit

/// Popover vibrancy. DESIGN.md: a flat popover reads as a screenshot pasted on the desktop.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// The load-bearing component. Headline + evidence + at most one link-out that never acts.
struct CoachCardView: View {
    let finding: Finding
    var onQuit: (String) -> Void = { _ in }
    @State private var confirming = false
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
                            Button(link) {}.buttonStyle(.plain)
                                .font(.pcLabel).foregroundStyle(PC.accent)
                        }
                        // Offered only when the process is live and passes every refusal.
                        if let target = finding.quitTarget {
                            Button("Quit \(target)") { confirming = true }
                                .buttonStyle(.plain)
                                .font(.pcLabel).foregroundStyle(PC.red)
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
                Text("Performac asks the app to quit, the same way Cmd-Q does — if it has unsaved work it will prompt you first. It is not forced.")
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

/// Popover header cell: uppercase label above a tabular value.
struct MetricTile: View {
    let label: String, value: String
    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.pcLabel).foregroundStyle(PC.meta).tracking(0.4)
            Text(value).font(.pcNum).fontWeight(.medium).foregroundStyle(PC.ink)
        }
        .frame(maxWidth: .infinity)
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
    private var usedFrac: Double { 1 - Double(freeBytes) / Double(totalBytes) }
    private var tint: Color { usedFrac > 0.92 ? PC.red : usedFrac > 0.85 ? PC.amber : PC.accentFill }
    var body: some View {
        // Single line so it centres with the controls beside it: the old two-line stack made
        // the toolbar taller than its own contents and pushed everything off-centre.
        HStack(spacing: PC.s2) {
            Text(Fmt.bytes(freeBytes)).font(.pcNum).fontWeight(.semibold).foregroundStyle(tint)
            Text("free of \(Fmt.bytes(totalBytes))").font(.pcSmall).foregroundStyle(PC.ink2)
            ZStack(alignment: .leading) {
                Capsule().fill(PC.fill3)
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: g.size.width * usedFrac)
                }
            }
            .frame(width: 96, height: 5)
            Text("\(Int(usedFrac * 100))%").font(.pcNum).foregroundStyle(tint)
        }
        .help("\(Fmt.bytes(freeBytes)) free of \(Fmt.bytes(totalBytes)) — \(Int(usedFrac * 100))% full")
    }
}

/// One row of the disk browser: name, item count, size, proportional bar.
struct SizeRow: View {
    let entry: SizeEntry, maxBytes: Int64
    var onOpen: () -> Void = {}
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
                    IconButton("magnifyingglass", help: "Reveal in Finder")
                    IconButton("trash", help: "Move to Trash")
                }
                .transition(.opacity)
            }
            Text(Fmt.count(entry.items)).font(.pcNum).foregroundStyle(PC.meta)
                .frame(width: 64, alignment: .trailing)
            Text(Fmt.bytes(entry.bytes)).font(.pcNum).foregroundStyle(PC.ink)
                .frame(width: 72, alignment: .trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(PC.fill3)
                    Capsule().fill(PC.accentFill)
                        .frame(width: g.size.width * (Double(entry.bytes) / Double(max(maxBytes, 1))))
                }
            }
            .frame(width: 90, height: 4)
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, 7)
        .background(hover ? PC.fill1 : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if isFolder { onOpen() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(isFolder ? "Double-click to open \(entry.name)" : entry.name)
    }
}

struct IconButton: View {
    let name: String, help: String
    init(_ name: String, help: String) { self.name = name; self.help = help }
    var body: some View {
        Button { } label: {
            Image(systemName: name).font(.system(size: 12)).foregroundStyle(PC.ink2)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain).help(help)
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
        let w = s / 604_800, d = s % 604_800 / 86_400                       // 3w 2d ago
        return d == 0 ? "\(w)w ago" : "\(w)w \(d)d ago"
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
