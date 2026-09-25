import CoreGraphics
import Testing
@testable import UnderPressure

/// Shared glyph geometry used by the menubar icon and the app icon (`Tools/AppIcon`).
struct IconGeometryTests {
    /// Menubar size with its default stroke, and the app icon's glyph size and stroke.
    @Test(arguments: [(side: 18.0, lineWidth: nil as Double?), (side: 560.0, lineWidth: 34.0)])
    func ringStaysInsideTheCanvas(side: Double, lineWidth: Double?) {
        let geometry = UnderPressureIconRenderer.geometry(side: side, lineWidth: lineWidth.map { CGFloat($0) })
        let outer = geometry.oval.insetBy(dx: -geometry.lineWidth / 2, dy: -geometry.lineWidth / 2)
        #expect(outer.minX >= 0 && outer.minY >= 0)
        #expect(outer.maxX <= side && outer.maxY <= side)
    }

    @Test func proportionsScaleUniformly() {
        let menubar = UnderPressureIconRenderer.geometry(side: 18)
        let large = UnderPressureIconRenderer.geometry(side: 180)
        #expect(abs(large.oval.width / 180 - menubar.oval.width / 18) < 0.0001)
        #expect(abs(large.waveLength / 180 - menubar.waveLength / 18) < 0.0001)
    }

    @Test func levelSpansTheOvalWithAVisibleMinimum() {
        let geometry = UnderPressureIconRenderer.geometry(side: 18)
        #expect(geometry.surfaceY(fill: 0) == geometry.oval.minY + geometry.scale)
        #expect(geometry.surfaceY(fill: 1) == geometry.oval.maxY)
        #expect(geometry.surfaceY(fill: 0.25) < geometry.surfaceY(fill: 0.75))
    }

    @Test func surfaceFlattensWhenEmptyOrFull() {
        let geometry = UnderPressureIconRenderer.geometry(side: 18)
        #expect(geometry.waveAmplitude(fill: 0, amplitudeScale: 1) == 0)
        #expect(geometry.waveAmplitude(fill: 1, amplitudeScale: 1) == 0)
        #expect(geometry.waveAmplitude(fill: 0.5, amplitudeScale: 1) > 0)
    }
}
