import Foundation

/// Samples CPU / GPU / RAM / disk / temperatures on an adaptive clock and computes the
/// final hardware stress (see `UnderPressureScore`).
///
/// Only what the stress needs is read on every tick (a few µs each). Display-only values
/// — temperatures (up to ≈ 17 ms), fan speeds and the top apps — are read only while the
/// menu is open (`showsMenuDetails`).
///
/// Adaptive polling: every 3.0 s while calm, every 1.5 s while active (stress ≥ 50% or a
/// thermal state above nominal). The UI subscribes via `onUpdate`; the icon animation
/// runs on its own clock (`LiquidIconAnimator`).
final class UnderPressureMonitor {
    private(set) var cpuPercent: Double?
    private(set) var gpuPercent: Double?
    /// RAM used % (Activity Monitor "Memory Used": app + wired + compressed).
    private(set) var memoryUsedPercent: Double?
    /// Kernel memory pressure as banded stress (`MemoryPressureReader`).
    private(set) var memoryPressure: Double?
    /// Memory's share of stress: the worse of RAM used and kernel pressure.
    private(set) var memoryStress: Double?
    private(set) var diskPercent: Double?
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    // Menu-only values, sampled while `showsMenuDetails` is on.

    private(set) var cpuTemperature: Double?
    private(set) var gpuTemperature: Double?
    /// One entry per fan; `nil` on fanless Macs.
    private(set) var fans: [FanReader.Fan]?
    private(set) var lastError: String?
    /// Heaviest apps (up to `topAppCount`, unfiltered: the menu decides what is worth
    /// showing).
    private(set) var topCPUApps: [AppUsage] = []
    private(set) var topMemoryApp: AppUsage?

    /// Final hardware stress, 0…100.
    private(set) var stress: Double = 0

    /// Invoked on the main thread after every sample.
    var onUpdate: (() -> Void)?

    /// Set while the menu is open: menu-only values are sampled right away and on every
    /// tick, plus once shortly after opening so the top apps don't wait a full interval.
    var showsMenuDetails = false {
        didSet {
            guard showsMenuDetails != oldValue else { return }
            if showsMenuDetails {
                sampleMenuDetails()
                scheduleDetailsRefresh()
            } else {
                appsReader.reset()
                topCPUApps = []
                topMemoryApp = nil
            }
        }
    }

    private var cpuReader = CPUReader()
    private let gpuReader = GPUReader()
    private let memoryReader = MemoryReader()
    private let pressureReader = MemoryPressureReader()
    private let diskReader = DiskReader()
    private let temperatureReader: TemperatureReader
    private let fanReader: FanReader
    private var appsReader = TopAppsReader()

    private var timer: Timer?
    private var cpuSustained = SustainedAverage(timeConstant: sustainedTimeConstant)
    private var gpuSustained = SustainedAverage(timeConstant: sustainedTimeConstant)

    // MARK: - Adaptive clock

    private static let normalInterval: TimeInterval = 3.0
    private static let activeInterval: TimeInterval = 1.5
    private static let activeStressThreshold = 50.0
    /// Share of the whole CPU (%) from which an app is revealed in the menu.
    static let topAppThreshold = 35.0
    /// At most this many apps can each hold `topAppThreshold` of the CPU.
    static let topAppCount = Int(100 / topAppThreshold)
    /// Time constant of the sustained CPU/GPU loads (s): spikes of a few seconds barely
    /// move them; full load reaches ≈ 76% (stress 53, Warning) in ≈ 30 s.
    private static let sustainedTimeConstant: TimeInterval = 20
    /// Delay of the first top-CPU reading after the menu opens.
    private static let detailsWarmUp: TimeInterval = 0.75

    init() {
        // One SMC connection shared by temperatures and fans.
        let smc = SMCClient()
        temperatureReader = TemperatureReader(smc: smc)
        fanReader = FanReader(smc: smc)
    }

    func start() {
        guard timer == nil else { return }
        tick()
    }

    private var desiredInterval: TimeInterval {
        let isActive = stress >= Self.activeStressThreshold || thermalState != .nominal
        return isActive ? Self.activeInterval : Self.normalInterval
    }

    /// (Re)schedules the sampling timer only when the interval actually changes.
    private func scheduleTimer() {
        let interval = desiredInterval
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Scheduled on the main run loop, so the callback is already main-isolated.
            MainActor.assumeIsolated {
                self.tick()
            }
        }
        // Tolerance lets macOS coalesce wake-ups (energy); `.common` keeps the
        // timer firing while the status menu is tracking.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One-shot: CPU share per app needs two walks, so take the second one soon.
    private func scheduleDetailsRefresh() {
        let timer = Timer(timeInterval: Self.detailsWarmUp, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.showsMenuDetails else { return }
                self.sampleTopApps()
                self.onUpdate?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Sampling

    private func tick() {
        // Delta-based readers (CPU, disk) measure over the elapsed interval, whatever it is.
        let now = ProcessInfo.processInfo.systemUptime
        cpuPercent = cpuReader.sample() ?? cpuPercent
        cpuSustained.add(cpuPercent, at: now)

        // Best-effort: keep last GPU % if this tick returns nil (Intel integrated can flicker).
        gpuPercent = gpuReader.sample() ?? gpuPercent
        gpuSustained.add(gpuPercent, at: now)

        memoryUsedPercent = memoryReader.sample()
        memoryPressure = pressureReader.sample()
        memoryStress = UnderPressureScore.memoryStress(used: memoryUsedPercent, pressure: memoryPressure)
        diskPercent = diskReader.sample() ?? diskPercent
        thermalState = ProcessInfo.processInfo.thermalState

        stress = UnderPressureScore.finalStress(.init(
            cpu: cpuPercent,
            cpuSustained: cpuSustained.value,
            gpu: gpuPercent,
            gpuSustained: gpuSustained.value,
            memoryUsed: memoryUsedPercent,
            memoryPressure: memoryPressure,
            disk: diskPercent,
            thermalState: thermalState
        ))

        if showsMenuDetails {
            sampleMenuDetails()
        }

        scheduleTimer()
        onUpdate?()
    }

    private func sampleMenuDetails() {
        cpuTemperature = temperatureReader.sampleCPU() ?? cpuTemperature
        gpuTemperature = temperatureReader.sampleGPU() ?? gpuTemperature
        fans = fanReader.sample()
        let sensorsMissing = cpuTemperature == nil && gpuTemperature == nil && gpuPercent == nil
        lastError = sensorsMissing ? "Some sensors unavailable on this Mac" : nil
        sampleTopApps()
    }

    private func sampleTopApps() {
        let top = appsReader.sample(count: Self.topAppCount)
        if top.hasCPUDelta {
            topCPUApps = top.cpu
        }
        topMemoryApp = top.memory
    }
}
