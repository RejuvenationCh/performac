// DashboardView.swift — replaces the old Today screen.
//
// Today only ever rendered the time-sensitive kinds (drive, thermal, backup), which on a
// healthy machine is nothing at all, so it was a permanently empty page. This answers the
// question that screen should have answered: what is worth knowing about this Mac. Live
// CPU, memory, network and temperature graphs lived here until Vorssaint covered them.
import SwiftUI

struct DashboardView: View {
    var findings: [Finding] = []
    var facts = EngineStore.QuietFacts()
    var trendPoints: [Double] = []
    var trendNote: String = ""
    var updatedAt: Date? = nil
    var busy: Bool = false
    var onRefresh: () -> Void = {}
    var quitAction: (String) -> Void = { _ in }
    var onIgnore: ((String) -> Void)? = nil
    var onLink: (FindingLink) -> Void = { _ in }

    /// Most severe first. A stable sort on a rank rather than a filter per severity, so adding
    /// a severity can never silently drop its cards off this screen.
    private var worst: [Finding] {
        func rank(_ s: Severity) -> Int { switch s { case .red: 0; case .amber: 1; case .info: 2 } }
        return findings.enumerated()
            .sorted { (rank($0.element.severity), $0.offset) < (rank($1.element.severity), $1.offset) }
            .map(\.element)
    }

    var body: some View {
        Page(title: "Dashboard",
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

                    if !trendPoints.isEmpty {
                        VStack(alignment: .leading, spacing: PC.s2) {
                            SectionHeader(text: "Free space over time")
                            Sparkline(values: trendPoints).frame(height: 46)
                            Text(trendNote).font(.pcSmall).foregroundStyle(PC.ink2)
                        }
                        .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()
                    }

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
                                          onIgnore: onIgnore, onLink: onLink)
                        }
                    }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
            }
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
            Text(caption).font(.system(size: 10)).foregroundStyle(PC.meta).lineLimit(1)
        }
        .padding(PC.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pcCard()
    }
}
