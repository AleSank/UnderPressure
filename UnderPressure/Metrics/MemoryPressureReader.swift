import Darwin

/// Reads the kernel's memory-pressure state via `sysctl` — the signal behind Activity
/// Monitor's pressure graph. It complements RAM used % in the memory stress (see
/// `UnderPressureScore.memoryStress`): it rises when the system starts swapping, even
/// before usage looks extreme. It is not part of `VM_STATISTICS64`; the kernel exposes it as:
/// - `kern.memorystatus_vm_pressure_level` — 1 normal, 2 warning, 4 critical
/// - `kern.memorystatus_level` — % of memory the kernel considers available
///
/// The level picks the band (normal 0–40, warning 60–85, critical 90–100); the available %
/// positions the value inside it, so the result is monotonic within each level.
struct MemoryPressureReader {
    private let levelMIB = Self.mib(for: "kern.memorystatus_vm_pressure_level")
    private let availableMIB = Self.mib(for: "kern.memorystatus_level")

    /// Pressure as stress on a 0…100 scale, or `nil` when the sysctls are unavailable.
    func sample() -> Double? {
        guard let rawLevel = Self.read(levelMIB),
              let available = Self.read(availableMIB)
        else {
            return nil
        }

        let band: ClosedRange<Double> = switch rawLevel {
        case 4...: 90...100
        case 2...: 60...85
        default: 0...40
        }

        let pressured = min(max(100 - Double(available), 0), 100) / 100
        return band.lowerBound + pressured * (band.upperBound - band.lowerBound)
    }

    /// Resolves the name once; per-sample reads then skip the string lookup.
    private static func mib(for name: String) -> [Int32] {
        var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var count = mib.count
        guard sysctlnametomib(name, &mib, &count) == 0 else { return [] }
        return Array(mib.prefix(count))
    }

    private static func read(_ mib: [Int32]) -> Int32? {
        guard !mib.isEmpty else { return nil }
        var mib = mib
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
