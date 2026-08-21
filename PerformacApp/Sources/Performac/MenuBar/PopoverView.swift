// PopoverView.swift — 380x520 menu bar surface: metric strip, advisory cards, two actions.
// It never scrolls past a few cards; more than that is what the window is for.
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store = EngineStore.shared
    var onOpenWindow: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MetricTile(label: "CPU", value: String(format: "%.0f%%", store.metrics.cpuPercent))
                Divider().frame(height: 26)
                MetricTile(label: "RAM", value: String(format: "%.1f/%.0f GB",
                                                       store.metrics.memUsedGb, store.metrics.memTotalGb))
                Divider().frame(height: 26)
                MetricTile(label: "FREE", value: String(format: "%.0f GB", store.metrics.freeGb))
                Divider().frame(height: 26)
                MetricTile(label: "TEMP", value: store.metrics.thermal)
            }
            .padding(.vertical, PC.gutter)
            .pcHairline(.bottom)

            ScrollView {
                VStack(spacing: PC.gutter) {
                    ForEach(store.live) { CoachCardView(finding: $0, onQuit: { store.requestQuit($0) }) }
                }
                .padding(PC.gutter)
            }

            HStack {
                Button("Scan Disk") {}.controlSize(.small)
                Spacer()
                Button("Open Performac", action: onOpenWindow)
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2 + 2)
            .pcHairline(.top)
        }
        .frame(width: 380, height: 520)
        .background(VisualEffect())
        // NSVisualEffectView follows the system appearance, so with the app pinned to light
        // the popover was rendering dark while every other surface was light.
        .environment(\.colorScheme, .light)
    }
}
