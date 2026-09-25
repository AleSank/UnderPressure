import Foundation
import Testing
@testable import UnderPressure

struct SustainedAverageTests {
    @Test func firstSampleSeedsAndNilIsIgnored() {
        var average = SustainedAverage(timeConstant: 20)
        average.add(nil, at: 0)
        #expect(average.value == nil)
        average.add(10, at: 0)
        #expect(average.value == 10)
        average.add(nil, at: 5)
        #expect(average.value == 10)
    }

    @Test func oneTimeConstantCoversSixtyThreePercent() throws {
        var average = SustainedAverage(timeConstant: 20)
        average.add(0, at: 0)
        average.add(100, at: 20)
        let value = try #require(average.value)
        #expect(abs(value - 100 * (1 - exp(-1))) < 1e-9)
    }

    @Test func resultDoesNotDependOnTheSamplingInterval() throws {
        var slow = SustainedAverage(timeConstant: 20)
        var fast = SustainedAverage(timeConstant: 20)
        slow.add(0, at: 0)
        fast.add(0, at: 0)
        for time in stride(from: 3.0, through: 30, by: 3) { slow.add(100, at: time) }
        for time in stride(from: 1.5, through: 30, by: 1.5) { fast.add(100, at: time) }
        #expect(abs(try #require(slow.value) - (try #require(fast.value))) < 1e-9)
    }

    @Test func sampleWithoutElapsedTimeIsIgnored() throws {
        var average = SustainedAverage(timeConstant: 20)
        average.add(0, at: 0)
        average.add(100, at: 10)
        let before = try #require(average.value)
        average.add(0, at: 10)
        #expect(average.value == before)
    }

    /// The icon promise in the README: amber after about half a minute of full load.
    @Test func fullLoadReachesWarningInAboutThirtySeconds() throws {
        var cpu = SustainedAverage(timeConstant: 20)
        cpu.add(5, at: 0)
        var time = 0.0
        var warningAt: Double?
        while time < 120, warningAt == nil {
            time += 1.5
            cpu.add(100, at: time)
            let stress = UnderPressureScore.finalStress(.init(cpu: 100, cpuSustained: cpu.value))
            if stress >= 53 { warningAt = time }
        }
        let seconds = try #require(warningAt)
        #expect((20...40).contains(seconds))
    }
}
