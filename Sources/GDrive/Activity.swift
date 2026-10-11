import Foundation
import IOKit

/// Cumulative bytes read and written on a whole disk, from the IORegistry
/// statistics of the block storage driver that owns it.
func diskCounters(_ bsdName: String) -> (read: UInt64, written: UInt64)? {
    let match = IOServiceMatching("IOMedia") as NSMutableDictionary
    match["IOPropertyMatch"] = ["BSD Name": bsdName]
    var entry = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }

    for _ in 0..<8 {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        IOObjectRelease(entry)
        entry = parent
        guard IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 else { continue }
        guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return nil }
        let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        let written = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        return (read, written)
    }
    return nil
}

/// Turns two counter samples into a rate, ignoring the keep-alive's own trickle.
struct ActivitySampler {
    enum Activity: Equatable {
        case idle
        case active(readRate: Double, writeRate: Double)
    }

    /// Bytes per second below which a direction counts as idle.
    static let threshold: Double = 200_000

    private var last: (read: UInt64, written: UInt64, at: Date)?

    /// Bytes moved since the drive was connected (the counters start at zero then).
    private(set) var totals: (read: UInt64, written: UInt64)?

    mutating func sample(_ bsdName: String) -> Activity? {
        guard let now = diskCounters(bsdName) else { last = nil; return nil }
        totals = (now.read, now.written)
        let stamp = Date()
        defer { last = (now.read, now.written, stamp) }
        guard let last, now.read >= last.read, now.written >= last.written else { return .idle }
        let seconds = max(stamp.timeIntervalSince(last.at), 0.1)
        let read = Double(now.read - last.read) / seconds
        let write = Double(now.written - last.written) / seconds
        let r = read >= Self.threshold ? read : 0
        let w = write >= Self.threshold ? write : 0
        return (r == 0 && w == 0) ? .idle : .active(readRate: r, writeRate: w)
    }

    mutating func reset() { last = nil; totals = nil }
}

func formatRate(_ bytesPerSecond: Double) -> String {
    String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
}
