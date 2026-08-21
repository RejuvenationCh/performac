import SwiftUI

/// "Updated 2 minutes ago" plus the control that actually re-measures. Findings are computed
/// on a schedule, so without this a card gives no clue how old its numbers are.
struct FreshnessBar: View {
    let at: Date?
    let busy: Bool
    let onRefresh: () -> Void
    private var text: String {
        guard let at else { return "Not measured yet" }
        let s = Int(Date().timeIntervalSince(at))
        if s < 45 { return "Updated just now" }
        if s < 5400 { return "Updated \(s / 60) min ago" }
        if s < 172_800 { return "Updated \(s / 3600) hours ago" }
        return "Updated \(s / 86_400) days ago"
    }
    var body: some View {
        HStack(spacing: PC.s2) {
            if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
            Text(busy ? "Measuring…" : text).font(.pcSmall).foregroundStyle(PC.meta)
            Button { onRefresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise").font(.pcLabel)
            }
            .controlSize(.small).disabled(busy)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Re-measure caches, backups, drift and the Trash. Cmd-Shift-R")
        }
    }
}

struct TodayView: View {
    var findings: [Finding] = Sample.findings
    var quitAction: (String) -> Void = { _ in }
    var updatedAt: Date? = nil
    var busy: Bool = false
    var onRefresh: () -> Void = {}
    var body: some View {
        Page(title: "Today", subtitle: "Live view — drives, thermals, and anything time-sensitive.",
             trailing: AnyView(FreshnessBar(at: updatedAt, busy: busy, onRefresh: onRefresh))) {
            if findings.isEmpty { QuietState() }
            else {
                ScrollView {
                    VStack(spacing: PC.gutter) {
                        ForEach(findings) { CoachCardView(finding: $0, onQuit: quitAction) }
                    }
                    .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
                }
            }
        }
    }
}

/// The app's most common state. It must look deliberate, never broken or unloaded.
struct QuietState: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(PC.green)
            Text("Nothing worth doing").font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.top, PC.gutter)
            Text("Performac has been watching for 6 days. Caches are in normal range,\ndrives are steady, free space is holding.")
                .font(.pcBody).foregroundStyle(PC.ink2)
                .multilineTextAlignment(.center).lineSpacing(2).padding(.top, PC.s1)
            HStack(spacing: PC.s2) {
                QuietTile("Free space", "66 GB")
                QuietTile("Largest cache", "29.8 GB")
                QuietTile("Drives steady", "6 days")
                QuietTile("Last scan", "2 hours ago")
            }
            .padding(.top, PC.stack + 4)
            Spacer()
            Text("Last checked 30 seconds ago").font(.pcSmall).foregroundStyle(PC.meta)
                .padding(.bottom, PC.stack)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuietTile: View {
    let label: String, value: String
    init(_ l: String, _ v: String) { label = l; value = v }
    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.pcLabel).foregroundStyle(PC.meta)
            Text(value).font(.pcNum).fontWeight(.medium).foregroundStyle(PC.ink)
        }
        .frame(width: 108).padding(.vertical, PC.s2 + 2)
        .background(PC.surface).clipShape(RoundedRectangle(cornerRadius: PC.rLg))
        .overlay(RoundedRectangle(cornerRadius: PC.rLg).stroke(PC.hairline, lineWidth: 1))
    }
}

struct DigestView: View {
    var findings: [Finding] = Sample.findings
    var quitAction: (String) -> Void = { _ in }
    var updatedAt: Date? = nil
    var busy: Bool = false
    var onRefresh: () -> Void = {}
    var trendPoints: [Double] = []
    var trendWindow: String = ""
    var trendNote: String = ""

    /// Templated from the findings actually present. It never claims more than the cards do.
    private var summary: String {
        if findings.isEmpty {
            return "Nothing worth doing. Caches are in normal range and nothing has changed enough to mention."
        }
        let red = findings.filter { $0.severity == .red }.count
        let amber = findings.filter { $0.severity == .amber }.count
        var parts: [String] = []
        if red > 0 { parts.append("\(red) needing attention") }
        if amber > 0 { parts.append("\(amber) worth a look") }
        let head = parts.isEmpty
            ? "\(findings.count) thing\(findings.count == 1 ? "" : "s") to know about"
            : parts.joined(separator: " and ")
        return "\(head), biggest first. Each card carries the evidence behind it — the age, the trend, or the count that made it worth showing."
    }
    var body: some View {
        Page(title: "Digest", subtitle: "Weekly read — the trends behind the cards.",
             trailing: AnyView(FreshnessBar(at: updatedAt, busy: busy, onRefresh: onRefresh))) {
            ScrollView {
                VStack(alignment: .leading, spacing: PC.gutter) {
                    VStack(alignment: .leading, spacing: PC.s2) {
                        SectionHeader(text: "Summary")
                        Text(summary)
                            .font(.pcBody).foregroundStyle(PC.ink2).lineSpacing(3)
                            .frame(maxWidth: 620, alignment: .leading)
                    }
                    .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                    VStack(alignment: .leading, spacing: PC.s2) {
                        SectionHeader(text: trendWindow.isEmpty ? "Free space" : "Free space, last \(trendWindow)")
                        if trendPoints.count >= 2 {
                            Sparkline(values: trendPoints).frame(height: 54)
                        } else {
                            Text("Not enough samples to draw yet.")
                                .font(.pcSmall).foregroundStyle(PC.meta)
                                .frame(height: 54, alignment: .leading)
                        }
                        Text(trendNote).font(.pcSmall).foregroundStyle(PC.ink2)
                    }
                    .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                    ForEach(findings) { CoachCardView(finding: $0, onQuit: quitAction) }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let span = max(hi - lo, 0.001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * Double(i) / Double(max(values.count - 1, 1)),
                        y: g.size.height * (1 - (v - lo) / span))
            }
            ZStack {
                Path { p in p.addLines(pts) }
                    .stroke(PC.accentFill, style: .init(lineWidth: 1.5, lineJoin: .round))
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [PC.accentFill.opacity(0.18), .clear],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
    }
}
