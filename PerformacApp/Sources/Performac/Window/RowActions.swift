// RowActions.swift — the right-click menu for disk browser rows, and the two panels it opens.
//
// The Clean view trashes from a reviewed allowlist. This is different: every row here can be
// the user's actual work, so the trash action is per item, always confirmed, shows the full
// path, and still goes through Trash.moveToTrash so it stays recoverable.
import SwiftUI
import AppKit

struct RowInfo: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var bytes: Int64
    var items: Int
    var isFolder: Bool
}

/// Attach to any row. `onOpen` is nil for files, which cannot be descended into.
struct RowContextMenu: ViewModifier {
    let info: RowInfo
    var onOpen: (() -> Void)?
    @Binding var infoTarget: RowInfo?
    @Binding var trashTarget: RowInfo?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let onOpen, info.isFolder {
                Button("Open", action: onOpen)
                Divider()
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(info.path, inFileViewerRootedAtPath: "")
            }
            Button("Get Info") { infoTarget = info }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.path, forType: .string)
            }
            Divider()
            Button("Move to Trash…") { trashTarget = info }
        }
    }
}

extension View {
    func rowActions(_ info: RowInfo, onOpen: (() -> Void)? = nil,
                    infoTarget: Binding<RowInfo?>, trashTarget: Binding<RowInfo?>) -> some View {
        modifier(RowContextMenu(info: info, onOpen: onOpen,
                                infoTarget: infoTarget, trashTarget: trashTarget))
    }
}

/// Properties, read from the filesystem when opened rather than from the scan, so it is
/// current even when the listing behind it is a stale snapshot.
struct RowInfoSheet: View {
    let info: RowInfo
    var onClose: () -> Void
    @State private var modified: Date?
    @State private var created: Date?
    @State private var kind: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PC.gutter) {
                Image(systemName: info.isFolder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 26)).foregroundStyle(PC.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.pcHeadline).foregroundStyle(PC.ink).lineLimit(2)
                    Text(kind).font(.pcSmall).foregroundStyle(PC.meta)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, PC.gutter)

            VStack(spacing: 0) {
                InfoRow("Size", Fmt.bytes(info.bytes))
                if info.items > 0 { InfoRow("Items", Fmt.count(info.items)) }
                InfoRow("Modified", modified.map(Self.stamp) ?? "unknown")
                InfoRow("Created", created.map(Self.stamp) ?? "unknown")
                InfoRow("Where", (info.path as NSString).deletingLastPathComponent
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
            .padding(.horizontal, 20)

            HStack(spacing: PC.s2) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(info.path, inFileViewerRootedAtPath: "")
                }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 420)
        .pcGlassPanel(PC.rXl)
        .onAppear(perform: load)
    }

    private func load() {
        let a = try? FileManager.default.attributesOfItem(atPath: info.path)
        modified = a?[.modificationDate] as? Date
        created = a?[.creationDate] as? Date
        if info.isFolder { kind = "Folder" }
        else {
            let ext = (info.path as NSString).pathExtension
            kind = ext.isEmpty ? "Document" : ext.uppercased() + " file"
        }
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM yyyy 'at' HH:mm"
        return f.string(from: d)
    }
}

private struct InfoRow: View {
    let label: String, value: String
    init(_ l: String, _ v: String) { label = l; value = v }
    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(.pcSmall).foregroundStyle(PC.meta).frame(width: 74, alignment: .leading)
            Text(value).font(.pcBody).foregroundStyle(PC.ink)
                .textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(PC.hairline).frame(height: 1) }
    }
}

/// One item, full path, explicit. Nothing here is on an allowlist, so the confirmation
/// carries more weight than the Clean view's.
struct RowTrashSheet: View {
    let info: RowInfo
    var onCancel: () -> Void
    var onConfirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move \"\(info.name)\" to the Trash?")
                .font(.pcHeadline).foregroundStyle(PC.ink).lineLimit(2)
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, PC.s2)

            VStack(alignment: .leading, spacing: 3) {
                Text(info.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.pcSmall).foregroundStyle(PC.ink2).textSelection(.enabled)
                Text(info.items > 0
                     ? "\(Fmt.bytes(info.bytes)) · \(Fmt.count(info.items)) items"
                     : Fmt.bytes(info.bytes))
                    .font(.pcNum).foregroundStyle(PC.ink)
            }
            .padding(.horizontal, 22).padding(.bottom, PC.gutter)

            HStack(alignment: .top, spacing: PC.gutter) {
                Image(systemName: "trash.fill").font(.system(size: 14)).foregroundStyle(PC.meta)
                Text(info.isFolder
                     ? "The whole folder and everything inside it goes to the Trash. You can put it back from Finder until you empty it."
                     : "It goes to the Trash, not deleted. You can put it back from Finder until you empty it.")
                    .font(.pcSmall).foregroundStyle(PC.ink2).lineSpacing(2)
            }
            .padding(.horizontal, 22).padding(.vertical, PC.gutter)
            .background(PC.fill1)

            HStack(spacing: PC.s2 + 2) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: onConfirm).buttonStyle(.borderedProminent)
            }
            .padding(22)
        }
        .frame(width: 480)
        .pcGlassPanel(PC.rXl)
    }
}
