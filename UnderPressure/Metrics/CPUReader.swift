import Darwin
import Foundation

/// System-wide CPU utilization via `HOST_CPU_LOAD_INFO` (one aggregate %, not per-core).
struct CPUReader {
    /// Cached once: every `mach_host_self()` call adds a reference to the host port.
    private let host = mach_host_self()
    private var previous: host_cpu_load_info?

    mutating func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(host, HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        defer { previous = info }

        guard let previous else { return nil }

        let user = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        return ((user + system + nice) / total) * 100.0
    }

}
