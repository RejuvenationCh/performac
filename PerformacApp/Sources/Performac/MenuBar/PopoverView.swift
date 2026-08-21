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

    private func rate(_ bps: Double) -> String {
        let mb = bps / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bps / 1024)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MetricTile(label: "CPU", value: String(format: "%.0f%%", live.current.cpuPercent))
                Divider().frame(height: 26)
                MetricTile(label: "RAM", value: String(format: "%.1f/%.0f GB",
                                                       live.current.memUsedGb, live.current.memTotalGb))
                Divider().frame(height: 26)
                MetricTile(label: "FREE", value: String(format: "%.0f GB", live.current.freeGb))
                Divider().frame(height: 26)
                MetricTile(label: "TEMP", value: live.current.thermal)
            }
            .padding(.vertical, PC.gutter)
            .pcHairline(.bottom)

            ScrollView {
                VStack(spacing: PC.gutter) {
                    // Percentages are pinned to 100 so the trace is comparable minute to
                    // minute; throughput scales to its own peak because it has no ceiling.
                    HStack(spacing: PC.s2) {
                        GraphTile(label: "CPU",
                                  value: String(format: "%.0f%%", live.current.cpuPercent),
                                  values: live.cpuSeries, tint: PC.accentFill, ceiling: 100)
                        GraphTile(label: "MEMORY",
                                  value: String(format: "%.0f%%", live.current.memPercent),
                                  values: live.memSeries, tint: PC.green, ceiling: 100)
                    }
                    HStack(spacing: PC.s2) {
                        GraphTile(label: "DOWN", value: rate(live.current.netDownBps),
                                  values: live.netDownSeries, tint: PC.accent)
                        GraphTile(label: "UP", value: rate(live.current.netUpBps),
                                  values: live.netUpSeries, tint: PC.amber)
                    }

                    if cards.isEmpty {
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
