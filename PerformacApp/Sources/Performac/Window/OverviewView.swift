// OverviewView.swift — replaces Dashboard and Digest, which rendered the same
// `store.digest` array through the same CoachCardView in two sort orders, on two of six
// rail slots. One screen: the four measured facts, the summary (with the Gemini rewrite),
// the free-space trend, then findings ranked worst-first.
import SwiftUI

struct OverviewView: View {
    var findings: [Finding] = []
    var facts = EngineStore.QuietFacts()
    var updatedAt: Date? = nil
    var busy: Bool = false
    var onRefresh: () -> Void = {}
    var quitAction: (String) -> Void = { _ in }
    var onIgnore: ((String) -> Void)? = nil
    var onLink: (FindingLink) -> Void = { _ in }
    var onDisableAgent: (String) -> Void = { _ in }
    var coachIntro: String? = nil
    var coachAt: Date? = nil
    var coachBusy: Bool = false
    var coachConfigured: Bool = false
    var onCoach: () -> Void = {}
    var trendPoints: [Double] = []
    var trendWindow: String = ""
    var trendNote: String = ""
    var trendVolume: String = ""

    /// Most severe first. A stable sort on a rank rather than a filter per severity, so adding
    /// a severity can never silently drop its cards off this screen.
    private var worst: [Finding] {
        func rank(_ s: Severity) -> Int { switch s { case .red: 0; case .amber: 1; case .info: 2 } }
        return findings.enumerated()
            .sorted { (rank($0.element.severity), $0.offset) < (rank($1.element.severity), $1.offset) }
            .map(\.element)
    }

    /// Templated from the findings actually present. It never claims more than the cards do.
    private var summary: String {
        if findings.isEmpty {
            return "Nothing worth doing. Caches are in normal range and nothing has changed enough to mention."
        }
        // The breakdown has to add up to the heading's total. This counted only red and amber,
        // so it read "1 needing attention and 1 worth a look" directly above a section heading
        // that said 19 — the summary contradicting the list it introduces.
        let red = findings.filter { $0.severity == .red }.count
        let amber = findings.filter { $0.severity == .amber }.count
        let info = findings.count - red - amber
        var parts: [String] = []
        if red > 0 { parts.append("\(red) needing attention") }
        if amber > 0 { parts.append("\(amber) worth a look") }
        if info > 0 { parts.append("\(info) for information") }
        return "\(findings.count) in total — \(parts.joined(separator: ", ")), biggest first. "
             + "Each card carries the evidence behind it: the age, the trend, or the count that made it worth showing."
    }

    var body: some View {
        Page(title: "Overview",
             subtitle: "What is worth knowing about this Mac.",
             trailing: AnyView(FreshnessBar(at: updatedAt, busy: busy, onRefresh: onRefresh))) {
            ScrollView {
                VStack(alignment: .leading, spacing: PC.gutter) {
                    // the four measured facts, no invented numbers
                    HStack(spacing: PC.gutter) {
                        // Every size goes through Fmt, so this agrees with the Disk toolbar.
                        // It used to print raw GiB labelled "GB" and disagree by 7.4%.
                        StatTile("Free space",
                                 facts.totalBytes > 0 ? Fmt.bytes(facts.freeBytes) : "—",
                                 facts.totalBytes > 0
                                    ? String(format: "%.0f%% of the disk in use",
                                             (1 - Double(facts.freeBytes) / Double(facts.totalBytes)) * 100)
                                    : "not measured yet")
                        StatTile("Largest cache",
                                 facts.largestCacheBytes >= 100_000_000
                                    ? Fmt.bytes(facts.largestCacheBytes) : "none yet",
                                 "biggest single cache measured")
                        StatTile("Drives quiet",
                                 facts.drivesQuietDays.map { $0 == 0 ? "today" : "\($0)d" } ?? "none seen",
                                 "since the last connect or eject")
                        StatTile("Watching",
                                 facts.watchingDays < 1 ? "<1d" : "\(facts.watchingDays)d",
                                 "of history collected")
                    }

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
                        // Names the volume: this chart is boot-only, and a card above it can
                        // be about an external drive heading for full.
                        SectionHeader(text: trendWindow.isEmpty
                                      ? "\(trendVolume) — free space"
                                      : "\(trendVolume) — free space, last \(trendWindow)")
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

                    if worst.isEmpty {
                        HStack(spacing: PC.s2) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(PC.green)
                            Text("Nothing worth doing.").font(.pcBody).foregroundStyle(PC.ink2)
                            Spacer()
                        }
                        .padding(PC.gutter).pcCard()
                    } else {
                        SectionHeader(text: "Worth knowing (\(worst.count))")
                        ForEach(worst) {
                            CoachCardView(finding: $0, onQuit: quitAction,
                                          onIgnore: onIgnore, onLink: onLink,
                                          onDisableAgent: onDisableAgent)
                        }
                    }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
            }
        }
    }
}

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

struct StatTile: View {
    let label: String, value: String, caption: String
    init(_ l: String, _ v: String, _ c: String) { label = l; value = v; caption = c }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.pcLabel).foregroundStyle(PC.meta)
            Text(value).font(.pcNumLg).foregroundStyle(PC.ink)
            Text(caption).font(.pcLabel).foregroundStyle(PC.meta).lineLimit(1)
        }
        .padding(PC.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pcCard()
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
