// Updates.swift: asks GitHub whether a newer release exists and installs it.
//
// No Developer ID, so the trust comes from two things instead. The zip is downloaded by the
// app itself, so macOS never quarantines it and Gatekeeper never sees it. And it is installed
// only if it satisfies this running copy's own designated requirement: the same bundle id
// signed by the same certificate. That also keeps Full Disk Access, which macOS ties to that
// requirement. A copy built from source with ad hoc signing cannot match a release, so it
// falls back to offering the release page.
import Foundation
import Security
import AppKit

struct Release: Decodable, Identifiable, Equatable, Sendable {
    let tag_name: String
    let body: String?
    let html_url: String
    var assets: [Asset]? = nil
    struct Asset: Decodable, Equatable, Sendable { let name: String; let browser_download_url: String }
    var id: String { tag_name }
    var version: String { Updates.parse(tag_name).text }
}

enum Updates {
    static let latestURL = URL(string: "https://api.github.com/repos/RejuvenationCh/performac/releases/latest")!
    static let lastCheckKey = "updates.lastCheck"
    /// The asset Scripts/release.sh attaches and install.sh downloads. Fixed, so the
    /// releases/latest/download/Performac.zip URL always resolves.
    static let assetName = "Performac.zip"

    /// The bundle's version. nil under `swift run`, which has no Info.plist: there is nothing
    /// honest to compare against, so the automatic check stays off for a development build.
    static var running: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    enum Latest: Sendable { case release(Release), noneYet, failed }

    static func fetchLatest() async -> Latest {
        var req = URLRequest(url: latestURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failed }
        if http.statusCode == 404 { return .noneYet }   // the repo exists but has no release
        guard http.statusCode == 200,
              let r = try? JSONDecoder().decode(Release.self, from: data) else { return .failed }
        return .release(r)
    }

    /// Semver order, not string order: "0.10.0" is newer than "0.9.0", and "1.0.0" is newer
    /// than "1.0.0-rc.1". A tag that does not parse reads as 0 and is never offered.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = parse(tag), b = parse(current)
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x > y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil), (.some, nil): return false
        case (nil, .some): return true
        // ponytail: numeric-aware string compare, not the full per-identifier semver rule;
        // right for rc.1 < rc.2 < rc.10 and alpha < beta < rc, which is all this repo tags.
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedDescending
        }
    }

    /// Download, unpack, verify, swap. Any failure returns false and leaves the installed app
    /// exactly as it was.
    static func install(_ r: Release, over app: URL, running: String) async -> Bool {
        let fm = FileManager.default
        guard app.pathExtension == "app",
              fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
              let asset = r.assets?.first(where: { $0.name == assetName }),
              let url = URL(string: asset.browser_download_url),
              let (zip, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              // Same volume as the app, so the final move is a rename. The OS clears it.
              let stage = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: app, create: true),
              run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path]) == 0 else { return false }
        let fresh = stage.appendingPathComponent("Performac.app")
        guard signedLikeThisApp(fresh),
              // A release tagged without bumping VERSION would otherwise reinstall every day.
              let v = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String,
              isNewer(v, than: running) else { return false }

        // The old copy goes to the Trash through the app's one deletion path, so a bad
        // release is one Put Back away from undone.
        let old = app.path
        guard let out = Trash.moveToTrash([old], allowed: [old], db: nil,
                                          now: Int64(Date().timeIntervalSince1970 * 1000)).first,
              out.ok else { return false }
        do {
            try fm.moveItem(at: fresh, to: app)
        } catch {
            if let back = out.trashedTo { try? fm.moveItem(atPath: back, toPath: old) }
            return false
        }
        return true
    }

    /// True when `url` satisfies the running app's designated requirement.
    static func signedLikeThisApp(_ url: URL) -> Bool {
        var me: SecCode?, meStatic: SecStaticCode?, req: SecRequirement?, other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(url as CFURL, [], &other) == errSecSuccess, let other
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(other, flags, req) == errSecSuccess
    }

    private static func run(_ bin: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func parse(_ s: String) -> (core: [Int], pre: String?, text: String) {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        let text = v
        v = String(v.split(separator: "+", maxSplits: 1).first ?? "")   // build metadata never orders
        let parts = v.split(separator: "-", maxSplits: 1)
        let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (core, parts.count > 1 ? String(parts[1]) : nil, text)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Captured at launch: once an update has swapped the bundle, this path holds the new one.
    let app = Bundle.main.bundleURL

    /// A newer release; drives the sheet in MainWindow.
    @Published var offered: Release?
    /// True when `offered` is already installed and only needs a restart. False means it
    /// could not be installed here, so the sheet offers the release page instead.
    @Published var ready = false
    /// The result of the last manual check, for Settings. Automatic checks never write it.
    @Published var status = ""
    @Published var checking = false

    var lastCheck: Date? {
        let t = UserDefaults.standard.double(forKey: Updates.lastCheckKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// At most once a day, and silent on any failure: offline or rate limited leaves the UI
    /// exactly as it was, and the next attempt comes round on its own.
    func checkIfDue(now: Date = Date()) async {
        guard Updates.running != nil else { return }
        if let last = lastCheck, now.timeIntervalSince(last) < 86_400 { return }
        switch await Updates.fetchLatest() {
        case .failed: return
        case .noneYet: record(now)
        case .release(let r):
            record(now)
            await take(r)
        }
    }

    /// Asked for, so it reports: an explicit check that says nothing reads as broken.
    func checkNow() async {
        checking = true
        defer { checking = false }
        switch await Updates.fetchLatest() {
        case .failed:
            status = "Could not reach GitHub. Try again later."
        case .noneYet:
            record(Date())
            status = "No releases have been published yet."
        case .release(let r):
            record(Date())
            guard let current = Updates.running else {
                status = "The latest release is \(r.version). This is a development build, so there is nothing to compare it with."
                return
            }
            guard Updates.isNewer(r.tag_name, than: current) else {
                status = "Up to date. The latest release is \(r.version)."
                return
            }
            status = "Installing \(r.version)."
            await take(r)
            status = ready ? "Version \(r.version) is installed. Restart Performac to use it."
                           : "Version \(r.version) is available but could not be installed automatically."
        }
    }

    /// Install `r` if it is newer, then say so once. The version is remembered so a daily
    /// check before the restart does not download it again.
    private func take(_ r: Release) async {
        guard let current = Updates.running, Updates.isNewer(r.tag_name, than: current),
              installed != r.version else { return }
        let ok = await Updates.install(r, over: app, running: current)
        if ok { installed = r.version }
        ready = ok
        offered = r
    }
    private var installed: String?

    /// Relaunch into the new bundle. A detached shell waits for this process to exit, then
    /// opens the app again; `open` while this copy is alive would only reactivate it.
    func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        guard (try? p.run()) != nil else { return }
        // AppKit refuses to quit while a sheet is attached, and this is called from one: the
        // shell above then waits forever on a process that never exits.
        offered = nil
        for w in NSApp.windows { if let s = w.attachedSheet { w.endSheet(s) } }
        NSApp.terminate(nil)
    }

    private func record(_ d: Date) {
        UserDefaults.standard.set(d.timeIntervalSince1970, forKey: Updates.lastCheckKey)
        objectWillChange.send()
    }
}
