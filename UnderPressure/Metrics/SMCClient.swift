import Foundation
import IOKit

/// Minimal AppleSMC user-client reader (`flt ` / `sp78` keys).
///
/// Uses the classic 80-byte `SMCKeyData` layout with IOConnect method index 2.
/// Resolve a key once with `keyInfo(_:)`, then read it every tick with
/// `readCelsius(_:)` (one IOConnect call instead of two). Missing keys return `nil`.
///
/// Known consumers:
/// - Apple Silicon GPU diode: `Tg0D` (`flt `) — verified M3 Pro
/// - Intel CPU package: `TC0P` / `TC0D` / `TC0E` / … (`sp78` typical)
/// - Intel/AMD GPU: `TG0D` / `TG0P` / …
final class SMCClient {
    /// Resolved key metadata; cache it and pass it to `readCelsius(_:)`.
    struct KeyInfo {
        let key: UInt32
        let size: UInt32
        let type: UInt32
    }

    private static let kernelIndexSMC: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let structSize = 80
    private static let typeFloat = fourCC("flt ")
    private static let typeSP78 = fourCC("sp78")

    private enum Offset {
        static let key = 0
        static let keyInfoDataSize = 28
        static let keyInfoDataType = 32
        static let result = 40
        static let data8 = 42
        static let bytes = 48
    }

    private let connection: io_connect_t
    /// Reused call buffers — avoids two heap allocations per SMC call.
    private var input = [UInt8](repeating: 0, count: SMCClient.structSize)
    private var output = [UInt8](repeating: 0, count: SMCClient.structSize)

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

    /// Size/type for a four-character key, or `nil` when the key is absent or not a
    /// temperature encoding this reader understands.
    func keyInfo(_ key: String) -> KeyInfo? {
        guard key.utf8.count == 4 else { return nil }
        let code = Self.fourCC(key)

        prepare(key: code, command: Self.cmdReadKeyInfo)
        guard call() else { return nil }

        let size = readUInt32(at: Offset.keyInfoDataSize)
        let type = readUInt32(at: Offset.keyInfoDataType)
        guard size > 0, size <= 32, type == Self.typeFloat || type == Self.typeSP78 else {
            return nil
        }
        return KeyInfo(key: code, size: size, type: type)
    }

    /// Current Celsius value for a resolved key, filtered to a plausible range.
    func readCelsius(_ info: KeyInfo) -> Double? {
        prepare(key: info.key, command: Self.cmdReadBytes)
        writeUInt32(info.size, at: Offset.keyInfoDataSize)
        guard call() else { return nil }

        let celsius: Double
        let start = Offset.bytes
        switch info.type {
        case Self.typeFloat:
            guard info.size >= 4 else { return nil }
            celsius = Double(Float(bitPattern: readUInt32(at: start)))
        case Self.typeSP78:
            guard info.size >= 2 else { return nil }
            celsius = Double(Int8(bitPattern: output[start])) + Double(output[start + 1]) / 256.0
        default:
            return nil
        }
        guard celsius.isFinite, celsius > -20, celsius < 120 else { return nil }
        return celsius
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

    /// Host-endian field read; for `flt ` payloads the SMC also returns host order.
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
}
