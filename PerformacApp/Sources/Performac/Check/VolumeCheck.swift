// VolumeCheck.swift: drives arriving and leaving.
//
// The picker used to read /Volumes on every render, so a drive plugged in while the Disk tab
// was open never appeared: nothing told SwiftUI the directory had changed. The list is now
// published and refreshed from NSWorkspace's mount notifications, which means the interesting
// logic is "what changed since last time", and that is what these check.
import AppKit
import Foundation

enum VolumeCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        // the real list, against the real /Volumes
        let live = EngineStore.volumePaths()
        c.check("volumes: every entry is under /Volumes",
                live.allSatisfy { $0.hasPrefix("/Volumes/") })
        c.check("volumes: the boot volume is excluded",
                !live.contains { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) == "/" })
        c.check("volumes: entries exist", live.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        c.check("volumes: sorted", live == live.sorted())

        let store = EngineStore(db: DB(path: NSTemporaryDirectory() + "performac-vol-\(UUID().uuidString).db"))

        // the picker must always offer Home, and every mounted drive, and the combined option
        // only when there is more than one thing to combine
        let targets = store.scanTargets
        c.check("volumes: Home is always a target", targets.contains { $0.label == "Home" })
        c.eq("volumes: every mounted drive is a target",
             Set(targets.map(\.path)).intersection(live), Set(live))
        c.eq("volumes: All drives is offered exactly when there is more than one",
             targets.contains { $0.path == EngineStore.allDrives }, live.count >= 1)
        c.eq("volumes: the combined option is not itself a drive to walk",
             store.allDriveRoots.contains(EngineStore.allDrives), false)
        c.eq("volumes: every drive is walked by a combined scan",
             Set(store.allDriveRoots), Set([NSHomeDirectory()] + live))

        // a drive appearing is offered; the same list twice changes nothing
        store.mountedVolumesForChecks = ["/Volumes/A"]
        store.applyVolumesForChecks(["/Volumes/A", "/Volumes/B"])
        c.eq("volumes: a drive that appears is offered", store.newlyMounted, "/Volumes/B")
        store.applyVolumesForChecks(["/Volumes/A", "/Volumes/B"])
        c.eq("volumes: an unchanged list leaves the offer alone", store.newlyMounted, "/Volumes/B")

        // unplugging the offered drive withdraws the offer rather than leaving a dead button
        store.applyVolumesForChecks(["/Volumes/A"])
        c.eq("volumes: unplugging the offered drive withdraws the offer", store.newlyMounted, nil)

        // an unrelated unplug must not withdraw a live offer
        store.applyVolumesForChecks(["/Volumes/A", "/Volumes/C"])
        c.eq("volumes: a second arrival is offered", store.newlyMounted, "/Volumes/C")
        store.applyVolumesForChecks(["/Volumes/C"])
        c.eq("volumes: an unrelated unplug leaves the offer standing",
             store.newlyMounted, "/Volumes/C")

        // browsing a drive that gets unplugged has to land somewhere real
        store.setScanRoot("/Volumes/Gone")
        store.applyVolumesForChecks(live)
        c.eq("volumes: unplugging what you were browsing falls back to Home",
             store.scanRoot, NSHomeDirectory())
        // and the combined root is not a path to fall back from
        store.setScanRoot(EngineStore.allDrives)
        store.applyVolumesForChecks(live.isEmpty ? ["/Volumes/X"] : [])
        c.eq("volumes: the combined root survives a drive leaving",
             store.scanRoot, EngineStore.allDrives)
    }
}
