import Foundation
import IOKit

/// System-disk I/O busy % from `IOBlockStorageDriver` `Statistics`.
///
/// Busy = Δ(`Total Time (Read)` + `Total Time (Write)`) / Δwall, with times in
/// nanoseconds. The counters sum each request's service time, so overlapping requests
/// add up: the ratio is the average number of requests in flight, capped at 100%. It
/// reaches 100% under sustained queued I/O even when the SSD has bandwidth left. Prefers the whole-disk driver for `disk0` (internal SSD on Apple
/// Silicon); falls back to the busiest whole disk. The chosen driver is cached so
/// every sample compares counters of the same device. Returns `nil` until a second
/// sample exists or when no driver reports stats.
final class DiskReader {
    private struct Snapshot {
        let busyNanoseconds: UInt64
        let uptime: TimeInterval
    }

    private var driver: io_service_t = 0
    private var previous: Snapshot?
    private var rescan = RescanGate(interval: 30)

    deinit {
        if driver != 0 {
            IOObjectRelease(driver)
        }
    }

    func sample() -> Double? {
        guard let current = readSnapshot() ?? rediscoverAndRead() else {
            previous = nil
            return nil
        }
        defer { previous = current }

        guard let previous else { return nil }

        let deltaWall = current.uptime - previous.uptime
        guard deltaWall > 0.05 else { return nil }

        let busyNs = Double(current.busyNanoseconds &- previous.busyNanoseconds)
        let percent = (busyNs / (deltaWall * 1_000_000_000.0)) * 100.0
        guard percent.isFinite, percent >= 0 else { return nil }
        return min(percent, 100)
    }

    private func readSnapshot() -> Snapshot? {
        guard driver != 0,
              let stats = IORegistry.property(driver, "Statistics") as? NSDictionary
        else {
            return nil
        }
        return Snapshot(
            busyNanoseconds: Self.busyTime(in: stats),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func rediscoverAndRead() -> Snapshot? {
        guard rescan.shouldAttempt() else { return nil }
        if driver != 0 {
            IOObjectRelease(driver)
        }
        driver = Self.findSystemDiskDriver()
        // Counters of a different device are not comparable with the last snapshot.
        previous = nil
        return readSnapshot()
    }

    /// Whole-disk driver for `disk0` when present, else the one with the most I/O time.
    /// Returns a retained object (or 0); all other candidates are released.
    private static func findSystemDiskDriver() -> io_service_t {
        var chosen: io_service_t = 0
        var chosenIsDisk0 = false
        var busiestTotal: UInt64 = 0

        for service in IORegistry.services(matching: "IOBlockStorageDriver") {
            guard !chosenIsDisk0,
                  let stats = IORegistry.property(service, "Statistics") as? NSDictionary,
                  let bsdName = wholeDiskBSDName(for: service)
            else {
                IOObjectRelease(service)
                continue
            }

            let total = busyTime(in: stats)
            let isDisk0 = bsdName == "disk0"
            guard isDisk0 || total >= busiestTotal else {
                IOObjectRelease(service)
                continue
            }

            if chosen != 0 {
                IOObjectRelease(chosen)
            }
            chosen = service
            chosenIsDisk0 = isDisk0
            busiestTotal = total
        }
        return chosen
    }

    private static func wholeDiskBSDName(for service: io_service_t) -> String? {
        let children = IORegistry.children(of: service)
        defer { IORegistry.release(children) }

        for child in children {
            guard IORegistry.property(child, "Whole") as? Bool == true,
                  let bsdName = IORegistry.property(child, "BSD Name") as? String
            else {
                continue
            }
            return bsdName
        }
        return nil
    }

    private static func busyTime(in stats: NSDictionary) -> UInt64 {
        let read = (stats["Total Time (Read)"] as? NSNumber)?.uint64Value ?? 0
        let write = (stats["Total Time (Write)"] as? NSNumber)?.uint64Value ?? 0
        return read &+ write
    }
}
