// LiveMetrics.swift — real-time CPU, memory and free space for the menu bar and popover.
//
// Reads the kernel directly (host_processor_info / host_statistics64 / statfs). No `ps`, no
// subprocess: the sampler's 30-second `ps` tick is far too slow and far too expensive to
// drive a menu bar that updates every couple of seconds.
import Darwin
import Foundation

struct Metrics: Sendable, Equatable {
    var cpuPercent: Double = 0
    var memUsedGb: Double = 0
    var memTotalGb: Double = 0
    var freeGb: Double = 0
    var thermal: String = "Normal"
    var memPercent: Double { memTotalGb > 0 ? memUsedGb / memTotalGb * 100 : 0 }
}

final class LiveMetrics: @unchecked Sendable {
    static let shared = LiveMetrics()
    /// CPU is a rate, so it needs the previous tick counts to compare against.
    private var prevTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private let lock = NSLock()

    func sample() -> Metrics {
        Metrics(cpuPercent: cpu(), memUsedGb: memory().used, memTotalGb: memory().total,
                freeGb: freeSpace(), thermal: thermalLevel())
    }

    /// Busy fraction between this call and the last one, across all cores.
    func cpu() -> Double {
        // HOST_CPU_LOAD_INFO_COUNT is a C macro, not imported into Swift
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let u = UInt64(info.cpu_ticks.0), s = UInt64(info.cpu_ticks.1)
        let i = UInt64(info.cpu_ticks.2), n = UInt64(info.cpu_ticks.3)

        lock.lock(); defer { lock.unlock() }
        defer { prevTicks = (u, s, i, n) }
        guard let p = prevTicks else { return 0 }        // first call has nothing to diff
        let du = Double(u &- p.user), ds = Double(s &- p.sys)
        let di = Double(i &- p.idle), dn = Double(n &- p.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return 0 }
        return min(max((du + ds + dn) / total * 100, 0), 100)
    }

    /// "Used" excludes purgeable and file-backed pages, matching what Activity Monitor
    /// calls memory in use rather than everything the kernel has touched.
    func memory() -> (used: Double, total: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        guard r == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Double(pageSize)
        let active = Double(stats.active_count) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        return ((active + wired + compressed) / 1_073_741_824, total)
    }

    func freeSpace() -> Double {
        var fs = statfs()
        guard statfs("/System/Volumes/Data", &fs) == 0 else { return 0 }
        return Double(fs.f_bavail) * Double(fs.f_bsize) / 1_073_741_824
    }

    /// Apple Silicon exposes no unprivileged temperature, so report pressure, not degrees.
    func thermalLevel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "Normal"
        }
    }
}
