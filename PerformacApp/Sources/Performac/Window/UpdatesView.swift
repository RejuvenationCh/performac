// UpdatesView.swift — what is behind, and the command to fix it.
import SwiftUI
import AppKit

struct UpdatesView: View {
    var items: [OutdatedItem] = []
    var loading: Bool = false
    var metadataAge: TimeInterval? = nil
    var brewMissing: Bool = false
    var onAppear: () -> Void = {}
    var onRefresh: () -> Void = {}
    @State private var copied: String? = nil

    private var formulae: [OutdatedItem] { items.filter { $0.kind == .formula } }
    private var casks: [OutdatedItem] { items.filter { $0.kind == .cask } }

    private var ageText: String {
        guard let a = metadataAge else { return "unknown age" }
        let h = Int(a / 3600)
        return h < 1 ? "updated less than an hour ago" : "updated \(h)h ago"
    }

    var body: some View {
        Page(title: "Updates",
             subtitle: "Command-line tools and apps installed through Homebrew.",
             trailing: AnyView(
                HStack(spacing: PC.gutter) {
                    if loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text("Package list \(ageText)").font(.pcSmall).foregroundStyle(PC.meta)
                    Button("Check again", action: onRefresh).controlSize(.small).disabled(loading)
                })) {
            if brewMissing {
                empty("Homebrew is not installed",
                      "This view reads Homebrew's package list. Without it there is nothing to report.")
            } else if items.isEmpty && !loading {
                empty("Everything is current", "No Homebrew package is behind its latest version.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: PC.gutter) {
                        // The app trashes files because the Trash is an undo. An upgrade has
                        // none, and bumping ffmpeg under a video editor mid-project is not a
                        // decision to make on someone's behalf.
                        HStack(alignment: .top, spacing: PC.s2) {
                            Image(systemName: "terminal").foregroundStyle(PC.meta)
                            Text("Performac does not run upgrades. A trashed file can be put back; an upgraded package cannot, and a version bump can change how a tool behaves mid-project. Copy a command and run it when it suits you.")
                                .font(.pcSmall).foregroundStyle(PC.ink2)
                            Spacer()
                        }
                        .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                        if !casks.isEmpty { section("Apps", casks) }
                        if !formulae.isEmpty { section("Command-line tools", formulae) }

                        HStack {
                            Spacer()
                            Button("Copy command for all \(items.count)") {
                                copy("brew upgrade" + (casks.isEmpty ? "" : " && brew upgrade --cask --greedy"))
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
                }
            }
        }
        .onAppear(perform: onAppear)
    }

    @ViewBuilder private func section(_ title: String, _ rows: [OutdatedItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(text: "\(title) (\(rows.count))")
                Spacer()
            }
            .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2)
            .pcHairline(.bottom)
            ForEach(rows) { item in
                HStack(spacing: PC.gutter) {
                    Text(item.name).font(.pcBody).foregroundStyle(PC.ink).lineLimit(1)
                    Spacer(minLength: PC.s2)
                    Text(item.installed).font(.pcNum).foregroundStyle(PC.meta)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(PC.meta)
                    Text(item.available).font(.pcNum).foregroundStyle(PC.ink)
                        .frame(minWidth: 74, alignment: .leading)
                    Button(copied == item.id ? "Copied" : "Copy") { copy(item.upgradeCommand, id: item.id) }
                        .controlSize(.small).frame(width: 66)
                }
                .padding(.horizontal, PC.gutter).padding(.vertical, 5)
                .help(item.upgradeCommand)
                Divider().overlay(PC.hairline)
            }
        }
        .pcCard()
    }

    @ViewBuilder private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: PC.s2) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(PC.green)
            Text(title).font(.pcHeadline).foregroundStyle(PC.ink)
            Text(detail).font(.pcBody).foregroundStyle(PC.ink2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ s: String, id: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        if let id {
            copied = id
            Task { try? await Task.sleep(for: .seconds(2)); if copied == id { copied = nil } }
        }
    }
}
