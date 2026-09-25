import Foundation
import Testing
@testable import UnderPressure

/// Reference cases of the stress formula (see AGENTS.md → Stress engine).
struct StressScoreTests {
    typealias Components = UnderPressureScore.Components

    private func stress(_ components: Components) -> Double {
        UnderPressureScore.finalStress(components)
    }

    @Test func allComponentsAtFifty() {
        let all = Components(
            cpu: 50, cpuSustained: 50, gpu: 50, gpuSustained: 50,
            memoryUsed: 0, memoryPressure: 50, disk: 50
        )
        #expect(stress(all) == 50)
    }

    @Test func missingDataIsCalm() {
        #expect(stress(Components()) == 0)
    }

    @Test func sustainedCPUReachesWarningButNotCritical() {
        #expect(stress(Components(cpu: 100, cpuSustained: 100)) == 70)
    }

    @Test func cpuSpikeOnlyMovesTheLevel() {
        #expect(stress(Components(cpu: 100, cpuSustained: 20)) == 35)
    }

    @Test func gpuBehavesLikeCPU() {
        #expect(stress(Components(gpu: 100, gpuSustained: 100)) == 70)
        #expect(stress(Components(gpu: 100, gpuSustained: 20)) == 35)
    }

    @Test func busyDiskAloneStaysLow() {
        #expect(stress(Components(disk: 100)) == 10)
    }

    @Test(arguments: [
        (used: 70.0, expected: 40.0),
        (used: 83.0, expected: 53.0),
        (used: 90.0, expected: 60.0),
        (used: 100.0, expected: 85.0),
    ])
    func memoryUsedCurve(used: Double, expected: Double) {
        let memory = UnderPressureScore.memoryStress(used: used, pressure: 0)
        #expect(abs(memory - expected) < 0.001)
    }

    @Test func kernelPressureWinsWhenWorse() {
        #expect(UnderPressureScore.memoryStress(used: 60, pressure: 95) == 95)
        #expect(stress(Components(memoryPressure: 60)) == 60)
        #expect(stress(Components(memoryPressure: 90)) == 90)
    }

    @Test func ramAtNinetyPercentAloneIsWarning() {
        #expect(stress(Components(memoryUsed: 90)) == 60)
    }

    @Test func thermalStateOverrides() {
        #expect(stress(Components(cpu: 5, thermalState: .serious)) == 75)
        #expect(stress(Components(cpu: 100, cpuSustained: 100, thermalState: .serious)) == 75)
        #expect(stress(Components(thermalState: .critical)) == 100)
        #expect(stress(Components(cpu: 5, thermalState: .fair)) == 5 * UnderPressureScore.cpuWeight)
    }

    @Test func outOfRangeInputsAreClamped() {
        #expect(stress(Components(cpu: 250, cpuSustained: 250)) == 70)
        #expect(stress(Components(cpu: -10, memoryUsed: -5, disk: -1)) == 0)
    }
}
