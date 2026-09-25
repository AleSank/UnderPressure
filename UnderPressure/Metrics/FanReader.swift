import Foundation

/// Fan speeds from the SMC: `FNum` fans, each with `F<n>Ac` (actual RPM) and `F<n>Mx`
/// (maximum RPM); `flt ` on Apple Silicon, `fpe2` on Intel (keys per Stats; verified on an
/// M3 Pro: 2 fans, max 6800 RPM).
///
/// Fanless Macs (MacBook Air…) have no `FNum` or report 0 fans: `sample()` returns `nil`
/// and the menu hides the row. Apple Silicon fans stop at low load, so 0 RPM is a real
/// reading ("Off"), not an error. Display only; read only while the menu is open.
final class FanReader {
    struct Fan: Equatable {
        let rpm: Double
        /// `nil` when the SMC doesn't report a maximum.
        let maxRPM: Double?

        /// Share of the maximum speed, 0…100.
        var percent: Double? {
            maxRPM.flatMap { $0 > 0 ? min(rpm / $0 * 100, 100) : nil }
        }
    }

    private struct Keys {
        let actual: SMCClient.KeyInfo
        let maximum: SMCClient.KeyInfo?
    }

    /// No Mac has more; guards against a garbage `FNum`.
    private static let maxFans = 4
    private static let plausibleRPM: ClosedRange<Double> = 0...20_000

    private let smc: SMCClient?
    /// Keys per fan, resolved on first use (`[]` = no fans).
    private var fans: [Keys]?

    init(smc: SMCClient?) {
        self.smc = smc
    }

    /// One entry per fan, or `nil` when the Mac has no fans or a read fails.
    func sample() -> [Fan]? {
        guard let smc else { return nil }
        let fans = self.fans ?? Self.resolveFans(using: smc)
        self.fans = fans
        guard !fans.isEmpty else { return nil }

        let readings = fans.compactMap { keys -> Fan? in
            guard let rpm = smc.readNumber(keys.actual), Self.plausibleRPM.contains(rpm) else { return nil }
            let maxRPM = keys.maximum.flatMap { smc.readNumber($0) }.flatMap { Self.plausibleRPM.contains($0) ? $0 : nil }
            return Fan(rpm: rpm, maxRPM: maxRPM)
        }
        return readings.count == fans.count ? readings : nil
    }

    private static func resolveFans(using smc: SMCClient) -> [Keys] {
        guard let countKey = smc.keyInfo("FNum"), let count = smc.readNumber(countKey), count >= 1 else {
            return []
        }
        return (0..<min(Int(count), maxFans)).compactMap { index in
            smc.keyInfo("F\(index)Ac").map { Keys(actual: $0, maximum: smc.keyInfo("F\(index)Mx")) }
        }
    }
}
