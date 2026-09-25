import Foundation
import IOKit

/// Thin helpers over the IOKit registry shared by the hardware readers.
/// `nonisolated` so readers can release objects from their (nonisolated) `deinit`.
nonisolated enum IORegistry {
    /// All services matching `className`. The caller owns every returned object and
    /// must balance it with `IOObjectRelease` (see `release(_:)`).
    static func services(matching className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(className),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    /// Direct children of `entry` in the service plane (caller owns each object).
    static func children(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    /// A single registry property. Cheaper than `IORegistryEntryCreateCFProperties`,
    /// which copies (and bridges) the entry's whole property table.
    static func property(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    static func release(_ objects: [io_object_t]) {
        for object in objects {
            IOObjectRelease(object)
        }
    }

    private static func drain(_ iterator: io_iterator_t) -> [io_object_t] {
        var objects: [io_object_t] = []
        var object = IOIteratorNext(iterator)
        while object != 0 {
            objects.append(object)
            object = IOIteratorNext(iterator)
        }
        return objects
    }
}

/// Rate-limits expensive device rediscovery so a missing or flaky sensor is not
/// re-probed on every sample.
struct RescanGate {
    private let interval: TimeInterval
    private var lastAttempt: TimeInterval = -.infinity

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func shouldAttempt(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now - lastAttempt >= interval else { return false }
        lastAttempt = now
        return true
    }
}
