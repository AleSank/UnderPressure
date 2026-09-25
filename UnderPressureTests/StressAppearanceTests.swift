import AppKit
import Testing
@testable import UnderPressure

struct StressAppearanceTests {
    @Test func normalBandUsesTheMenubarColorAndStillWaves() {
        #expect(StressAppearance.color(stress: 0) == nil)
        #expect(StressAppearance.color(stress: 50) == nil)
        #expect(StressAppearance.choppiness(stress: 30) == 0)
        #expect(StressAppearance.amplitudeScale(stress: 30) == 1)
    }

    @Test func warningAndCriticalAreTinted() throws {
        let amber = try #require(StressAppearance.color(stress: 50.5))
        let red = try #require(StressAppearance.color(stress: 100))
        #expect(amber.greenComponent > red.greenComponent)
        #expect(red.redComponent == 1)
    }

    /// The 80 boundary must be continuous, or the icon would jump there.
    @Test func criticalBoundaryIsContinuous() throws {
        let below = try #require(StressAppearance.color(stress: 79.999))
        let above = try #require(StressAppearance.color(stress: 80.001))
        #expect(abs(below.greenComponent - above.greenComponent) < 0.001)
        #expect(abs(StressAppearance.waveSpeed(stress: 79.999) - StressAppearance.waveSpeed(stress: 80.001)) < 0.001)
    }

    @Test func wavesGetFasterAndChoppierWithStress() {
        let levels = stride(from: 50.0, through: 100, by: 5).map { $0 }
        let speeds = levels.map { StressAppearance.waveSpeed(stress: $0) }
        let choppiness = levels.map { StressAppearance.choppiness(stress: $0) }
        #expect(speeds == speeds.sorted())
        #expect(choppiness == choppiness.sorted())
    }
}
