// ThermalSensors.swift — real die temperature on Apple Silicon.
//
// pmset and powermetrics gave nothing useful without root, which is why this app shipped
// thermal *pressure* rather than degrees. That was an incomplete conclusion: the sensors are
// reachable through IOHIDEventSystem, unprivileged, and there are 47 of them on this Mac.
//
// This uses private IOKit symbols resolved at runtime (the same route Stats and Macs Fan
// Control take). Every step is optional-chained and any failure degrades to nil, so an OS
// update that renames a symbol costs a reading, never a crash.
import Foundation
import IOKit

enum ThermalSensors {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias CopyProperty = @convention(c) (AnyObject?, CFString) -> Unmanaged<AnyObject>?
    private typealias EventFloat = @convention(c) (AnyObject?, Int32) -> Double

    nonisolated(unsafe) private static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ n: String) -> T? { dlsym(lib, n).map { unsafeBitCast($0, to: T.self) } }

    /// Held open: rebuilding the client per sample is far more expensive than the read.
    nonisolated(unsafe) private static var client: AnyObject? = {
        guard let create: ClientCreate = sym("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatching = sym("IOHIDEventSystemClientSetMatching"),
              let c = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        // page 0xff00 / usage 5 selects the temperature sensors
        _ = setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return c
    }()

    /// Representative SoC temperature in Celsius, or nil if the sensors are unreadable.
    ///
    /// Averages the PMU die sensors rather than taking a single one: individual dies swing
    /// several degrees apart, so one sensor reads as noise while their mean tracks load.
    static func socCelsius() -> Double? {
        guard let client,
              let copyServices: CopyServices = sym("IOHIDEventSystemClientCopyServices"),
              let copyEvent: CopyEvent = sym("IOHIDServiceClientCopyEvent"),
              let copyProp: CopyProperty = sym("IOHIDServiceClientCopyProperty"),
              let floatVal: EventFloat = sym("IOHIDEventGetFloatValue"),
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return nil }

        var readings: [Double] = []
        for s in services {
            guard let name = copyProp(s, "Product" as CFString)?.takeUnretainedValue() as? String,
                  name.contains("tdie") || name.contains("tdev")   // die sensors, not battery or ambient
            else { continue }
            guard let ev = copyEvent(s, 15, 0, 0)?.takeUnretainedValue() else { continue }
            let c = floatVal(ev, 15 << 16)
            if c > 0, c < 130 { readings.append(c) }               // discard obvious garbage
        }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }
}
