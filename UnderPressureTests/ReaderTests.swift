import Foundation
import Testing
@testable import UnderPressure

/// Live readings on the test machine: every reader must return a plausible value or
/// `nil`, never trap or produce out-of-range numbers.
struct ReaderTests {
    @Test func cpuNeedsTwoSamplesThenReportsAPercentage() async throws {
        var reader = CPUReader()
        #expect(reader.sample() == nil)
        try await Task.sleep(for: .milliseconds(200))
        if let percent = reader.sample() {
            #expect((0...100).contains(percent))
        }
    }

    @Test func memoryUsedIsAPercentage() throws {
        let percent = try #require(MemoryReader().sample())
        #expect(percent > 0 && percent <= 100)
    }

    @Test func memoryPressureIsBanded() throws {
        let pressure = try #require(MemoryPressureReader().sample())
        #expect((0...100).contains(pressure))
    }

    @Test func optionalHardwareStaysInRange() {
        if let gpu = GPUReader().sample() { #expect((0...100).contains(gpu)) }
        let temperatures = TemperatureReader()
        for celsius in [temperatures.sampleCPU(), temperatures.sampleGPU()].compactMap({ $0 }) {
            #expect(celsius > -20 && celsius < 120)
        }
    }

    @Test(arguments: [
        ("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", "Google Chrome"),
        ("/Applications/Xcode.app/Contents/Developer/usr/bin/clang", "Xcode"),
        ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "Finder"),
        ("/usr/bin/yes", nil),
    ])
    func processesAreGroupedByOutermostApp(path: String, app: String?) {
        #expect(TopAppsReader.bundleName(in: path) == app)
    }
}
