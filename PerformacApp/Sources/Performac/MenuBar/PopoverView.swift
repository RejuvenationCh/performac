// PopoverView.swift — 380x520 menu bar surface.
//
// Metric strip, live graphs, then whatever is actually worth telling you. The graphs earn
// their place: a number alone cannot show that CPU has been pinned for a minute rather than
// spiking as you looked.
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store = EngineStore.shared
    @ObservedObject var live = MetricsStore.shared
    var onOpenWindow: () -> Void = {}
    var onScan: () -> Void = {}

    /// Time-sensitive findings first; if there are none, everything else. Showing only the
    /// live kinds left the popover blank on a healthy machine, which read as broken.
    private var cards: [Finding] { store.live.isEmpty ? store.digest : store.live }

    @ViewBuilder private func tile(_ g: GraphKind) -> some View {
        switch g {
        case .cpu:
            GraphTile(label: "CPU", value: String(format: "%.0f%%", live.current.cpuPercent),
                      values: live.cpuSeries, tint: PC.accentFill, ceiling: 100)
        case .memory:
            GraphTile(label: "MEMORY", value: String(format: "%.0f%%", live.current.memPercent),
                      values: live.memSeries, tint: PC.green, ceiling: 100)
        case .network:
            GraphTile(label: "NETWORK", value: rate(live.current.netDownBps),
                      values: live.netDownSeries, tint: PC.accent)
        case .temperature:
            GraphTile(label: "TEMPERATURE",
                      value: live.current.tempC.map { String(format: "%.0f°C", $0) } ?? "n/a",
                      values: live.tempSeries, tint: PC.red)
        }
    }

    private func shortLabel(_ t: MetricTileKind) -> String {
        switch t {
        case .cpu: "CPU"; case .ram: "RAM"; case .free: "FREE"; case .temp: "TEMP"
        case .network: "NET"; case .battery: "BATT"; case .diskUsed: "DISK"
        }
    }

    private func tileValue(_ t: MetricTileKind) -> String {
        let m = live.current
        switch t {
        case .cpu: return String(format: "%.0f%%", m.cpuPercent)
        case .ram: return String(format: "%.1f/%.0f GB", m.memUsedGb, m.memTotalGb)
        case .free: return String(format: "%.0f GB", m.freeGb)
        // A real number now: the die sensors are readable, so "Normal" was hiding
        // information the machine was willing to give.
        case .temp: return m.tempC.map { String(format: "%.0f°C", $0) } ?? m.thermal
        case .network: return rate(m.netDownBps)
        case .battery: return m.batteryPercent >= 0 ? "\(m.batteryPercent)%" : "n/a"
        case .diskUsed: return String(format: "%.0f%%", m.diskUsedPercent)
        }
    }

    private func rate(_ bps: Double) -> String {
        let mb = bps / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bps / 1024)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                let tiles = store.metricTiles
                ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { Divider().frame(height: 26) }
                    MetricTile(label: shortLabel(t), value: tileValue(t))
                }
            }
            .padding(.vertical, PC.gutter)
            .pcHairline(.bottom)

            ScrollView {
                VStack(spacing: PC.gutter) {
                    // Percentages are pinned to 100 so the trace is comparable minute to
                    // minute; throughput scales to its own peak because it has no ceiling.
                    // two per row, in whatever order Settings has them enabled
                    let tiles = store.popoverGraphs
                    ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { i in
                        HStack(spacing: PC.s2) {
                            tile(tiles[i])
                            if i + 1 < tiles.count { tile(tiles[i + 1]) } else { Spacer() }
                        }
                    }

                    if !store.popoverShowsFindings {
                        EmptyView()
                    } else if cards.isEmpty {
                        VStack(spacing: PC.s2) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 24)).foregroundStyle(PC.green)
                            Text("Nothing worth doing").font(.pcTitle).foregroundStyle(PC.ink)
                            Text("Caches are in range and drives are steady.")
                                .font(.pcSmall).foregroundStyle(PC.ink2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ForEach(cards) { f in
                            CoachCardView(finding: f, onQuit: { store.requestQuit($0) })
                        }
                    }
                }
                .padding(PC.gutter)
            }

            HStack {
                Button("Scan Disk", action: onScan).controlSize(.small)
                Spacer()
                Button("Open Performac", action: onOpenWindow)
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2 + 2)
            .pcHairline(.top)
        }
        .frame(width: 380, height: 520)
        .pcGlassPanel(PC.rXl)
        .environment(\.colorScheme, .light)
    }
}
