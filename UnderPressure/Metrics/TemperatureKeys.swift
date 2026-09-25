import Darwin

/// SMC temperature keys per chip family.
///
/// Key names change with every Apple Silicon generation (and the same name can mean a
/// CPU core on one chip and something else on another), so there is no reliable generic
/// rule: blind prefix scans also pick up keys holding constants (e.g. `Tf16` = 77 °C and
/// `Tf12` = −11 °C on an M3 Pro). Lists come from Stats (github.com/exelban/stats,
/// `Modules/Sensors/values.swift`, September 2026), the most widely maintained public
/// table, plus keys measured on an M3 Pro (each one rises under a full CPU load).
///
/// Readers average every listed key that exists and reads plausibly (see
/// `SMCClient.plausibleCelsius`); missing keys are simply skipped. Update these tables
/// when a new chip ships.
enum TemperatureKeys {
    enum Chip: Equatable {
        case appleSilicon(generation: Int)
        case appleA18Pro
        case intel
        case unknown
    }

    /// The running Mac's chip, from `machdep.cpu.brand_string` ("Apple M3 Pro", "Intel(R)…").
    static let current = chip(brand: brandString())

    /// Parses a CPU brand string (pure, unit tested).
    static func chip(brand: String) -> Chip {
        if brand.hasPrefix("Intel") { return .intel }
        if brand.hasPrefix("Apple A18 Pro") { return .appleA18Pro }
        guard brand.hasPrefix("Apple M") else { return .unknown }
        let digits = brand.dropFirst("Apple M".count).prefix { $0.isNumber }
        return Int(digits).map { .appleSilicon(generation: $0) } ?? .unknown
    }

    /// CPU core keys for `chip`; unknown or newer chips get every Apple Silicon list.
    static func cpu(for chip: Chip) -> [String] {
        switch chip {
        case .appleSilicon(1): m1CPU
        case .appleSilicon(2): m2CPU
        case .appleSilicon(3): m3CPU
        case .appleSilicon(4): m4CPU
        case .appleSilicon(5): m5CPU
        case .appleA18Pro: a18ProCPU
        case .intel: intelCPU
        case .appleSilicon, .unknown: unique(m5CPU + m4CPU + m3CPU + m2CPU + m1CPU)
        }
    }

    /// GPU keys for `chip`; unknown or newer chips get every Apple Silicon list.
    static func gpu(for chip: Chip) -> [String] {
        switch chip {
        case .appleSilicon(1): m1GPU
        case .appleSilicon(2): m2GPU
        case .appleSilicon(3): m3GPU
        case .appleSilicon(4): m4GPU
        case .appleSilicon(5): m5GPU
        case .appleA18Pro: a18ProGPU
        case .intel: intelGPU
        case .appleSilicon, .unknown: unique(m5GPU + m4GPU + m3GPU + m2GPU + m1GPU)
        }
    }

    /// Apple Silicon GPU sensor keys start with this; last-resort discovery for chips newer
    /// than the tables (18 `Tg…` keys on an M3 Pro, all plausible).
    static let appleSiliconGPUPrefix = "Tg"

    /// Intel reports one package/proximity sensor: use the first that answers instead of
    /// averaging (core keys are only a fallback).
    static func prefersFirstKey(for chip: Chip) -> Bool {
        chip == .intel
    }

    // MARK: - Tables

    private static let m1CPU = [
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
    ]
    private static let m1GPU = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]

    private static let m2CPU = [
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
    ]
    private static let m2GPU = ["Tg0f", "Tg0j"]

    /// Stats' M3 keys, plus the efficiency (`Te…`) and performance (`Tp…` pairs) core keys
    /// measured on an M3 Pro, where most of Stats' `Tf0x`/`Tf4x` keys don't exist.
    private static let m3CPU = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        "Te04", "Te06", "Te0G", "Te0H", "Te0I", "Te0Q", "Te0R", "Te0T", "Te0U", "Te0V",
        "Tp04", "Tp05", "Tp0C", "Tp0D", "Tp0K", "Tp0L", "Tp0R", "Tp0S", "Tp0U", "Tp0V",
        "Tp0a", "Tp0b", "Tp0g", "Tp0h", "Tp0m", "Tp0n", "Tp0u", "Tp0v", "Tp0y", "Tp0z",
        "Tp16", "Tp17", "Tp1E", "Tp1F", "Tp1I", "Tp1J", "Tp1Q", "Tp1R", "Tp1S", "Tp3O", "Tp3W",
    ]
    private static let m3GPU = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]

    private static let m4CPU = [
        "Te05", "Te0S", "Te09", "Te0H",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
    ]
    private static let m4GPU = [
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k",
    ]

    private static let m5CPU = [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
    ]
    private static let m5GPU = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]

    private static let a18ProCPU = ["Te05", "Te0S", "Tp05", "Tp0D"]
    private static let a18ProGPU = ["Tg05", "Tg0D", "Tg0L", "Tg0e"]

    /// Intel, in preference order: package, proximity, diode…, then individual cores.
    ///
    /// | Key  | Meaning                  |
    /// |------|--------------------------|
    /// | TCAD | CPU package              |
    /// | TC0P | CPU proximity            |
    /// | TC0D | CPU diode                |
    /// | TC0E | CPU diode (virtual)      |
    /// | TC0F | CPU diode (filtered)     |
    /// | TC0H | CPU heatsink             |
    /// | TC%C | CPU core % (0…9)         |
    private static let intelCPU = ["TCAD", "TC0P", "TC0D", "TC0E", "TC0F", "TC0H"]
        + (0...9).map { "TC\($0)C" } + (0...9).map { "TC\($0)c" }

    /// | Key  | Meaning                |
    /// |------|------------------------|
    /// | TCGC | Intel integrated GPU   |
    /// | TG0D | discrete GPU diode     |
    /// | TGDD | AMD Radeon             |
    /// | TG0P | GPU proximity          |
    /// | TG0H | GPU heatsink           |
    private static let intelGPU = ["TG0D", "TGDD", "TG0P", "TG0H", "TCGC"]

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func brandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
