import Darwin
import Foundation

/// RAM used % from `HOST_VM_INFO64` + physical memory size — shown in the menu.
/// Stress uses `MemoryPressureReader` instead (used bytes are skewed by caching).
///
/// Matches Activity Monitor "Memory Used" / physical memory (verified on an M3 Pro
/// against `vm_stat` and `top`).
struct MemoryReader {
    /// Cached once: every `mach_host_self()` call adds a reference to the host port.
    private let host = mach_host_self()
    /// Kernel page size the VM counters are expressed in (16 KB on Apple Silicon).
    private let pageSize: UInt64
    private let totalBytes = ProcessInfo.processInfo.physicalMemory

    init() {
        var kernelPageSize: vm_size_t = 0
        pageSize = host_page_size(host, &kernelPageSize) == KERN_SUCCESS ? UInt64(kernelPageSize) : 0
    }

    /// Used % (0…100), or `nil` when the VM statistics are unavailable.
    func sample() -> Double? {
        guard pageSize > 0, totalBytes > 0 else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        // Activity Monitor "Memory Used" = App Memory + Wired + Compressed, where
        // App Memory = anonymous (internal) pages − purgeable, and Compressed = pages
        // occupied by the compressor. File-backed cache is excluded.
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = anonymous &- min(purgeable, anonymous)
        let usedPages = appPages &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
        let used = min(totalBytes, usedPages &* pageSize)

        return Double(used) / Double(totalBytes) * 100.0
    }
}
