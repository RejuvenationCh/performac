import SwiftUI

/// "Updated 2 minutes ago" plus the control that actually re-measures. Findings are computed
/// on a schedule, so without this a card gives no clue how old its numbers are.
struct FreshnessBar: View {
    let at: Date?
    let busy: Bool
    let onRefresh: () -> Void
    var body: some View {
        HStack(spacing: PC.s2) {
            if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
            if busy {
                Text("Measuring…").font(.pcSmall).foregroundStyle(PC.meta)
            } else if at == nil {
                Text("Not measured yet").font(.pcSmall).foregroundStyle(PC.meta)
            } else {
                TickingAgo(date: at, prefix: "Updated ")
                    .font(.pcSmall).foregroundStyle(PC.meta).monospacedDigit()
            }
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
    var facts = EngineStore.QuietFacts()
    var body: some View {
        Page(title: "Today", subtitle: "Live view — drives, thermals, and anything time-sensitive.",
             trailing: AnyView(FreshnessBar(at: updatedAt, busy: busy, onRefresh: onRefresh))) {
            if findings.isEmpty { QuietState(facts: facts) }
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
    var facts = EngineStore.QuietFacts()
    private var watchedText: String {
        facts.watchingDays < 1 ? "less than a day" : "\(facts.watchingDays) day\(facts.watchingDays == 1 ? "" : "s")"
    }
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(PC.green)
            Text("Nothing worth doing").font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.top, PC.gutter)
            Text("Performac has been watching for \(watchedText). Nothing has changed\nenough to be worth telling you about.")
                .font(.pcBody).foregroundStyle(PC.ink2)
                .multilineTextAlignment(.center).lineSpacing(2).padding(.top, PC.s1)
            HStack(spacing: PC.s2) {
                QuietTile("Free space", String(format: "%.0f GB", facts.freeGb))
                QuietTile("Largest cache", facts.largestCacheGb >= 0.1
                          ? String(format: "%.1f GB", facts.largestCacheGb) : "none yet")
                // Days since the last mount/unmount. No events ever seen means nothing has
                // been plugged in while watching, which is not the same as "steady".
                QuietTile("Drives quiet", facts.drivesQuietDays.map {
                    $0 == 0 ? "today" : "\($0)d" } ?? "none seen")
                QuietTile("Last scan", facts.lastScanAt == nil ? "never" : "")
                    .overlay(alignment: .bottom) {
                        if let d = facts.lastScanAt {
                            TickingAgo(date: d).font(.pcNum).fontWeight(.medium)
                                .foregroundStyle(PC.ink).padding(.bottom, 10)
                        }
                    }
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
    var coachIntro: String? = nil
    var coachAt: Date? = nil
    var coachBusy: Bool = false
    var coachConfigured: Bool = false
    var onCoach: () -> Void = {}
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
                        HStack {
                            SectionHeader(text: "Summary")
                            Spacer()
                            if coachConfigured {
                                if coachBusy {
                                    ProgressView().controlSize(.small).scaleEffect(0.6)
                                } else {
                                    Button("Rewrite", action: onCoach)
                                        .buttonStyle(.link).font(.pcLabel)
                                        .help("Ask Gemini to summarise the findings below")
                                }
                            }
                        }
                        // Gemini's paragraph when configured and available; otherwise the
                        // templated one. Either way it only restates the cards.
                        Text(coachIntro ?? summary)
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
