import Foundation
import IOKit

/// CPU / GPU temperature for the menu (display only: stress uses the thermal state).
///
/// Sources, first that answers wins:
/// - **CPU:** IOHID core sensors (`pACC`/`eACC MTR`, M1/M2) → SMC core keys for this chip
///   (`TemperatureKeys`) → IOHID die sensors (`PMU tdie`…, last resort).
/// - **GPU:** IOHID `GPU MTR` sensors (M1/M2) → SMC GPU keys for this chip → any SMC
///   `Tg…` key (last resort for Apple Silicon chips newer than the tables).
///
/// Groups report the **average** of their plausible sensors, like Stats: robust to a
/// single odd key, and what "CPU temperature" means for a multi-core chip. Intel's SMC
/// uses its first package/proximity key instead. The HID client, its classified services
/// and the working SMC keys are resolved once and cached; rediscovery is rate-limited.
/// Missing sensors return `nil`; callers show `—`. Never traps on absent keys.
final class TemperatureReader {
    private let hid = HIDTemperatureSensors()
    private let smc: SMCClient?
    private var cpuSMC: SMCKeyGroup
    private var gpuSMC: SMCKeyGroup
    private var gpuDiscovery: SMCKeyGroup

    init(smc: SMCClient?, chip: TemperatureKeys.Chip = TemperatureKeys.current) {
        self.smc = smc
        let firstKeyOnly = TemperatureKeys.prefersFirstKey(for: chip)
        cpuSMC = SMCKeyGroup(keys: { _ in TemperatureKeys.cpu(for: chip) }, firstKeyOnly: firstKeyOnly)
        gpuSMC = SMCKeyGroup(keys: { _ in TemperatureKeys.gpu(for: chip) }, firstKeyOnly: firstKeyOnly)
        gpuDiscovery = SMCKeyGroup(
            keys: { chip == .intel ? [] : $0.keys(withPrefix: TemperatureKeys.appleSiliconGPUPrefix) },
            firstKeyOnly: false
        )
    }

    func sampleCPU() -> Double? {
        if let celsius = hid?.sample(.cpuCores) { return celsius }
        if let smc, let celsius = cpuSMC.read(using: smc) { return celsius }
        return hid?.sample(.dieFallback)
    }

    func sampleGPU() -> Double? {
        if let celsius = hid?.sample(.gpu) { return celsius }
        guard let smc else { return nil }
        return gpuSMC.read(using: smc) ?? gpuDiscovery.read(using: smc)
    }
}

// MARK: - SMC

/// A set of SMC temperature keys read as one value.
///
/// Resolves which keys exist and read plausibly, then reads only those. If none does,
/// re-probing is rate-limited, so Macs without these keys don't pay for failing SMC calls
/// on every read.
private struct SMCKeyGroup {
    /// Candidate keys; a closure so a discovery group can ask the SMC for its key list.
    let keys: (SMCClient) -> [String]
    /// Use only the first plausible key (Intel package sensor) instead of the average.
    let firstKeyOnly: Bool
    private var resolved: [SMCClient.KeyInfo] = []
    private var rescan = RescanGate(interval: 60)

    init(keys: @escaping (SMCClient) -> [String], firstKeyOnly: Bool) {
        self.keys = keys
        self.firstKeyOnly = firstKeyOnly
    }

    mutating func read(using smc: SMCClient) -> Double? {
        if let celsius = average(of: resolved, using: smc) { return celsius }
        guard rescan.shouldAttempt() else { return nil }

        resolved = []
        for key in keys(smc) {
            guard let info = smc.keyInfo(key), smc.readCelsius(info) != nil else { continue }
            resolved.append(info)
            if firstKeyOnly { break }
        }
        return average(of: resolved, using: smc)
    }

    private func average(of keys: [SMCClient.KeyInfo], using smc: SMCClient) -> Double? {
        let readings = keys.compactMap { smc.readCelsius($0) }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }
}

// MARK: - IOHID (private, dlsym)

/// Private `IOHIDEventSystemClient` temperature services, classified by product name
/// (names per Stats' HID list and an M3 Pro).
///
/// Creating an event-system client is expensive and retains kernel resources, so one
/// client lives for the app's lifetime and its services are rediscovered only when
/// every cached sensor of a group stops reporting (rate-limited).
private final class HIDTemperatureSensors {
    enum Group {
        /// Per-core sensors: the real CPU temperature (M1/M2 expose these over HID).
        case cpuCores
        /// Power-manager / SoC die sensors (`PMU tdie…`): cooler than the cores, only used
        /// when nothing better exists (measured on an M3 Pro: 44 °C with cores at 60+ °C).
        case dieFallback
        case gpu
    }

    private static let temperatureEventType: Int64 = 15 // kIOHIDEventTypeTemperature
    private static let temperatureEventField: Int32 = 15 << 16 // IOHIDEventFieldBase(type)

    private static let names: [Group: [String]] = [
        .cpuCores: ["pACC MTR Temp", "eACC MTR Temp", "CPU Die", "core temperature"],
        .dieFallback: ["PMU tdie", "PMGR SOC Die Temp", "SOC MTR Temp", "SOC Die", "die temperature"],
        .gpu: ["GPU MTR Temp", "GPU Die", "GFX Die", "AGX"],
    ]

    private static let deniedSubstrings = [
        "tcal", "tdev", "tvmr", "tcmz", "gas", "battery", "ambient", "nand",
        "ssd", "skin", "palm", "case", "headset", "microphone", "speaker",
    ]

    private let api: HIDFunctions
    private let client: AnyObject
    private var services: [Group: [AnyObject]] = [:]
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

    /// Average plausible reading of the group's sensors.
    func sample(_ group: Group) -> Double? {
        if let celsius = average(of: services[group] ?? []) { return celsius }
        guard !(services[group] ?? []).isEmpty, rescan.shouldAttempt() else { return nil }
        discoverServices()
        return average(of: services[group] ?? [])
    }

    private func average(of services: [AnyObject]) -> Double? {
        let readings = services.compactMap { service -> Double? in
            guard let event = api.copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else {
                return nil
            }
            let value = api.getFloat(event, Self.temperatureEventField)
            return SMCClient.plausibleCelsius.contains(value) ? value : nil
        }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    private func discoverServices() {
        services = [:]
        guard let all = api.copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return
        }

        for service in all {
            guard let name = api.copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String
            else {
                continue
            }
            let lower = name.lowercased()
            guard !Self.deniedSubstrings.contains(where: lower.contains) else { continue }
            for (group, candidates) in Self.names
            where candidates.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                services[group, default: []].append(service)
            }
        }
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
