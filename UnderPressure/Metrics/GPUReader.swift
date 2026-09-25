import Foundation
import IOKit

/// System-wide GPU load from IOAccelerator `PerformanceStatistics`.
///
/// Best-effort on Apple Silicon and Intel Macs:
/// - Prefers `Device Utilization %` (common on AGX / many discrete GPUs)
/// - Falls back through Renderer / Tiler / vendor-style utilization keys
/// - Returns `nil` when no accelerator reports a usable % (callers show `—`)
///
/// Instantaneous driver snapshot — not IOReport residency. Accelerator services are
/// discovered once and cached; rediscovery (e.g. eGPU hot-plug) is rate-limited.
final class GPUReader {
    /// Known utilization dictionary keys across AGX / AMD / Intel drivers.
    private static let utilizationKeys = [
        "Device Utilization %",
        "Renderer Utilization %",
        "Tiler Utilization %",
        "GPU Utilization %",
        "GPU Activity%",
        "GpuActivity",
        "hardware utilization%",
        "Device Utilization",
        "Renderer Utilization",
    ]

    private var accelerators: [io_service_t] = []
    private var rescan = RescanGate(interval: 30)

    deinit {
        IORegistry.release(accelerators)
    }

    func sample() -> Double? {
        if let value = readUtilization() { return value }
        guard rescan.shouldAttempt() else { return nil }
        IORegistry.release(accelerators)
        accelerators = IORegistry.services(matching: "IOAccelerator")
        return readUtilization()
    }

    /// Highest utilization across accelerators (multi-GPU Intel Macs report several).
    private func readUtilization() -> Double? {
        var best: Double?
        for service in accelerators {
            guard let stats = IORegistry.property(service, "PerformanceStatistics") as? NSDictionary,
                  let value = Self.utilization(in: stats)
            else {
                continue
            }
            best = max(best ?? 0, value)
        }
        return best
    }

    private static func utilization(in stats: NSDictionary) -> Double? {
        for key in utilizationKeys {
            if let number = stats[key] as? NSNumber {
                let value = number.doubleValue
                guard value.isFinite, value >= 0 else { continue }
                return min(value, 100)
            }
        }
        // Case-insensitive scan for anything that looks like utilization %.
        for (key, raw) in stats {
            guard let key = key as? String, let number = raw as? NSNumber else { continue }
            let lower = key.lowercased()
            guard lower.contains("util") || lower.contains("activity") else { continue }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= 100 else { continue }
            return value
        }
        return nil
    }
}
