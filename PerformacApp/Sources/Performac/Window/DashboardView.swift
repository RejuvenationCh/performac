// DashboardView.swift — replaces the old Today screen.
//
// Today only ever rendered the time-sensitive kinds (drive, thermal, backup), which on a
// healthy machine is nothing at all, so it was a permanently empty page. This answers the
// question that screen should have answered: what is this Mac doing right now, and what is
// worth knowing about it.
import SwiftUI

struct DashboardView: View {
    @ObservedObject var live = MetricsStore.shared
    var findings: [Finding] = []
    var graphs: [GraphKind] = GraphKind.dashboardDefaults
    var facts = EngineStore.QuietFacts()
    var trendPoints: [Double] = []
    var trendNote: String = ""
    var updatedAt: Date? = nil
    var busy: Bool = false
    var onRefresh: () -> Void = {}
    var quitAction: (String) -> Void = { _ in }

    private var worst: [Finding] {
        let order: [Severity] = [.red, .amber, .info]
        return order.flatMap { sev in findings.filter { $0.severity == sev } }
    }
    private func rate(_ bps: Double) -> String {
        let mb = bps / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f KB/s", bps / 1024)
    }

    var body: some View {
        Page(title: "Dashboard",
             subtitle: "What this Mac is doing now, and what is worth knowing.",
             trailing: AnyView(FreshnessBar(at: updatedAt, busy: busy, onRefresh: onRefresh))) {
            ScrollView {
                VStack(alignment: .leading, spacing: PC.gutter) {
                    // live traces, one card each, only the ones enabled in Settings
                    if !graphs.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: PC.gutter)],
                                  spacing: PC.gutter) {
                            ForEach(graphs) { g in card(for: g) }
                        }
                    }

                    // the four measured facts, no invented numbers
                    HStack(spacing: PC.gutter) {
                        StatTile("Free space", String(format: "%.0f GB", facts.freeGb),
                                 String(format: "%.0f%% of the disk in use", live.current.diskUsedPercent))
                        StatTile("Largest cache",
                                 facts.largestCacheGb >= 0.1
                                    ? String(format: "%.1f GB", facts.largestCacheGb) : "none yet",
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
                        ForEach(worst) { CoachCardView(finding: $0, onQuit: quitAction) }
                    }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
            }
        }
    }

    @ViewBuilder private func card(for g: GraphKind) -> some View {
        switch g {
        case .cpu:
            GraphCard(title: "CPU", value: String(format: "%.0f%%", live.current.cpuPercent),
                      values: live.cpuSeries, tint: PC.accentFill, ceiling: 100)
        case .memory:
            GraphCard(title: "Memory",
                      value: String(format: "%.1f / %.0f GB", live.current.memUsedGb, live.current.memTotalGb),
                      values: live.memSeries, tint: PC.green, ceiling: 100)
        case .network:
            GraphCard(title: "Network",
                      value: "\(rate(live.current.netDownBps)) down",
                      values: live.netDownSeries, tint: PC.accent,
                      secondary: (values: live.netUpSeries, tint: PC.amber,
                                  caption: "\(rate(live.current.netUpBps)) up"))
        case .disk:
            GraphCard(title: "Free space",
                      value: String(format: "%.0f GB", live.current.freeGb),
                      values: live.history.map(\.freeGb), tint: PC.amber)
        }
    }
}

/// One live trace, optionally with a second series drawn behind it (network up and down).
struct GraphCard: View {
    let title: String
    let value: String
    let values: [Double]
    var tint: Color = PC.accentFill
    var ceiling: Double? = nil
    var secondary: (values: [Double], tint: Color, caption: String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: PC.s1) {
            HStack {
                Text(title).font(.pcLabel).foregroundStyle(PC.meta)
                Spacer()
                Text(value).font(.pcNum).fontWeight(.medium).foregroundStyle(PC.ink)
            }
            ZStack {
                if let s = secondary { MiniGraph(values: s.values, tint: s.tint, width: 206, height: 56) }
                MiniGraph(values: values, tint: tint, ceiling: ceiling, width: 206, height: 56)
            }
            if let s = secondary {
                Text(s.caption).font(.system(size: 10)).foregroundStyle(s.tint)
            }
        }
        .padding(PC.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pcCard()
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
