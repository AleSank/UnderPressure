import Foundation
import IOKit

/// Minimal AppleSMC user-client reader (temperatures and fans).
///
/// Uses the classic 80-byte `SMCKeyData` layout with IOConnect method index 2.
/// Resolve a key once with `keyInfo(_:)`, then read it with `readCelsius(_:)` or
/// `readNumber(_:)` (one IOConnect call instead of two). Missing keys return `nil`.
///
/// Decoded types: `flt ` (Apple Silicon), `sp78` (Intel temperatures), `fpe2` (Intel fan
/// speeds), `ui8 ` / `ui16` / `ui32` (counts). Integer and fixed-point payloads are
/// big-endian; `flt ` is little-endian. Key tables per chip live in `TemperatureKeys`.
final class SMCClient {
    /// Resolved key metadata; cache it and pass it to the read functions.
    struct KeyInfo {
        let key: UInt32
        let size: UInt32
        let type: UInt32
    }

    /// Temperatures outside this range are treated as "not a real sensor": some keys hold
    /// constants such as −11 or 0 (measured on an M3 Pro).
    static let plausibleCelsius: ClosedRange<Double> = 10...110

    private static let kernelIndexSMC: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadIndex: UInt8 = 8
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let structSize = 80
    private static let maxPayload: UInt32 = 32
    /// `ui32` key holding the number of keys the SMC exposes.
    private static let keyCountKey = "#KEY"
    /// Sanity cap for the enumeration (real SMCs expose a few thousand keys).
    private static let maxKeyCount = 10_000
    private static let temperatureTypes: Set<String> = ["flt ", "sp78"]

    private enum Offset {
        static let key = 0
        static let keyInfoDataSize = 28
        static let keyInfoDataType = 32
        static let result = 40
        static let data8 = 42
        static let data32 = 44
        static let bytes = 48
    }

    private let connection: io_connect_t
    /// Reused call buffers — avoids two heap allocations per SMC call.
    private var input = [UInt8](repeating: 0, count: SMCClient.structSize)
    private var output = [UInt8](repeating: 0, count: SMCClient.structSize)
    /// Every key the SMC exposes, enumerated once on first use (a few thousand calls).
    private lazy var allKeys: [UInt32] = enumerateKeys()

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS,
              connection != 0
        else {
            return nil
        }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Size/type for a four-character key, or `nil` when the key is absent.
    func keyInfo(_ key: String) -> KeyInfo? {
        guard key.utf8.count == 4 else { return nil }
        let code = Self.fourCC(key)

        prepare(key: code, command: Self.cmdReadKeyInfo)
        guard call() else { return nil }

        let size = readUInt32(at: Offset.keyInfoDataSize)
        guard size > 0, size <= Self.maxPayload else { return nil }
        return KeyInfo(key: code, size: size, type: readUInt32(at: Offset.keyInfoDataType))
    }

    /// Celsius for a temperature-typed key, or `nil` if it isn't one or the reading is
    /// outside `plausibleCelsius`.
    func readCelsius(_ info: KeyInfo) -> Double? {
        guard Self.temperatureTypes.contains(Self.string(fromFourCC: info.type)),
              let celsius = readNumber(info),
              Self.plausibleCelsius.contains(celsius)
        else { return nil }
        return celsius
    }

    /// Value of any supported numeric type (see the type doc above).
    func readNumber(_ info: KeyInfo) -> Double? {
        prepare(key: info.key, command: Self.cmdReadBytes)
        writeUInt32(info.size, at: Offset.keyInfoDataSize)
        guard call() else { return nil }
        let payload = Array(output[Offset.bytes..<(Offset.bytes + Int(info.size))])
        return Self.decode(payload, type: Self.string(fromFourCC: info.type))
    }

    /// Keys starting with `prefix` (case-sensitive), e.g. `Tg` for Apple Silicon GPU sensors.
    /// The first call enumerates the whole SMC (tens of ms); later calls are cached.
    func keys(withPrefix prefix: String) -> [String] {
        allKeys.map(Self.string(fromFourCC:)).filter { $0.hasPrefix(prefix) }
    }

    /// Decodes an SMC payload of the given four-character type (pure, unit tested).
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        func bigEndian(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = bytes.prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            value = Double(Float(bitPattern: bits))
        case "sp78":
            guard let raw = bigEndian(2) else { return nil }
            value = Double(Int16(bitPattern: UInt16(raw))) / 256
        case "fpe2":
            guard let raw = bigEndian(2) else { return nil }
            value = Double(raw) / 4
        case "ui8 ":
            guard let raw = bigEndian(1) else { return nil }
            value = Double(raw)
        case "ui16":
            guard let raw = bigEndian(2) else { return nil }
            value = Double(raw)
        case "ui32":
            guard let raw = bigEndian(4) else { return nil }
            value = Double(raw)
        default:
            return nil
        }
        return value.isFinite ? value : nil
    }

    // MARK: - Enumeration

    private func enumerateKeys() -> [UInt32] {
        guard let countInfo = keyInfo(Self.keyCountKey), let total = readNumber(countInfo) else { return [] }
        let count = min(Int(total), Self.maxKeyCount)

        var keys: [UInt32] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            prepare(key: 0, command: Self.cmdReadIndex)
            writeUInt32(UInt32(index), at: Offset.data32)
            guard call() else { continue }
            keys.append(readUInt32(at: Offset.key))
        }
        return keys
    }

    // MARK: - Struct I/O

    private func prepare(key: UInt32, command: UInt8) {
        for index in input.indices {
            input[index] = 0
        }
        writeUInt32(key, at: Offset.key)
        input[Offset.data8] = command
    }

    /// Performs the struct call; `true` only when both IOKit and the SMC report success.
    private func call() -> Bool {
        var outSize = Self.structSize
        let result = input.withUnsafeBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                IOConnectCallStructMethod(
                    connection,
                    Self.kernelIndexSMC,
                    inRaw.baseAddress,
                    Self.structSize,
                    outRaw.baseAddress,
                    &outSize
                )
            }
        }
        return result == KERN_SUCCESS && output[Offset.result] == 0
    }

    /// Host-endian field write (the struct is passed through to the kernel as-is).
    private func writeUInt32(_ value: UInt32, at offset: Int) {
        withUnsafeBytes(of: value) { raw in
            for index in 0..<4 {
                input[offset + index] = raw[index]
            }
        }
    }

    /// Host-endian struct field read (key codes, sizes, types).
    private func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { raw in
            for index in 0..<4 {
                raw[index] = output[offset + index]
            }
        }
        return value
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func string(fromFourCC code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
