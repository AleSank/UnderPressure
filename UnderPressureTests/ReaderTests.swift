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
        let temperatures = TemperatureReader(smc: SMCClient())
        for celsius in [temperatures.sampleCPU(), temperatures.sampleGPU()].compactMap({ $0 }) {
            #expect(SMCClient.plausibleCelsius.contains(celsius))
        }
    }

    /// GPU temperature discovery on unknown chips relies on enumerating SMC keys.
    @Test func smcExposesTemperatureKeys() {
        guard let smc = SMCClient() else { return }
        let keys = smc.keys(withPrefix: "T")
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { $0.utf8.count == 4 && $0.hasPrefix("T") })
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

struct SMCDecodingTests {
    @Test func decodesEveryType() {
        // Measured on an M3 Pro: F0Mn = 2317 rpm as little-endian `flt `.
        #expect(SMCClient.decode([0x00, 0xD0, 0x10, 0x45], type: "flt ") == 2317)
        // `sp78`: signed 8.8 fixed point, big-endian (45.5 °C).
        #expect(SMCClient.decode([0x2D, 0x80], type: "sp78") == 45.5)
        #expect(SMCClient.decode([0xFF, 0x00], type: "sp78") == -1)
        // `fpe2`: unsigned 14.2 fixed point, big-endian (Intel fans: 1800 rpm).
        #expect(SMCClient.decode([0x1C, 0x20], type: "fpe2") == 1800)
        #expect(SMCClient.decode([2], type: "ui8 ") == 2)
        #expect(SMCClient.decode([0x01, 0x00], type: "ui16") == 256)
        #expect(SMCClient.decode([0x00, 0x00, 0x09, 0xC4], type: "ui32") == 2500)
    }

    @Test func rejectsShortPayloadsAndUnknownTypes() {
        #expect(SMCClient.decode([0x00, 0xD0], type: "flt ") == nil)
        #expect(SMCClient.decode([], type: "ui8 ") == nil)
        #expect(SMCClient.decode([1, 2, 3, 4], type: "ch8*") == nil)
    }
}

struct TemperatureKeysTests {
    @Test(arguments: [
        ("Apple M1", TemperatureKeys.Chip.appleSilicon(generation: 1)),
        ("Apple M2", .appleSilicon(generation: 2)),
        ("Apple M3 Pro", .appleSilicon(generation: 3)),
        ("Apple M4 Max", .appleSilicon(generation: 4)),
        ("Apple M5", .appleSilicon(generation: 5)),
        ("Apple M12 Ultra", .appleSilicon(generation: 12)),
        ("Apple A18 Pro", .appleA18Pro),
        ("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", .intel),
        ("", .unknown),
    ])
    func chipFromBrandString(brand: String, chip: TemperatureKeys.Chip) {
        #expect(TemperatureKeys.chip(brand: brand) == chip)
    }

    @Test func everyChipHasCPUAndGPUKeys() {
        let chips: [TemperatureKeys.Chip] = [
            .appleSilicon(generation: 1), .appleSilicon(generation: 2), .appleSilicon(generation: 3),
            .appleSilicon(generation: 4), .appleSilicon(generation: 5), .appleSilicon(generation: 9),
            .appleA18Pro, .intel, .unknown,
        ]
        for chip in chips {
            #expect(!TemperatureKeys.cpu(for: chip).isEmpty)
            #expect(!TemperatureKeys.gpu(for: chip).isEmpty)
            #expect(TemperatureKeys.cpu(for: chip).allSatisfy { $0.utf8.count == 4 })
        }
    }

    /// A chip newer than the tables gets every Apple Silicon key, without duplicates.
    @Test func unknownAppleSiliconFallsBackToAllTables() {
        let keys = TemperatureKeys.gpu(for: .appleSilicon(generation: 9))
        #expect(keys.contains("Tg0f") && keys.contains("Tf14") && keys.contains("Tg0U"))
        #expect(Set(keys).count == keys.count)
    }

    @Test func thisMacReportsPlausibleTemperatures() {
        let reader = TemperatureReader(smc: SMCClient())
        for celsius in [reader.sampleCPU(), reader.sampleGPU()].compactMap({ $0 }) {
            #expect(SMCClient.plausibleCelsius.contains(celsius))
        }
    }
}

struct FanTests {
    @Test func fanRowMatchesTheOtherRows() {
        let stopped = FanReader.Fan(rpm: 0, maxRPM: 6800)
        #expect(MenuCopy.fanText([stopped, stopped]) == "Fans:\t0%\t· Off")
        #expect(MenuCopy.fanText([FanReader.Fan(rpm: 0.3, maxRPM: 6800)]) == "Fan:\t0%\t· Off")
        #expect(MenuCopy.fanText([FanReader.Fan(rpm: 3400, maxRPM: 6800)]) == "Fan:\t50%\t· 3400 rpm")
        let pair = [FanReader.Fan(rpm: 2300, maxRPM: 6800), FanReader.Fan(rpm: 2334, maxRPM: 6800)]
        #expect(MenuCopy.fanText(pair) == "Fans:\t34%\t· 2317 rpm")
        #expect(MenuCopy.fanText([FanReader.Fan(rpm: 1800, maxRPM: nil)]) == "Fan:\t—\t· 1800 rpm")
    }

    @Test func percentOfMaximumIsClamped() {
        #expect(FanReader.Fan(rpm: 7000, maxRPM: 6800).percent == 100)
        #expect(FanReader.Fan(rpm: 1000, maxRPM: 0).percent == nil)
    }

    @Test func fanReadingsArePlausibleWhenPresent() {
        guard let fans = FanReader(smc: SMCClient()).sample() else { return }
        #expect(!fans.isEmpty)
        #expect(fans.allSatisfy { (0...20_000).contains($0.rpm) && ($0.percent.map { (0...100).contains($0) } ?? true) })
    }
}
