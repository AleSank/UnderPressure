import AppKit

/// Visual mapping from final stress (0…100) to the liquid glyph.
///
/// | Stress   | State    | Color                          | Waves                |
/// |----------|----------|--------------------------------|----------------------|
/// | 0–50     | Normal   | Template (menubar white/black) | calm, smooth         |
/// | 50–80    | Warning  | amber → orange                 | faster, choppier     |
/// | 80–100   | Critical | orange → solid red             | fastest, most choppy |
///
/// The fill level is the stress itself (`stress / 100`).
enum StressAppearance {
    static let warningStart = 50.0
    static let criticalStart = 80.0

    private static let amber = (r: 1.00, g: 0.74, b: 0.00)
    private static let orange = (r: 1.00, g: 0.50, b: 0.00)
    private static let red = (r: 1.00, g: 0.22, b: 0.18)

    /// Radians per second of the wave phase.
    private static let calmSpeed = 1.2
    private static let warningSpeed = 3.5
    private static let criticalSpeed = 6.5

    /// `nil` means "normal": use the menubar's own label color, like a template icon.
    static func color(stress: Double) -> NSColor? {
        if stress <= warningStart { return nil }
        let (from, to, t) = stress <= criticalStart
            ? (amber, orange, progress(stress, warningStart, criticalStart))
            : (orange, red, progress(stress, criticalStart, 100))
        return NSColor(
            srgbRed: from.r + (to.r - from.r) * t,
            green: from.g + (to.g - from.g) * t,
            blue: from.b + (to.b - from.b) * t,
            alpha: 1
        )
    }

    static func waveSpeed(stress: Double) -> Double {
        piecewise(stress, calm: calmSpeed, warning: warningSpeed, critical: criticalSpeed)
    }

    /// 0 = single smooth sine; 1 = strong second harmonic (choppy surface).
    static func choppiness(stress: Double) -> Double {
        piecewise(stress, calm: 0, warning: 0.6, critical: 1)
    }

    /// Multiplier on the reference wave amplitude.
    static func amplitudeScale(stress: Double) -> Double {
        piecewise(stress, calm: 1, warning: 1.3, critical: 1.5)
    }

    /// Constant `calm` up to 50, ramps to `warning` at 80, then to `critical` at 100.
    private static func piecewise(_ stress: Double, calm: Double, warning: Double, critical: Double) -> Double {
        if stress <= warningStart { return calm }
        if stress <= criticalStart {
            return calm + (warning - calm) * progress(stress, warningStart, criticalStart)
        }
        return warning + (critical - warning) * progress(stress, criticalStart, 100)
    }

    private static func progress(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max((value - lower) / (upper - lower), 0), 1)
    }
}

/// Shared geometry of the UnderPressure glyph — a circle filled from the bottom like a liquid.
///
/// The menubar icon (animated Core Animation layers, `LiquidIconAnimator`) and the app
/// icon (`Tools/AppIcon`, also shown in the About panel) both build their shapes from
/// these functions, so they can never drift apart. Geometry is defined for the 18 pt menubar size and scaled
/// uniformly; only the stroke can be overridden, and the oval inset follows it.
enum UnderPressureIconRenderer {
    /// Menubar canvas size — source of truth for proportions.
    static let referenceSide: CGFloat = 18
    /// Inset of the oval from the canvas edge at reference size.
    static let referenceInset: CGFloat = 1.25
    /// Stroke width at reference size.
    static let referenceLineWidth: CGFloat = 1.6
    /// Calm wave crest height at reference size (≈ 1.5 px on a Retina menubar).
    static let referenceWaveAmplitude: CGFloat = 0.75
    /// Wavelength as a fraction of the oval width (a bit less than one full wave).
    static let waveLengthFraction: CGFloat = 0.9
    /// Weight of the second harmonic at full choppiness.
    static let harmonicWeight: CGFloat = 0.45

    struct Geometry {
        let scale: CGFloat
        let lineWidth: CGFloat
        let oval: CGRect

        var waveLength: CGFloat { oval.width * UnderPressureIconRenderer.waveLengthFraction }

        /// Absolute y of the liquid surface. A minimum level keeps a low load visible.
        func surfaceY(fill: CGFloat) -> CGFloat {
            oval.minY + min(max(oval.height * clampedFill(fill), scale), oval.height)
        }

        /// Crest height, flattened near empty/full so 0% and 100% still read as flat.
        func waveAmplitude(fill: CGFloat, amplitudeScale: CGFloat) -> CGFloat {
            let fill = clampedFill(fill)
            let taper = min(1, fill * 6, (1 - fill) * 6)
            return UnderPressureIconRenderer.referenceWaveAmplitude * scale * amplitudeScale * taper
        }

        private func clampedFill(_ fill: CGFloat) -> CGFloat {
            min(max(fill, 0), 1)
        }
    }

    static func geometry(side: CGFloat, lineWidth: CGFloat? = nil) -> Geometry {
        let scale = side / referenceSide
        let lineWidth = lineWidth ?? referenceLineWidth * scale
        let inset = lineWidth * (referenceInset / referenceLineWidth)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return Geometry(scale: scale, lineWidth: lineWidth, oval: bounds.insetBy(dx: inset, dy: inset))
    }

    /// Liquid body under a wavy surface centered on y = 0, filled down to `-depth`.
    ///
    /// The surface is periodic in x with `waveLength` (fundamental + 2nd harmonic), so a
    /// strip spanning one extra wavelength can be translated by exactly one wavelength and
    /// loop seamlessly. Point count depends only on the x-range, so paths built for
    /// different amplitudes interpolate cleanly when animated.
    static func liquidPath(
        minX: CGFloat,
        maxX: CGFloat,
        waveLength: CGFloat,
        amplitude: CGFloat,
        choppiness: CGFloat,
        depth: CGFloat,
        step: CGFloat
    ) -> CGPath {
        let waveNumber = 2 * .pi / waveLength
        let harmonic = choppiness * harmonicWeight

        func surface(_ x: CGFloat) -> CGFloat {
            let u = waveNumber * (x - minX)
            return amplitude * (sin(u) + harmonic * sin(2 * u + 1.3))
        }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX, y: -depth))
        var x = minX
        while x < maxX {
            path.addLine(to: CGPoint(x: x, y: surface(x)))
            x += step
        }
        path.addLine(to: CGPoint(x: maxX, y: surface(maxX)))
        path.addLine(to: CGPoint(x: maxX, y: -depth))
        path.closeSubpath()
        return path
    }
}
