// SettingsView.swift — macOS System Settings idiom: grouped rows, label left, control right.
//
// Every control on this screen now does something. It used to carry five that did not: a
// Launch-at-login toggle held in local @State and never persisted, a Show-in-menu-bar toggle
// the same, a Reveal button wired to `{}`, a "+" wired to `{}`, and skip-folder chips whose
// remove affordance was an Image rather than a Button — showing two hardcoded paths that did
// not even match the scanner's real defaults.
import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    let config: Config
    var fdaGranted: Bool = false
    let databaseSummary: String
    var ignored: [String] = []
    var onUnignore: (String) -> Void = { _ in }
    var onSave: (String, JSONValue) -> Void = { _, _ in }

    @State private var appearance = Appearance.current
    /// Read from the system, not remembered locally — the previous local-only Bool meant the
    /// toggle reported whatever it was last clicked to, never what macOS actually does.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String? = nil

    // Edit-in-progress values for the numeric fields. Seeded from config and resynced below
    // whenever the stored value changes, so this screen cannot drift from the config it edits.
    @State private var staleDays: Int
    @State private var weeksLeft: Int
    @State private var cycles: Int
    @State private var cpuMinutes: Int
    @State private var dupMinMB: Int
    @State private var historyDays: Int

    init(config: Config = .defaults, fdaGranted: Bool = false,
         databaseSummary: String = "not measured",
         ignored: [String] = [],
         onUnignore: @escaping (String) -> Void = { _ in },
         onSave: @escaping (String, JSONValue) -> Void = { _, _ in }) {
        self.config = config
        self.fdaGranted = fdaGranted
        self.databaseSummary = databaseSummary
        self.ignored = ignored
        self.onUnignore = onUnignore
        self.onSave = onSave
        _staleDays = State(initialValue: config.cacheRules.staleDays)
        _weeksLeft = State(initialValue: config.storage.warnWeeksLeft)
        _cycles = State(initialValue: config.drive.cycles24h)
        _cpuMinutes = State(initialValue: config.hog.minMinutes)
        _dupMinMB = State(initialValue: Int(config.dup.minMb))
        _historyDays = State(initialValue: config.retentionDays.cache)
    }

    /// The scanner's actual prune list, read from the scanner rather than retyped.
    private var skipPaths: [String] { DiskScanner().skipPaths }

    var body: some View {
        Page(title: "Settings") {
            ScrollView {
                VStack(alignment: .leading, spacing: PC.stack) {
                    SettingsGroup(header: "Permissions") {
                        Row("Full Disk Access") {
                            HStack(spacing: PC.s2) {
                                Pill(text: fdaGranted ? "Granted" : "Not granted",
                                     tint: fdaGranted ? PC.green : PC.amber,
                                     soft: fdaGranted ? PC.greenSoft : PC.amberSoft)
                                Button("Open System Settings") {
                                    // Deep-links straight to Privacy → Full Disk Access.
                                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                        NSWorkspace.shared.open(u)
                                    }
                                }.controlSize(.small)
                            }
                        }
                        // No invented figures. This used to read "can only measure 736 GB of
                        // your 889 GB" — numbers from one scan of one machine, printed as if
                        // they were live, against the app's own rule about evidence.
                        Note("Without it, folders Performac cannot read are skipped silently, so scan totals come out lower than the disk really is.")
                    }

                    SettingsGroup(header: "General") {
                        Row("Appearance") {
                            Picker("", selection: Binding(get: { appearance },
                                                          set: { appearance = $0; Appearance.apply($0) })) {
                                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 190)
                        }
                        Divider().overlay(PC.hairline)
                        Row("Launch at login") {
                            Toggle("", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                                .labelsHidden()
                        }
                        if let launchError {
                            Note(launchError)
                        }
                    }

                    SettingsGroup(header: "Thresholds") {
                        Stepper2("Warn when a cache is unused for", $staleDays, "days", 1...365)
                            .onChange(of: staleDays) { _, v in onSave("cacheRules", .object(["staleDays": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Stepper2("Warn when free space drops below", $weeksLeft, "weeks remaining", 1...52)
                            .onChange(of: weeksLeft) { _, v in onSave("storage", .object(["warnWeeksLeft": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Stepper2("Drive reconnect cycles before warning", $cycles, "", 1...50)
                            .onChange(of: cycles) { _, v in onSave("drive", .object(["cycles24h": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Stepper2("Sustained CPU warning after", $cpuMinutes, "minutes", 1...1440)
                            .onChange(of: cpuMinutes) { _, v in onSave("hog", .object(["minMinutes": .number(Double(v))])) }
                    }

                    SettingsGroup(header: "Ignored processes") {
                        if ignored.isEmpty {
                            Note("Nothing ignored. Use Ignore on a CPU or memory card to stop reporting a process.")
                        } else {
                            ForEach(Array(ignored.enumerated()), id: \.element) { i, name in
                                if i > 0 { Divider().overlay(PC.hairline) }
                                Row(name) {
                                    Button("Stop ignoring") { onUnignore(name) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }

                    SettingsGroup(header: "Scanning") {
                        Stepper2("Duplicate scan minimum file size", $dupMinMB, "MB", 1...10_240)
                            .onChange(of: dupMinMB) { _, v in onSave("dup", .object(["minMb": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Row("Folders always skipped") {
                            HStack(spacing: PC.s1) {
                                ForEach(skipPaths, id: \.self) { Chip($0) }
                            }
                        }
                        Note("Fixed: these are pruned from every scan. /Volumes is skipped because each drive is scanned as its own target.")
                    }

                    SettingsGroup(header: "Data") {
                        Stepper2("History kept", $historyDays, "days", 7...3650)
                            .onChange(of: historyDays) { _, v in onSave("retentionDays", .object(["cache": .number(Double(v)), "disk": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Row("Database") {
                            HStack(spacing: PC.s2) {
                                Text(databaseSummary).font(.pcNum).foregroundStyle(PC.meta)
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.selectFile(EngineStore.databasePath,
                                                                  inFileViewerRootedAtPath: "")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        // Resync the editable copies if the stored config changes from anywhere else.
        .onChange(of: config.cacheRules.staleDays) { _, v in staleDays = v }
        .onChange(of: config.storage.warnWeeksLeft) { _, v in weeksLeft = v }
        .onChange(of: config.drive.cycles24h) { _, v in cycles = v }
        .onChange(of: config.hog.minMinutes) { _, v in cpuMinutes = v }
        .onChange(of: config.dup.minMb) { _, v in dupMinMB = Int(v) }
        .onChange(of: config.retentionDays.cache) { _, v in historyDays = v }
    }

    /// Register or unregister the login item, then report what macOS actually did rather than
    /// leaving the switch showing an intent that never took effect.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "macOS refused the change: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct SettingsGroup<C: View>: View {
    let header: String
    @ViewBuilder var content: C
    init(header: String, @ViewBuilder content: () -> C) { self.header = header; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: PC.s2) {
            SectionHeader(text: header)
            VStack(spacing: 0) { content }.pcCard()
        }
    }
}

private struct Row<C: View>: View {
    let label: String
    @ViewBuilder var control: C
    init(_ label: String, @ViewBuilder control: () -> C) { self.label = label; self.control = control() }
    var body: some View {
        HStack {
            Text(label).font(.pcBody).foregroundStyle(PC.ink)
            Spacer()
            control
        }
        .padding(.horizontal, PC.gutter).padding(.vertical, PC.s2 + 1)
    }
}

/// A bounded number. The range is not decoration: these write straight through to config, and
/// the fields used to accept 0 and negatives, which sail past validateSetting's `> 0` check
/// only because the clamp never happened on the way in.
private struct Stepper2: View {
    let label: String
    @Binding var value: Int
    let unit: String
    let range: ClosedRange<Int>

    init(_ l: String, _ v: Binding<Int>, _ u: String, _ range: ClosedRange<Int>) {
        label = l; _value = v; unit = u; self.range = range
    }

    var body: some View {
        Row(label) {
            HStack(spacing: PC.s1) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                    .font(.pcNum).multilineTextAlignment(.trailing)
                    .onSubmit { clamp() }
                Stepper("", value: $value, in: range).labelsHidden()
                if !unit.isEmpty {
                    Text(unit).font(.pcSmall).foregroundStyle(PC.meta).frame(width: 116, alignment: .leading)
                }
            }
            .help("\(range.lowerBound)–\(range.upperBound)")
        }
        .onChange(of: value) { clamp() }
    }

    private func clamp() {
        let c = min(max(value, range.lowerBound), range.upperBound)
        if c != value { value = c }
    }
}

private struct Note: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.pcSmall).foregroundStyle(PC.meta).lineSpacing(2)
            .padding(.horizontal, PC.gutter).padding(.bottom, PC.s2 + 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Read-only. It carried an xmark that looked like a remove button and was a plain Image.
private struct Chip: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.pcSmall).foregroundStyle(PC.ink2)
            .padding(.horizontal, PC.s2).padding(.vertical, 3)
            .background(PC.chip, in: Capsule())
    }
}
