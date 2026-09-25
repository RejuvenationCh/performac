// Core/LiveDeps.swift: the real SamplerDeps: Process-based execFile/spawn (argv
// arrays, never a shell string, /usr/bin/env only resolves the binary name),
// statfs(2), /Volumes listing, realpath(3). Used by the app; the checks keep using
// fakes so they never touch real binaries.
import Foundation
import UserNotifications

/// Free-function wrapper so the protocol method `statfs` doesn't shadow the C import.
private func sysStatfs(_ path: String, _ s: UnsafeMutablePointer<statfs>) -> Int32 {
    statfs(path, s)
}

final class LiveDeps: SamplerDeps {
    func execFile(_ bin: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")   // resolve `bin` via PATH
            p.arguments = [bin] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    struct NotPosted: Error {}

    /// Posts as Performac. Throws when it could not, so maybeNotify keeps the cooldown open:
    /// unbundled (`swift run`, where UserNotifications aborts the process), or not allowed.
    func notify(_ title: String, _ subtitle: String?, _ body: String) async throws {
        guard Bundle.main.bundleIdentifier != nil else { throw NotPosted() }
        let center = UNUserNotificationCenter.current()
        // Asks once; after that it answers from the stored choice without a prompt.
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw NotPosted() }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func spawn(_ bin: String, _ args: [String]) -> StreamChild {
        ProcessStreamChild(bin: bin, args: args)
    }

    func statfs(_ path: String) async throws -> StatFs {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<StatFs, Error>) in
            DispatchQueue.global(qos: .utility).async {
                var s = Darwin.statfs()
                guard sysStatfs(path, &s) == 0 else {
                    cont.resume(throwing: NSError(domain: "statfs", code: 1))
                    return
                }
                cont.resume(returning: StatFs(bsize: Int64(s.f_bsize), blocks: Int64(s.f_blocks), bavail: Int64(s.f_bavail)))
            }
        }
    }

    func listVolumes() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
    }

    func realpathSync(_ p: String) throws -> String {
        guard let c = realpath(p, nil) else { throw NSError(domain: "realpath", code: 1) }
        defer { free(c) }
        return String(cString: c)
    }

    func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// A spawned stream child: Process + Pipe, lines split out of the buffer, exit reported.
final class ProcessStreamChild: StreamChild, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
    var onExit: (@Sendable () -> Void)?

    private let process: Process
    private let source: DispatchSourceRead
    private let file: FileHandle

    init(bin: String, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [bin] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        process = p
        file = pipe.fileHandleForReading
        let src = DispatchSource.makeReadSource(fileDescriptor: file.fileDescriptor, queue: .global(qos: .utility))
        source = src
        var buf = Data()
        src.setEventHandler { [file, weak self] in
            let data = file.availableData
            if data.isEmpty {
                self?.source.cancel()
                return
            }
            buf.append(data)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = String(data: buf[..<nl], encoding: .utf8) ?? ""
                buf.removeSubrange(...nl)
                self?.onLine?(line)
            }
        }
        src.setCancelHandler { [weak self] in
            self?.onExit?()
        }
        p.terminationHandler = { [weak self] _ in
            self?.file.closeFile()
            self?.source.cancel()
        }
        do {
            try p.run()
            src.resume()
        } catch {
            source.cancel()
        }
    }

    func kill() {
        process.terminate()
        source.cancel()
    }
}
