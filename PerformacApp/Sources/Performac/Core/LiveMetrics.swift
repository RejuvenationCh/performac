// LiveMetrics.swift — real-time CPU, memory and free space for the menu bar and popover.
//
// Reads the kernel directly (host_processor_info / host_statistics64 / statfs). No `ps`, no
// subprocess: the sampler's 30-second `ps` tick is far too slow and far too expensive to
// drive a menu bar that updates every couple of seconds.
import Darwin
import Foundation
import IOKit.ps

struct Metrics: Sendable, Equatable {
    var cpuPercent: Double = 0
    var memUsedGb: Double = 0
    var memTotalGb: Double = 0
    var freeGb: Double = 0
    var totalGb: Double = 0
    var thermal: String = "Normal"
    var netDownBps: Double = 0
    var netUpBps: Double = 0
    var batteryPercent: Int = -1        // -1 = no battery
    var batteryCharging = false
    var memPercent: Double { memTotalGb > 0 ? memUsedGb / memTotalGb * 100 : 0 }
    var diskUsedPercent: Double { totalGb > 0 ? (totalGb - freeGb) / totalGb * 100 : 0 }
}

final class LiveMetrics: @unchecked Sendable {
    static let shared = LiveMetrics()
    /// CPU is a rate, so it needs the previous tick counts to compare against.
    private var prevTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    /// Network is a rate too: bytes counters plus the moment they were read.
    private var prevNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    private let lock = NSLock()

    func sample() -> Metrics {
        let mem = memory()
        let disk = space()
        let net = network()
        let bat = battery()
        return Metrics(cpuPercent: cpu(), memUsedGb: mem.used, memTotalGb: mem.total,
                       freeGb: disk.free, totalGb: disk.total, thermal: thermalLevel(),
                       netDownBps: net.down, netUpBps: net.up,
                       batteryPercent: bat.percent, batteryCharging: bat.charging)
    }

    /// Throughput across every physical interface, from the kernel's byte counters.
    /// Loopback and virtual interfaces are excluded or the numbers double-count.
    func network() -> (down: Double, up: Double) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var inB: UInt64 = 0, outB: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            guard let d = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            inB += UInt64(d.pointee.ifi_ibytes)
            outB += UInt64(d.pointee.ifi_obytes)
        }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        defer { prevNet = (inB, outB, now) }
        guard let prev = prevNet else { return (0, 0) }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0.05 else { return (0, 0) }
        // counters wrap and interfaces come and go; a negative delta means reset, not traffic
        let dIn = inB >= prev.inBytes ? Double(inB - prev.inBytes) : 0
        let dOut = outB >= prev.outBytes ? Double(outB - prev.outBytes) : 0
        return (dIn / dt, dOut / dt)
    }

    func battery() -> (percent: Int, charging: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let src = list.first,
              let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any]
        else { return (-1, false) }
        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        return (max > 0 ? Int(Double(cur) / Double(max) * 100) : -1, charging)
    }

    func space() -> (free: Double, total: Double) {
        var fs = statfs()
        guard statfs("/System/Volumes/Data", &fs) == 0 else { return (0, 0) }
        let unit = Double(fs.f_bsize)
        return (Double(fs.f_bavail) * unit / 1_073_741_824,
                Double(fs.f_blocks) * unit / 1_073_741_824)
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
