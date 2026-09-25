import AppKit

/// Menu row strings and warning tones.
///
/// Rows are three columns — `label ⇥ value ⇥ detail` (top apps: `⇥ percentage ⇥ app`) —
/// rendered with shared tab stops (`StatusItemController.rowStyle`): values right-aligned in
/// a column sized for "100%" (a row never changes length as the value grows), details one
/// space after it, so `7% · 45°` has equal space around the separator and separators line up.
enum MenuCopy {
    enum Tone: Int, Comparable {
        case secondary, primary, orange, red

        var nsColor: NSColor {
            switch self {
            case .secondary: .secondaryLabelColor
            case .primary: .labelColor
            case .orange: .systemOrange
            case .red: .systemRed
            }
        }

        static func < (lhs: Tone, rhs: Tone) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// A secondary row below the metrics: revealed only when `isRelevant`.
    struct DetailRow {
        let text: String
        let tone: Tone
        let isRelevant: Bool
    }

    static let topAppsHeader = "Top apps (CPU)"
    /// Every label of the first column; the widest one sizes it.
    static let columnLabels = ["CPU:", "GPU:", "Fan:", "Fans:", "RAM:", "Disk:"]
    /// Widest value; sizes the value column before the details.
    static let widestPercentage = "100%"

    // MARK: - Rows

    static func cpuRow(_ monitor: UnderPressureMonitor) -> String {
        columns("CPU:", percent(monitor.cpuPercent), "· \(degrees(monitor.cpuTemperature))")
    }

    static func gpuRow(_ monitor: UnderPressureMonitor) -> String {
        columns("GPU:", percent(monitor.gpuPercent), "· \(degrees(monitor.gpuTemperature))")
    }

    /// Below CPU and GPU; `nil` on Macs without fans (the row is hidden).
    static func fanRow(_ monitor: UnderPressureMonitor) -> String? {
        monitor.fans.map(fanText)
    }

    /// Same shape as the CPU/GPU rows: share of maximum speed, then the actual speed
    /// (averaged over the fans) — `Fans ⇥ 34% ⇥ · 2317 rpm` — or `· Off` when they are
    /// stopped (Apple Silicon fans stop at low load).
    static func fanText(_ fans: [FanReader.Fan]) -> String {
        let label = fans.count == 1 ? "Fan:" : "Fans:"
        let rpm = average(fans.map(\.rpm)) ?? 0
        let percents = fans.compactMap(\.percent)
        let share = percents.count == fans.count ? average(percents) : nil
        guard rpm.rounded() > 0 else { return columns(label, percent(0), "· Off") }
        return columns(label, percent(share), "· \(String(format: "%.0f", rpm)) rpm")
    }

    static func ramRow(_ monitor: UnderPressureMonitor) -> String {
        columns("RAM:", percent(monitor.memoryUsedPercent))
    }

    static func diskRow(_ monitor: UnderPressureMonitor) -> String {
        columns("Disk:", percent(monitor.diskPercent))
    }

    /// The `index`-th heaviest app, e.g. ` 42%  Xcode` (share of the whole CPU, same scale
    /// as the CPU row). Relevant from `UnderPressureMonitor.topAppThreshold`.
    static func topAppRow(_ monitor: UnderPressureMonitor, at index: Int) -> DetailRow {
        guard monitor.topCPUApps.indices.contains(index) else {
            return DetailRow(text: "\t\(percent(nil))", tone: .secondary, isRelevant: false)
        }
        let app = monitor.topCPUApps[index]
        return DetailRow(
            text: "\t\(percent(app.value))\t\(app.name)",
            tone: .secondary,
            isRelevant: app.value >= UnderPressureMonitor.topAppThreshold
        )
    }

    /// Relevant when memory is high (RAM used ≥ 90% or kernel pressure), naming the app
    /// holding the most memory.
    static func pressureRow(_ monitor: UnderPressureMonitor) -> DetailRow {
        let tone = memoryTone(monitor)
        let level = switch tone {
        case .red: "critical"
        case .orange: "high"
        default: "normal"
        }
        var text = "Memory pressure: \(level)"
        if tone != .secondary, let top = monitor.topMemoryApp {
            text += " · \(top.name) \(gigabytes(top.value))"
        }
        return DetailRow(text: text, tone: tone, isRelevant: tone != .secondary)
    }

    /// Relevant while macOS reports heat-related throttling.
    static func thermalRow(_ monitor: UnderPressureMonitor) -> DetailRow {
        let text = switch monitor.thermalState {
        case .critical: "Thermal state: critical (throttling)"
        case .serious: "Thermal state: serious (throttling)"
        case .fair: "Thermal state: fair"
        default: "Thermal state: normal"
        }
        let tone = thermalTone(monitor)
        return DetailRow(text: text, tone: tone == .primary ? .secondary : tone, isRelevant: tone != .primary)
    }

    static func sensorNotice(_ monitor: UnderPressureMonitor) -> DetailRow {
        DetailRow(text: monitor.lastError ?? "", tone: .orange, isRelevant: monitor.lastError != nil)
    }

    // MARK: - Tones

    /// Temperatures are colored by the system thermal state, not by °C: safe ranges
    /// differ per chip (Apple Silicon dies routinely run above 95 °C under load).
    static func cpuTone(_ monitor: UnderPressureMonitor) -> Tone {
        max(tone(monitor.cpuPercent, warn: 80, critical: 90), thermalTone(monitor))
    }

    static func gpuTone(_ monitor: UnderPressureMonitor) -> Tone {
        max(tone(monitor.gpuPercent, warn: 80, critical: 90), thermalTone(monitor))
    }

    /// Same memory stress as the icon: orange from 90% used or kernel warning, red only on
    /// kernel critical pressure.
    static func ramTone(_ monitor: UnderPressureMonitor) -> Tone {
        let tone = memoryTone(monitor)
        return tone == .secondary ? .primary : tone
    }

    static func diskTone(_ monitor: UnderPressureMonitor) -> Tone {
        tone(monitor.diskPercent, warn: 80, critical: 90)
    }

    // MARK: - Helpers

    /// `label ⇥ value ⇥ detail` (see the type doc); the detail is optional.
    private static func columns(_ label: String, _ value: String, _ detail: String? = nil) -> String {
        [label, value, detail].compactMap { $0 }.joined(separator: "\t")
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    private static func degrees(_ celsius: Double?) -> String {
        celsius.map { String(format: "%.0f°", $0) } ?? "—"
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }

    private static func memoryTone(_ monitor: UnderPressureMonitor) -> Tone {
        guard let stress = monitor.memoryStress else { return .secondary }
        if stress >= UnderPressureScore.memoryCriticalStress { return .red }
        if stress >= UnderPressureScore.memoryWarningStress { return .orange }
        return .secondary
    }

    private static func thermalTone(_ monitor: UnderPressureMonitor) -> Tone {
        switch monitor.thermalState {
        case .critical: .red
        case .serious: .orange
        default: .primary
        }
    }

    private static func tone(_ value: Double?, warn: Double, critical: Double) -> Tone {
        guard let value else { return .primary }
        if value >= critical { return .red }
        if value >= warn { return .orange }
        return .primary
    }
}
