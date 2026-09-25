import Foundation

/// Pure hardware-stress evaluation — no state, no I/O, easy to unit test.
///
/// Stress means the Mac is *struggling*, not merely busy:
/// ```
/// memory     = max(RAM used curve, kernel memory pressure)
/// base       = CPU × 0.35 + GPU × 0.35 + memory × 0.20 + Disk I/O × 0.10
/// saturation = max(sustained CPU × 0.7, sustained GPU × 0.7, memory)  // bottleneck
/// final      = max(base, saturation)
/// thermal state serious → final ≥ 75;  critical → final = 100
/// ```
/// - `base` uses instant loads, so the level reacts on the next sample.
/// - CPU and GPU act as a bottleneck through their *sustained* load (≈ 20 s average,
///   `SustainedAverage`): a few seconds of spike don't color the icon, half a minute of
///   full load does (Warning in ≈ 30 s). Alone each tops out at 70, clearly amber/orange
///   but never red: the Mac is working hard, not failing.
/// - Disk only counts in `base`: its busy % saturates under ordinary queued I/O
///   (backups, indexing) that users don't feel.
/// - Memory counts at full value. RAM used (what the user's apps hold, file cache excluded)
///   maps to 40 at 70%, 60 (Warning) at 90%, 85 at 100%: little headroom is pressure the
///   user should see. The kernel's own pressure (warning ≥ 60, critical ≥ 90) covers
///   swapping that starts before usage looks extreme; only it can reach red.
/// - Heat uses the system's thermal state (is it throttling?) rather than °C thresholds,
///   which differ per chip and sensor.
enum UnderPressureScore {
    /// All loads are percentages (0…100). Missing values count as 0.
    struct Components {
        var cpu: Double?
        /// CPU % averaged over the last ≈ 20 s.
        var cpuSustained: Double?
        var gpu: Double?
        /// GPU % averaged over the last ≈ 20 s.
        var gpuSustained: Double?
        /// RAM used % (app + wired + compressed; file cache excluded).
        var memoryUsed: Double?
        /// Kernel memory pressure, already banded (`MemoryPressureReader`).
        var memoryPressure: Double?
        var disk: Double?
        var thermalState: ProcessInfo.ThermalState = .nominal
    }

    static let cpuWeight = 0.35
    static let gpuWeight = 0.35
    static let memoryWeight = 0.20
    static let diskWeight = 0.10
    /// Sustained full CPU or GPU alone lifts stress to 70 (Warning, clearly visible; not Critical).
    static let saturationFactor = 0.7

    /// Memory stress from which the menu calls it high / critical.
    static let memoryWarningStress = 60.0
    static let memoryCriticalStress = 90.0
    /// RAM used % → stress knots: still Normal at 70%, Warning at 90%, orange at 100%.
    private static let usedMemoryCurve: [(used: Double, stress: Double)] = [
        (0, 0), (70, 40), (90, 60), (100, 85),
    ]

    static let thermalSeriousFloor = 75.0
    static let thermalCriticalStress = 100.0

    /// Final stress on a 0…100 scale.
    static func finalStress(_ components: Components) -> Double {
        let cpu = clamp(components.cpu)
        let gpu = clamp(components.gpu)
        let memory = memoryStress(used: components.memoryUsed, pressure: components.memoryPressure)
        let disk = clamp(components.disk)

        let base = cpu * cpuWeight + gpu * gpuWeight + memory * memoryWeight + disk * diskWeight
        let sustainedLoad = max(clamp(components.cpuSustained), clamp(components.gpuSustained))
        let stress = max(base, sustainedLoad * saturationFactor, memory)

        switch components.thermalState {
        case .critical: return thermalCriticalStress
        case .serious: return max(stress, thermalSeriousFloor)
        default: return stress
        }
    }

    /// Memory's share of stress (0…100): the worse of RAM used and kernel pressure.
    static func memoryStress(used: Double?, pressure: Double?) -> Double {
        max(usedMemoryStress(clamp(used)), clamp(pressure))
    }

    /// Piecewise-linear interpolation along `usedMemoryCurve`.
    private static func usedMemoryStress(_ used: Double) -> Double {
        for (lower, upper) in zip(usedMemoryCurve, usedMemoryCurve.dropFirst()) where used <= upper.used {
            let t = (used - lower.used) / (upper.used - lower.used)
            return lower.stress + (upper.stress - lower.stress) * t
        }
        return usedMemoryCurve.last?.stress ?? 0
    }

    private static func clamp(_ percent: Double?) -> Double {
        min(max(percent ?? 0, 0), 100)
    }
}
