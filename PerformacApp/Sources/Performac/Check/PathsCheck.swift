// Check/PathsCheck.swift: ports of v1 test/paths.test.js.
import Foundation

@MainActor
enum PathsCheck {
    static let HOME = "/Users/testuser"

    static func run(_ c: CheckSuite) async {
        let noInputs = CacheTargetsInputs()

        // resolve targets: config wiring → cache, gallery, proxy (optional)
        do {
            let cfg = "Site.1.FS.1.Root = \(HOME)/Movies\nRenderCaching.CacheDir = CacheClip"
            let targets = cacheTargets(Config.defaults, inputs: CacheTargetsInputs(home: HOME, resolveCfg: cfg))
            let byId = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
            c.eq("resolve-cache path", byId["resolve-cache"]?.path, "\(HOME)/Movies/CacheClip")
            c.eq("resolve-gallery path", byId["resolve-gallery"]?.path, "\(HOME)/Movies/.gallery")
            c.eq("resolve-proxy path", byId["resolve-proxy"]?.path, "\(HOME)/Movies/ProxyMedia")
            c.check("resolve-proxy optional", byId["resolve-proxy"]?.optional == true)
        }
        // resolve fallback when config unparsable
        do {
            let targets = cacheTargets(Config.defaults, inputs: CacheTargetsInputs(home: HOME, resolveCfg: "garbage"))
            c.eq("resolve fallback → ~/Movies/CacheClip",
                 targets.first { $0.id == "resolve-cache" }?.path, "\(HOME)/Movies/CacheClip")
        }
        // premiere: four Adobe/Common subdirs; side-by-side prefs → note
        do {
            let targets = cacheTargets(Config.defaults, inputs: CacheTargetsInputs(home: HOME, prefs: ""))
            let ids = targets.filter { $0.id.hasPrefix("premiere-") }.map { $0.id }.sorted()
            c.eq("premiere ids", ids, ["premiere-analyzer", "premiere-db", "premiere-media", "premiere-peaks"])
            c.eq("premiere-media path", targets.first { $0.id == "premiere-media" }?.path,
                 "\(HOME)/Library/Application Support/Adobe/Common/Media Cache Files")
            c.check("premiere-media no note by default", targets.first { $0.id == "premiere-media" }?.note == nil)
            let sb = cacheTargets(Config.defaults, inputs: CacheTargetsInputs(
                home: HOME,
                prefs: "<BE.Prefs.MediaCache.FilesSideBySide>true</BE.Prefs.MediaCache.FilesSideBySide>"))
            c.eq("premiere side-by-side note", sb.first { $0.id == "premiere-media" }?.note, "side-by-side")
        }
        // lightroom: sibling lrdata targets per catalog, deduped, default always included
        do {
            let lrcats = ["/Volumes/Photo/Catalog.lrcat", "\(HOME)/Documents/Old Catalog.lrcat", "/Volumes/Photo/Catalog.lrcat"]
            let targets = cacheTargets(Config.defaults, inputs: CacheTargetsInputs(home: HOME, lrcatPaths: lrcats))
            let lr = targets.filter { $0.id.hasPrefix("lr-") }
            let lrPaths = lr.map { $0.path }
            c.check("lightroom deduped", Set(lrPaths).count == lrPaths.count)
            c.check("lightroom catalog previews", lrPaths.contains("/Volumes/Photo/Catalog Previews.lrdata"))
            c.check("lightroom smart previews", lrPaths.contains("/Volumes/Photo/Catalog Smart Previews.lrdata"))
            c.check("lightroom old catalog", lrPaths.contains("\(HOME)/Documents/Old Catalog Previews.lrdata"))
            c.check("lightroom default present", lr.contains { $0.id == "lr-default" })
            c.eq("lightroom default path", lr.first { $0.id == "lr-default" }?.path, "\(HOME)/Pictures/Lightroom")
        }
        // default lightroom skipped when covered
        do {
            let targets = cacheTargets(Config.defaults, inputs: CacheTargetsInputs(
                home: HOME, lrcatPaths: ["\(HOME)/Pictures/Lightroom/Lightroom Catalog.lrcat"]))
            c.check("default lr target skipped when covered", !targets.contains { $0.id == "lr-default" })
        }
        // measure: size/newest mtime/count; symlinks skipped; missing dir → zeros
        do {
            let dir = NSTemporaryDirectory() + "performac-paths-\(UUID().uuidString)"
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // left for the system to purge: trashing fixtures would litter the user's Bin
            try! Data(count: 1024).write(to: URL(fileURLWithPath: dir + "/a.bin"))
            try! FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
            try! Data(count: 2048).write(to: URL(fileURLWithPath: dir + "/sub/b.bin"))
            try! FileManager.default.createSymbolicLink(atPath: dir + "/link.bin", withDestinationPath: dir + "/a.bin")
            let old = (Date().timeIntervalSince1970 - 10 * 86_400) * 1000
            try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: old / 1000)], ofItemAtPath: dir + "/a.bin")
            let m = measure(dir)
            c.eq("measure: fileCount", m.fileCount, 2)
            c.eq("measure: sizeMb", m.sizeMb, 3072.0 / 1_048_576)
            c.check("measure: newest is b.bin, not a.bin", Double(m.newestMtime ?? 0) > old + 8.0 * 86_400_000)
            let missing = measure(dir + "/nope")
            c.eq("measure: missing dir → zeros", missing, MeasureResult(sizeMb: 0, newestMtime: nil, fileCount: 0))
        }
        // generic registry: fixed entries + discovered per-bundle dirs, safety labels
        do {
            let targets = cacheTargets(Config.defaults, inputs: CacheTargetsInputs(
                home: HOME,
                cacheDirs: [.init(name: "BigBundle", sizeMb: 600, newestMtime: 1, fileCount: 2)]))
            for id in ["gen-xcode", "gen-deriveddata", "gen-npm", "gen-google", "gen-brave", "gen-zen"] {
                let t = targets.first { $0.id == id }
                c.check("generic \(id) present", t != nil)
                c.check("generic \(id) path", (t?.path.hasPrefix("\(HOME)/Library") ?? false) || (t?.path.hasPrefix("\(HOME)/.npm") ?? false), t?.path ?? "")
            }
            let byId = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
            c.eq("gen-xcode safety", byId["gen-xcode"]?.safety, "safe")
            c.eq("gen-google safety", byId["gen-google"]?.safety, "check-first")
            c.eq("gen-brave safety", byId["gen-brave"]?.safety, "check-first")
            c.eq("gen-zen safety", byId["gen-zen"]?.safety, "check-first")
            let big = byId["gen-bigbundle"]
            c.check("discovered per-bundle dir becomes a target", big != nil)
            c.eq("discovered safety", big?.safety, "safe")
            c.eq("discovered path", big?.path, "\(HOME)/Library/Caches/BigBundle")
            c.eq("discovered measurement", big?.measurement, MeasureResult(sizeMb: 600, newestMtime: 1, fileCount: 2))
        }
    }
}
