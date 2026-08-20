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
                    if let link = finding.link {
                        Button(link) {}.buttonStyle(.plain)
                            .font(.pcLabel).foregroundStyle(PC.accent).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(PC.gutter)
        }
        .pcCard()
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
        VStack(alignment: .trailing, spacing: PC.s1) {
            HStack(spacing: 4) {
                Text(Fmt.bytes(freeBytes)).font(.pcNum).fontWeight(.semibold).foregroundStyle(tint)
                Text("free of \(Fmt.bytes(totalBytes)) — \(Int(usedFrac * 100))% full")
                    .font(.pcSmall).foregroundStyle(PC.ink2)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(PC.fill3)
                    Capsule().fill(tint).frame(width: g.size.width * usedFrac)
                }
            }
            .frame(width: 180, height: 4)
        }
    }
}

/// One row of the disk browser: name, item count, size, proportional bar.
struct SizeRow: View {
    let entry: SizeEntry, maxBytes: Int64
    @State private var hover = false
    var body: some View {
        HStack(spacing: PC.gutter) {
            Image(systemName: entry.symbol).font(.system(size: 13)).foregroundStyle(entry.kind.color)
                .frame(width: 16)
            Text(entry.name).font(.pcBody).foregroundStyle(PC.ink).lineLimit(1)
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
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
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
