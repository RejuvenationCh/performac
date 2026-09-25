// Disk/ScanCLI.swift: `Performac scan <path>`: headless scan with the numbers the
// go/no-go decision needs (total time, time-to-first-progress, peak RSS, top dirs).
import Foundation

enum ScanCLI {
    static func run(path: String) async -> Int32 {
        var root = URL(fileURLWithPath: path)
        // "/" is the firmlink view. Scanning the Data volume directly avoids
        // double-counting every firmlink (Users, Applications, Library, ...).
        if root.path == "/" { root = URL(fileURLWithPath: "/System/Volumes/Data") }

        let start = Date()
        let scanner = DiskScanner()
        var firstProgress: TimeInterval?
        var lastPrint: TimeInterval = 0

        print("scanning \(root.path)")
        for await event in scanner.scan(root) {
            switch event {
            case .progress(let s):
                if firstProgress == nil {
                    firstProgress = Date().timeIntervalSince(start)
                    print(String(format: "first-progress %.1fs", firstProgress!))
                }
                let now = Date().timeIntervalSince(start)
                if now - lastPrint >= 5 {
                    print(String(format: "  %.1fs files=%d bytes=%.1f GB  %@",
                                 now, s.filesScanned, Double(s.bytes) / 1e9, s.currentPath))
                    lastPrint = now
                }
            case .finished(let sum):
                let f = ByteCountFormatter()
                print(String(format: "first-progress %.1fs", firstProgress ?? -1))
                print("total \(String(format: "%.1f", sum.elapsed))s  files=\(sum.files)  bytes=\(f.string(fromByteCount: sum.bytes))")
                print("peak-rss \(String(format: "%.1f", Self.peakRssMb())) MB")
                print("top directories:")
                for d in sum.topDirectories.prefix(25) {
                    print(String(format: "  %9d files %@  %@", d.files, f.string(fromByteCount: d.bytes), d.path))
                }
            }
        }
        return 0
    }

    private static func peakRssMb() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_maxrss) / 1024.0 / 1024.0   // ru_maxrss is in bytes on macOS
    }
}
