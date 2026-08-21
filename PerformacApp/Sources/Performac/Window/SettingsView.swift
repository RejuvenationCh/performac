// SettingsView.swift — macOS System Settings idiom: grouped rows, label left, control right.
import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var launchAtLogin = false
    @State private var showInMenuBar = true
    @State private var menuBarShows: String
    var onMenuBar: (String) -> Void = { _ in }
    @State private var staleDays: Int
    @State private var weeksLeft: Int
    @State private var cycles: Int
    @State private var cpuMinutes: Int
    @State private var dupMinMB: Int
    @State private var historyDays: Int
    var fdaGranted: Bool = false
    var onSave: (String, JSONValue) -> Void = { _, _ in }

    init(config: Config = .defaults, fdaGranted: Bool = false,
         menuBarMode: String = "metrics",
         onMenuBar: @escaping (String) -> Void = { _ in },
         onSave: @escaping (String, JSONValue) -> Void = { _, _ in }) {
        _menuBarShows = State(initialValue: menuBarMode)
        self.onMenuBar = onMenuBar
        _staleDays = State(initialValue: config.cacheRules.staleDays)
        _weeksLeft = State(initialValue: config.storage.warnWeeksLeft)
        _cycles = State(initialValue: config.drive.cycles24h)
        _cpuMinutes = State(initialValue: config.hog.minMinutes)
        _dupMinMB = State(initialValue: Int(config.dup.minMb))
        _historyDays = State(initialValue: config.retentionDays.cache)
        self.fdaGranted = fdaGranted
        self.onSave = onSave
    }

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
                        Note("Without it, Performac can only measure 736 GB of your 889 GB — folders it cannot read are silently missing from totals.")
                    }
                    SettingsGroup(header: "General") {
                        Row("Launch at login") { Toggle("", isOn: $launchAtLogin).labelsHidden() }
                        Divider().overlay(PC.hairline)
                        Row("Show in menu bar") { Toggle("", isOn: $showInMenuBar).labelsHidden() }
                        Divider().overlay(PC.hairline)
                        Row("Menu bar shows") {
                            Picker("", selection: Binding(get: { menuBarShows },
                                                          set: { menuBarShows = $0; onMenuBar($0) })) {
                                Text("Live CPU and memory").tag("metrics")
                                Text("Worst finding").tag("finding")
                                Text("Free space").tag("free")
                            }.labelsHidden().frame(width: 180)
                        }
                    }
                    SettingsGroup(header: "Thresholds") {
                        Stepper2("Warn when a cache is unused for", $staleDays, "days")
                            .onChange(of: staleDays) { v in onSave("cacheRules", .object(["staleDays": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Stepper2("Warn when free space drops below", $weeksLeft, "weeks remaining")
                            .onChange(of: weeksLeft) { v in onSave("storage", .object(["warnWeeksLeft": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Stepper2("Drive reconnect cycles before warning", $cycles, "")
                            .onChange(of: cycles) { v in onSave("drive", .object(["cycles24h": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Stepper2("Sustained CPU warning after", $cpuMinutes, "minutes")
                            .onChange(of: cpuMinutes) { v in onSave("hog", .object(["minMinutes": .number(Double(v))])) }
                    }
                    SettingsGroup(header: "Scanning") {
                        Stepper2("Duplicate scan minimum file size", $dupMinMB, "MB")
                            .onChange(of: dupMinMB) { v in onSave("dup", .object(["minMb": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Row("Folders to skip") {
                            HStack(spacing: PC.s1) {
                                Chip("/System"); Chip("/Volumes/Time Machine")
                                Button { } label: { Image(systemName: "plus") }
                                    .buttonStyle(.plain).foregroundStyle(PC.meta)
                            }
                        }
                    }
                    SettingsGroup(header: "Data") {
                        Stepper2("History kept", $historyDays, "days")
                            .onChange(of: historyDays) { v in onSave("retentionDays", .object(["cache": .number(Double(v)), "disk": .number(Double(v))])) }
                        Divider().overlay(PC.hairline)
                        Row("Database") {
                            HStack(spacing: PC.s2) {
                                Text("6,820 samples · 14 MB").font(.pcNum).foregroundStyle(PC.meta)
                                Button("Reveal in Finder") {}.controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
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

private struct Stepper2: View {
    let label: String; @Binding var value: Int; let unit: String
    init(_ l: String, _ v: Binding<Int>, _ u: String) { label = l; _value = v; unit = u }
    var body: some View {
        Row(label) {
            HStack(spacing: PC.s1) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                    .font(.pcNum).multilineTextAlignment(.trailing)
                Stepper("", value: $value).labelsHidden()
                if !unit.isEmpty {
                    Text(unit).font(.pcSmall).foregroundStyle(PC.meta).frame(width: 116, alignment: .leading)
                }
            }
        }
    }
}

private struct Note: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.pcSmall).foregroundStyle(PC.meta).lineSpacing(2)
            .padding(.horizontal, PC.gutter).padding(.bottom, PC.s2 + 2)
    }
}

private struct Chip: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(.pcSmall).foregroundStyle(PC.ink2)
            Image(systemName: "xmark").font(.system(size: 7)).foregroundStyle(PC.meta)
        }
        .padding(.horizontal, PC.s2).padding(.vertical, 3)
        .background(PC.chip, in: Capsule())
    }
}
