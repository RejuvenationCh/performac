// OverviewView.swift: replaces Dashboard and Digest, which rendered the same
// `store.digest` array through the same FindingCard in two sort orders, on two of six
// rail slots. One screen: the four measured facts, the templated summary,
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
    var trendPoints: [TrendPoint] = []
    var trendWindow: String = ""
    var trendNote: String = ""
    var trendVolume: String = ""
    /// The sample under the pointer, reported by the chart and read out in its header.
    @State private var hoveredPoint: TrendPoint? = nil

    /// Short and unambiguous: samples can be minutes apart, so the time matters as much as
    /// the day. en_US to match every other figure in the app.
    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }

    /// Most severe first. A stable sort on a rank rather than a filter per severity, so adding
    /// a severity can never silently drop its cards off this screen.
    private var worst: [Finding] {
        func rank(_ s: Severity) -> Int { switch s { case .red: 0; case .amber: 1; case .info: 2 } }
        return findings.enumerated()
            .sorted { (rank($0.element.severity), $0.offset) < (rank($1.element.severity), $1.offset) }
            .map(\.element)
    }

    /// Two points thirty seconds apart satisfy "count >= 2" and draw a flat line under a
    /// heading reading "last 0 hours", while the note below it correctly says there is not
    /// enough history yet. The x axis has to span something before the line means anything, so
    /// the gate is elapsed time rather than a sample count.
    private var trendDrawable: Bool {
        guard trendPoints.count >= 2,
              let first = trendPoints.first, let last = trendPoints.last else { return false }
        return last.ts - first.ts >= 3_600_000   // one hour
    }

    /// A brand new install has measured nothing yet, which is not the same as having measured
    /// and found nothing. Saying "Nothing worth doing" before the first samples land is the app
    /// claiming a result it has not earned, and it is the first thing anyone sees.
    ///
    /// The card is for the whole first day. It used to also require zero findings, which a new
    /// install almost never has: backup state and old installers need no history and turn up
    /// on the first tick, so the card meant for new users was the one they never saw.
    private var firstDay: Bool { facts.watchingDays < 1 }
    private var nothingMeasured: Bool { firstDay && findings.isEmpty && facts.lastScanAt == nil }

    private var firstRunCard: some View {
        HStack(alignment: .top, spacing: PC.gutter) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 20)).foregroundStyle(PC.accent)
            VStack(alignment: .leading, spacing: PC.s1) {
                Text("Performac has just started watching")
                    .font(.pcTitle).foregroundStyle(PC.ink)
                Text("""
                     It samples every 30 seconds and needs about four days before it can tell a \
                     trend from a normal day, so anything built on a trend stays quiet for now. \
                     Cards that need no history, like old installers or a missing backup, \
                     appear straight away.
                     """)
                    .font(.pcBody).foregroundStyle(PC.ink2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("""
                     Disk and Duplicates do not wait: both answer as soon as you run a scan. \
                     Clean already knows what your caches are holding.
                     """)
                    .font(.pcBody).foregroundStyle(PC.ink2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()
    }

    /// Templated from the findings actually present. It never claims more than the cards do.
    private var summary: String {
        if nothingMeasured {
            return "Nothing measured yet. The facts above fill in as samples arrive; the cards below need a few days of history before they can say anything honest."
        }
        if findings.isEmpty {
            return "Nothing worth doing. Caches are in normal range and nothing has changed enough to mention."
        }
        // The breakdown has to add up to the heading's total. This counted only red and amber,
        // so it read "1 needing attention and 1 worth a look" directly above a section heading
        // that said 19: the summary contradicting the list it introduces.
        let red = findings.filter { $0.severity == .red }.count
        let amber = findings.filter { $0.severity == .amber }.count
        let info = findings.count - red - amber
        var parts: [String] = []
        if red > 0 { parts.append("\(red) needing attention") }
        if amber > 0 { parts.append("\(amber) worth a look") }
        if info > 0 { parts.append("\(info) for information") }
        return "\(findings.count) in total: \(parts.joined(separator: ", ")), biggest first. "
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
                                 facts.totalBytes > 0 ? Fmt.bytes(facts.freeBytes) : "none yet",
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
                        SectionHeader(text: "Summary")
                        Text(summary)
                            .font(.pcBody).foregroundStyle(PC.ink2).lineSpacing(3)
                            .frame(maxWidth: 620, alignment: .leading)
                    }
                    .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                    VStack(alignment: .leading, spacing: PC.s2) {
                        HStack(alignment: .firstTextBaseline) {
                            // Names the volume: this chart is boot-only, and a card above it
                            // can be about an external drive heading for full.
                            SectionHeader(text: trendWindow.isEmpty
                                          ? "\(trendVolume): free space"
                                          : "\(trendVolume): free space, last \(trendWindow)")
                            Spacer()
                            if let p = hoveredPoint {
                                // Value leads, time follows: the reader already knows what the
                                // chart is and came for the number. Monospaced digits so the
                                // readout does not twitch as the pointer sweeps.
                                HStack(spacing: PC.s2) {
                                    Text(Fmt.bytes(p.freeBytes))
                                        .font(.pcNum).fontWeight(.semibold).foregroundStyle(PC.ink)
                                    Text(Self.stamp(p.date))
                                        .font(.pcSmall).foregroundStyle(PC.meta).monospacedDigit()
                                }
                                .transition(.opacity)
                            }
                        }
                        if trendDrawable {
                            Sparkline(points: trendPoints) { hoveredPoint = $0 }
                                .frame(height: 54)
                        } else {
                            Text("Not enough samples to draw yet.")
                                .font(.pcSmall).foregroundStyle(PC.meta)
                                .frame(height: 54, alignment: .leading)
                        }
                        Text(trendNote).font(.pcSmall).foregroundStyle(PC.ink2)
                    }
                    .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                    if firstDay {
                        firstRunCard
                    }
                    if worst.isEmpty {
                        // On day one the card above already says why it is quiet.
                        if !firstDay {
                            HStack(spacing: PC.s2) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(PC.green)
                                Text("Nothing worth doing.").font(.pcBody).foregroundStyle(PC.ink2)
                                Spacer()
                            }
                            .padding(PC.gutter).pcCard()
                        }
                    } else {
                        SectionHeader(text: "Worth knowing (\(worst.count))")
                        ForEach(worst) {
                            FindingCard(finding: $0, onQuit: quitAction,
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

/// The free-space line, with a crosshair that reports the sample under the pointer.
///
/// The pointer aims at a *time*, not at a 1.5pt line: the hover snaps to the nearest sample
/// on X, so the whole height of the chart is the hit target. The readout lives in the card
/// header rather than in a floating bubble: this plot is 54pt tall, and a tooltip inside it
/// would cover the very line it describes.
struct Sparkline: View {
    let points: [TrendPoint]
    var onHover: (TrendPoint?) -> Void = { _ in }
    @State private var hoverIndex: Int? = nil

    var body: some View {
        GeometryReader { g in
            let vals = points.map { Double($0.freeBytes) }
            let lo = vals.min() ?? 0, hi = vals.max() ?? 1
            // A series that never moves is flat, not empty. Normalising it would put every
            // point at (v-lo)/span = 0, i.e. pinned to the bottom edge, which reads as "the
            // disk is full": the same wrong story a flat line at zero told before.
            let flat = (hi - lo) < max(hi, 1) * 0.005
            let span = max(hi - lo, 1)
            let xs = points.indices.map { g.size.width * CGFloat($0) / CGFloat(max(points.count - 1, 1)) }
            let ys = vals.map { v in
                flat ? g.size.height * 0.5 : g.size.height * (1 - CGFloat((v - lo) / span))
            }
            let pts = points.indices.map { CGPoint(x: xs[$0], y: ys[$0]) }

            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [PC.accentFill.opacity(0.18), .clear],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in p.addLines(pts) }
                    .stroke(PC.accentFill, style: .init(lineWidth: 1.5, lineJoin: .round))

                if let i = hoverIndex, points.indices.contains(i) {
                    Rectangle().fill(PC.meta.opacity(0.5))
                        .frame(width: 1, height: g.size.height)
                        .position(x: pts[i].x, y: g.size.height / 2)
                    // a surface ring so the marker reads against the line it sits on
                    Circle().fill(PC.surface).frame(width: 9, height: 9).position(pts[i])
                    Circle().fill(PC.accentFill).frame(width: 5, height: 5).position(pts[i])
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    guard points.count > 1 else { return }
                    let step = g.size.width / CGFloat(points.count - 1)
                    let i = min(max(Int((loc.x / max(step, 0.001)).rounded()), 0), points.count - 1)
                    if i != hoverIndex { hoverIndex = i; onHover(points[i]) }
                case .ended:
                    hoverIndex = nil
                    onHover(nil)
                }
            }
        }
    }
}
