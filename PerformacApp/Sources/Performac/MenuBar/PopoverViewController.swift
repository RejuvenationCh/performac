// MenuBar/PopoverViewController.swift — Phase 0 placeholder popover. The Scan button
// doubles as the Phase 2 streaming demo: results populate progressively, and the
// status-item title carries the live total while the scan runs.
import AppKit

@MainActor
final class PopoverViewController: NSViewController {
    /// Lets the status item title mirror live scan progress.
    var onStatusTitle: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "Performac v2 — Phase 0 shell")
    private let progress = NSTextField(labelWithString: "No scan yet")
    private var scanTask: Task<Void, Never>?

    override func loadView() {
        let scanButton = NSButton(title: "Scan home folder", target: self, action: #selector(startScan))
        let stack = NSStackView(views: [label, progress, scanButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 280, height: 130)
    }

    @objc private func startScan() {
        scanTask?.cancel()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let formatter = ByteCountFormatter()
        scanTask = Task {
            for await event in DiskScanner().scan(home) {
                guard !Task.isCancelled else { return }
                switch event {
                case .progress(let s):
                    progress.stringValue =
                        "\(s.filesScanned.formatted()) files · \(formatter.string(fromByteCount: s.bytes))"
                    onStatusTitle?(formatter.string(fromByteCount: s.bytes))
                case .finished(let sum):
                    progress.stringValue =
                        "Done in \(Int(sum.elapsed))s: \(sum.files.formatted()) files · \(formatter.string(fromByteCount: sum.bytes))"
                    onStatusTitle?("P")
                }
            }
        }
    }
}
