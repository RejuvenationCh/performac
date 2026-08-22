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
    var upgrading: Bool = false
    var progress: String = ""
    var log: [String] = []
    var summary: String? = nil
    var onSelect: (String, Bool) -> Void = { _, _ in }
    var onSelectAll: (Bool) -> Void = { _ in }
    var onUpgrade: () -> Void = {}
    var state: [String: UpgradeOutcome] = [:]
    var activeID: String? = nil
    @State private var copied: String? = nil
    @State private var confirming = false

    private var selected: [OutdatedItem] { items.filter(\.selected) }
    private var majors: [OutdatedItem] { selected.filter(\.isMajorJump) }
    /// Packages the last run could not finish without root. The command is the only thing
    /// Performac can offer here — it does not ask for passwords.
    private var lockedOut: [OutdatedItem] { items.filter { state[$0.id] == .needsPassword } }
    /// A live count during the run, so a long batch shows progress in the summary slot too.
    private var runningTally: String? {
        guard upgrading, !state.isEmpty else { return nil }
        let done = state.values.filter { $0 == .ok }.count
        let stuck = state.count - done
        return stuck == 0 ? "\(done) done"
                          : "\(done) done, \(stuck) need attention"
    }

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
                        // An upgrade cannot be undone, so the caution stays visible rather
                        // than living in a confirmation the user clicks past.
                        HStack(alignment: .top, spacing: PC.s2) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(PC.amber)
                            Text("Upgrades cannot be undone. Anything marked as a major version can change how a tool behaves — worth leaving unticked while a project is open.")
                                .font(.pcSmall).foregroundStyle(PC.ink2)
                            Spacer()
                        }
                        .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                        if upgrading || !log.isEmpty { logPane }

                        if !casks.isEmpty { section("Apps", casks) }
                        if !formulae.isEmpty { section("Command-line tools", formulae) }

                        HStack(spacing: PC.gutter) {
                            Button(selected.count == items.count ? "Deselect all" : "Select all") {
                                onSelectAll(selected.count != items.count)
                            }
                            .controlSize(.small).disabled(upgrading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(upgrading ? "Upgrading \(progress)…"
                                               : "\(selected.count) of \(items.count) selected")
                                    .font(.pcTitle).foregroundStyle(PC.ink)
                                Text(runningTally ?? summary ?? (majors.isEmpty
                                     ? "Runs brew upgrade for each, one at a time."
                                     : "\(majors.count) of these are major version changes."))
                                    .font(.pcSmall).foregroundStyle(majors.isEmpty ? PC.meta : PC.amber)
                            }
                            Spacer()
                            Button(lockedOut.isEmpty ? "Copy commands" : "Copy \(lockedOut.count) for Terminal") {
                                let cmds = lockedOut.isEmpty ? selected : lockedOut
                                copy(cmds.map(\.upgradeCommand).joined(separator: "\n"))
                            }
                            .controlSize(.small)
                            .disabled((selected.isEmpty && lockedOut.isEmpty) || upgrading)
                            Button(upgrading ? "Upgrading…" : "Update \(selected.count)") { confirming = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(selected.isEmpty || upgrading)
                        }
                        .padding(PC.gutter).pcCard()
                    }
                    .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
                }
            }
        }
        .onAppear(perform: onAppear)
        .sheet(isPresented: $confirming) {
            UpgradeSheet(items: selected, majors: majors,
                         onCancel: { confirming = false },
                         onConfirm: { confirming = false; onUpgrade() })
        }
    }

    /// brew's own output, so a failure is visible rather than summarised away.
    @ViewBuilder private var logPane: some View {
        VStack(alignment: .leading, spacing: PC.s1) {
            HStack(spacing: PC.s2) {
                if upgrading { ProgressView().controlSize(.small).scaleEffect(0.6) }
                SectionHeader(text: upgrading ? "Running" : "Last run")
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("$") ? PC.accent : PC.ink2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                }
                .frame(height: 150)
                .onChange(of: log.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()
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
                    status(item)
                    Text(item.name).font(.pcBody).foregroundStyle(PC.ink).lineLimit(1)
                    if item.isMajorJump {
                        Pill(text: "major version", tint: PC.amber, soft: PC.amberSoft)
                    }
                    Spacer(minLength: PC.s2)
                    Text(item.installed).font(.pcNum).foregroundStyle(PC.meta)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(PC.meta)
                    Text(item.available).font(.pcNum).foregroundStyle(PC.ink)
                        .frame(minWidth: 74, alignment: .leading)
                    Button(copied == item.id ? "Copied" : "Copy") { copy(item.upgradeCommand, id: item.id) }
                        .controlSize(.small).frame(width: 66)
                        .help(state[item.id] == .needsPassword
                              ? "Paste this into Terminal, where sudo can ask for your password"
                              : item.upgradeCommand)
                }
                .padding(.horizontal, PC.gutter).padding(.vertical, 5)
                .help(item.upgradeCommand)
                Divider().overlay(PC.hairline)
            }
        }
        .pcCard()
    }

    /// The row's own answer to "what happened to me". While a run is going the checkbox has
    /// nothing left to decide, so the same 16pt slot carries the outcome instead.
    @ViewBuilder private func status(_ item: OutdatedItem) -> some View {
        let outcome = state[item.id]
        Group {
            if activeID == item.id {
                ProgressView().controlSize(.small).scaleEffect(0.55)
            } else if let outcome {
                switch outcome {
                case .ok:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PC.green)
                case .needsPassword:
                    Image(systemName: "lock.fill").foregroundStyle(PC.amber)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(PC.red)
                }
            } else {
                Toggle("", isOn: Binding(get: { item.selected },
                                         set: { onSelect(item.id, $0) }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(upgrading)
            }
        }
        .font(.system(size: 12))
        .frame(width: 16, alignment: .center)
        .help(outcome == .ok ? "Upgraded"
              : outcome == .needsPassword ? "Needs an admin password — run it in Terminal"
              : outcome == .failed ? "Homebrew could not upgrade this one" : "")
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

/// The confirmation. Unlike the trash sheets, this one cannot promise recoverability — so it
/// says the opposite plainly, and leads with the major-version changes rather than burying
/// them in a list of forty.
struct UpgradeSheet: View {
    let items: [OutdatedItem]
    let majors: [OutdatedItem]
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upgrade \(items.count) package\(items.count == 1 ? "" : "s")?")
                .font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, PC.s2)

            if !majors.isEmpty {
                VStack(alignment: .leading, spacing: PC.s1) {
                    HStack(spacing: PC.s2) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PC.amber)
                        Text("\(majors.count) major version change\(majors.count == 1 ? "" : "s")")
                            .font(.pcTitle).foregroundStyle(PC.ink)
                    }
                    ForEach(majors) { m in
                        Text("\(m.name)  \(m.installed) → \(m.available)")
                            .font(.pcNum).foregroundStyle(PC.ink2)
                    }
                    Text("A major version can change how a tool behaves. If a project depends on one of these, cancel and untick it.")
                        .font(.pcSmall).foregroundStyle(PC.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading)
                .background(PC.amberSoft)
                .padding(.horizontal, 22).padding(.bottom, PC.gutter)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { i in
                        Text(i.upgradeCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PC.ink2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
            }
            .frame(maxHeight: 150)

            HStack(alignment: .top, spacing: PC.gutter) {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(PC.meta)
                Text("This cannot be undone from Performac. Homebrew keeps the old version until you run brew cleanup, so a rollback means going back through Homebrew yourself.")
                    .font(.pcSmall).foregroundStyle(PC.ink2).lineSpacing(2)
            }
            .padding(.horizontal, 22).padding(.vertical, PC.stack)

            HStack(spacing: PC.s2 + 2) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Upgrade \(items.count)", action: onConfirm).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22).padding(.bottom, 20)
        }
        .frame(width: 520)
        .pcGlassPanel(PC.rXl)
    }
}
