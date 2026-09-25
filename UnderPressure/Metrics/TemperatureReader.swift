import Foundation
import IOKit

/// CPU / GPU package temperature via curated IOHID sensors and AppleSMC keys.
///
/// Paths (tried in order, per sample):
/// 1. **IOHID** private temperature services (Apple Silicon die / PMU names; some Intel HIDs)
/// 2. **AppleSMC** four-char keys — Intel package + GPU diodes, plus AS GPU fallbacks
///
/// The HID client, its classified services and the first working SMC key are all
/// resolved once and cached; per tick only the temperature events are read.
/// Missing sensors return `nil`; callers show `—`. Never traps on absent keys.
final class TemperatureReader {
    private let hid = HIDTemperatureSensors()
    private let smc = SMCClient()
    private var cpuSMC = SMCKeyProbe(keys: SMCKeys.cpu)
    private var gpuSMC = SMCKeyProbe(keys: SMCKeys.gpu)

    /// Preferred CPU / package die temperature (IOHID, then Intel SMC).
    func sampleCPU() -> Double? {
        if let celsius = hid?.sample(.cpu) { return celsius }
        guard let smc else { return nil }
        return cpuSMC.read(using: smc)
    }

    /// GPU temperature: IOHID GPU-named sensors, then SMC GPU key allowlist.
    func sampleGPU() -> Double? {
        if let celsius = hid?.sample(.gpu) { return celsius }
        guard let smc else { return nil }
        return gpuSMC.read(using: smc)
    }
}

// MARK: - SMC

private enum SMCKeys {
    /// Intel / classic MacBook CPU package proximity & diode keys (`sp78` / `flt `).
    /// Prefer package/proximity over single-core when several respond.
    ///
    /// | Key  | Typical meaning        |
    /// |------|------------------------|
    /// | TC0P | CPU proximity          |
    /// | TC0D | CPU diode              |
    /// | TC0E | CPU PECI / package     |
    /// | TC0F | CPU PECI alt           |
    /// | TC0H | CPU heatsink           |
    /// | TC0C | CPU core 0             |
    /// | TC1C | CPU core 1             |
    /// | TC2C | CPU core 2             |
    /// | TC3C | CPU core 3             |
    /// | TCAH | CPU A heatsink         |
    /// | TCGC | CPU graphics / package |
    static let cpu = [
        "TC0P", "TC0D", "TC0E", "TC0F", "TC0H",
        "TCGC", "TCAH",
        "TC0C", "TC1C", "TC2C", "TC3C",
    ]

    /// GPU diode / proximity SMC keys for Apple Silicon + Intel/AMD Macs.
    ///
    /// | Key  | Typical meaning     |
    /// |------|---------------------|
    /// | Tg0D | AS GPU diode (flt)  |
    /// | Tg1D | AS GPU diode alt    |
    /// | TG0D | Intel/AMD GPU diode |
    /// | TG0P | GPU proximity       |
    /// | TG0H | GPU heatsink        |
    /// | TG1D | GPU diode alt       |
    /// | TG0F | GPU PECI-style      |
    static let gpu = [
        "Tg0D", "Tg1D",
        "TG0D", "TG0P", "TG0H", "TG1D", "TG0F",
    ]
}

/// Remembers the first key (in preference order) that yields a plausible reading.
/// Re-probing the whole list is rate-limited, so Macs without these keys (most
/// Apple Silicon CPUs) do not pay for a dozen failing SMC calls every second.
private struct SMCKeyProbe {
    let keys: [String]
    private var resolved: SMCClient.KeyInfo?
    private var rescan = RescanGate(interval: 60)

    init(keys: [String]) {
        self.keys = keys
    }

    mutating func read(using smc: SMCClient) -> Double? {
        if let resolved, let celsius = smc.readCelsius(resolved) {
            return celsius
        }
        guard rescan.shouldAttempt() else { return nil }

        resolved = nil
        for key in keys {
            guard let info = smc.keyInfo(key), let celsius = smc.readCelsius(info) else { continue }
            resolved = info
            return celsius
        }
        return nil
    }
}

// MARK: - IOHID (private, dlsym)

/// Private `IOHIDEventSystemClient` temperature services, classified by product name.
///
/// Creating an event-system client is expensive and retains kernel resources, so one
/// client lives for the app's lifetime and its services are rediscovered only when
/// every cached sensor of a group stops reporting (rate-limited).
private final class HIDTemperatureSensors {
    enum Group {
        case cpu, gpu
    }

    private static let temperatureEventType: Int64 = 15 // kIOHIDEventTypeTemperature
    private static let temperatureEventField: Int32 = 15 << 16 // IOHIDEventFieldBase(type)

