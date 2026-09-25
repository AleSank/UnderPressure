import Foundation

/// Exponential moving average weighted by the real elapsed time, so it behaves the same
/// whatever the sampling interval (3.0 s calm, 1.5 s active).
///
/// Used for sustained CPU and GPU load: a spike of a few seconds barely moves it, while
/// a load that lasts about one time constant reaches ≈ 63% of its value.
nonisolated struct SustainedAverage {
    let timeConstant: TimeInterval
    private(set) var value: Double?
    private var lastUpdate: TimeInterval?

    init(timeConstant: TimeInterval) {
        self.timeConstant = timeConstant
    }

    /// Folds in `sample` taken at `now` (seconds on a monotonic clock). The first sample
    /// seeds the average; a `nil` sample, or one with no elapsed time, leaves it untouched.
    mutating func add(_ sample: Double?, at now: TimeInterval) {
        guard let sample else { return }
        guard let value, let lastUpdate else {
            self.value = sample
            self.lastUpdate = now
            return
        }
        guard now > lastUpdate else { return }
        self.lastUpdate = now
        let weight = 1 - exp(-(now - lastUpdate) / timeConstant)
        self.value = value + (sample - value) * weight
    }
}
