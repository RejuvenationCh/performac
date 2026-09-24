// PopoverView.swift — 380x520 menu bar surface.
//
// Whatever is actually worth telling you. Live CPU, memory, network and temperature used to
// sit above this; Vorssaint's menu bar already shows them, so they went.
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store = EngineStore.shared
    var onOpenWindow: () -> Void = {}
    var onScan: () -> Void = {}

    /// Time-sensitive findings first; if there are none, everything else. Showing only the
    /// live kinds left the popover blank on a healthy machine, which read as broken.
    private var cards: [Finding] { store.live.isEmpty ? store.digest : store.live }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: PC.gutter) {
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
                            CoachCardView(finding: f, onQuit: { store.requestQuit($0) },
                                          onIgnore: { store.ignoreProcess($0) },
                                          onLink: openLink)
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
        // No forced colorScheme here. It used to pin `.light`, which did NOT affect the PC.*
        // tokens — those resolve off NSAppearance (Tokens.swift) — but did flip SwiftUI's own
        // materials, glass, progress indicators and button chrome. Under a dark system that
        // left the popover half light and half dark.
    }

    /// A card's link, from the menu bar. Navigating needs the window; revealing does not.
    private func openLink(_ link: FindingLink) {
        if case .clean = link { onOpenWindow() }
        store.openLink(link)
    }
}