    /// Broadened beyond M3 Pro `PMU tdie*` — covers common M1/M2/M3/M4 Product strings.
    private static let cpuNames = [
        "pACC MTR Temp",
        "eACC MTR Temp",
        "pACC",
        "eACC",
        "PMGR SOC Die Temp",
        "SOC MTR Temp",
        "SOC Die",
        "PMU tdie",
        "CPU Die",
        "cpu die",
        "die temperature",
        "core temperature",
        "CPU Average",
        "CPU Max",
        "package",
    ]

    private static let gpuNames = [
        "GPU Die",
        "GPU MTR",
        "GPU Average",
        "GPU Max",
        "AGX",
        "GFX Die",
        "gfx die",
        "gpu die",
        "GPU temperature",
    ]

    private static let deniedSubstrings = [
        "tcal", "tdev", "tvmr", "tcmz", "gas", "battery", "ambient", "nand",
        "ssd", "skin", "palm", "case", "headset", "microphone", "speaker",
    ]

    private let api: HIDFunctions
    private let client: AnyObject
    private var cpuServices: [AnyObject] = []
    private var gpuServices: [AnyObject] = []
    private var rescan = RescanGate(interval: 60)

    init?() {
        guard let api = HIDFunctions.shared,
              let client = api.create(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            return nil
        }
        let matching: [String: Int] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x0005,
        ]
        api.setMatching(client, matching as CFDictionary)

        self.api = api
        self.client = client
        discoverServices()
    }

    /// Hottest plausible reading among the group's sensors.
    func sample(_ group: Group) -> Double? {
        if let celsius = hottest(in: services(group)) { return celsius }
        guard !services(group).isEmpty, rescan.shouldAttempt() else { return nil }
        discoverServices()
        return hottest(in: services(group))
    }

    private func services(_ group: Group) -> [AnyObject] {
        switch group {
        case .cpu: cpuServices
        case .gpu: gpuServices
        }
    }

    private func hottest(in services: [AnyObject]) -> Double? {
        var best: Double?
        for service in services {
            guard let event = api.copyEvent(service, Self.temperatureEventType, 0, 0)?
                .takeRetainedValue()
            else {
                continue
            }
            let value = api.getFloat(event, Self.temperatureEventField)
            guard value.isFinite, value > 0, value < 110 else { continue }
            best = max(best ?? value, value)
        }
        return best
    }

    private func discoverServices() {
        cpuServices = []
        gpuServices = []
        guard let services = api.copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return
        }

        for service in services {
            guard let name = api.copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String
            else {
                continue
            }
            let lower = name.lowercased()
            guard !Self.deniedSubstrings.contains(where: lower.contains) else { continue }

            if Self.matches(name, Self.cpuNames) {
                cpuServices.append(service)
            }
            if Self.matches(name, Self.gpuNames) {
                gpuServices.append(service)
            }
        }
    }

    private static func matches(_ name: String, _ candidates: [String]) -> Bool {
        candidates.contains { name.localizedCaseInsensitiveContains($0) }
    }
}

/// Private IOKit HID symbols resolved once via `dlsym`.
private struct HIDFunctions {
    typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias ClientSetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    typealias ClientCopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    /// `IOHIDServiceClientCopyEvent(service, int64 type, int32 options, int64 timestamp)`.
    typealias ServiceCopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    typealias ServiceCopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    typealias EventGetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    let create: ClientCreate
    let setMatching: ClientSetMatching
    let copyServices: ClientCopyServices
    let copyEvent: ServiceCopyEvent
    let copyProperty: ServiceCopyProperty
    let getFloat: EventGetFloatValue

    static let shared: HIDFunctions? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }

        func symbol<T>(_ name: String) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard
            let create: ClientCreate = symbol("IOHIDEventSystemClientCreate"),
            let setMatching: ClientSetMatching = symbol("IOHIDEventSystemClientSetMatching"),
            let copyServices: ClientCopyServices = symbol("IOHIDEventSystemClientCopyServices"),
            let copyEvent: ServiceCopyEvent = symbol("IOHIDServiceClientCopyEvent"),
            let copyProperty: ServiceCopyProperty = symbol("IOHIDServiceClientCopyProperty"),
            let getFloat: EventGetFloatValue = symbol("IOHIDEventGetFloatValue")
        else {
            return nil
        }

        return HIDFunctions(
            create: create,
            setMatching: setMatching,
            copyServices: copyServices,
            copyEvent: copyEvent,
            copyProperty: copyProperty,
            getFloat: getFloat
        )
    }()
}
