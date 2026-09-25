import AppKit
import QuartzCore

/// Animates the menubar liquid with Core Animation, decoupled from metric sampling.
///
/// The glyph is a small layer tree inside the status button:
/// ```
/// IconLayerView.layer
/// ├─ liquidLayer (masked by the circle)
/// │  └─ levelLayer   position.y = liquid surface — eased over 0.5 s on each sample
/// │     └─ waveLayer periodic wave strip, translated one wavelength in an endless loop
/// └─ ringLayer       circle stroke
/// ```
/// The wave loop and all transitions run in the system render server, so the app does
/// no per-frame work: it only touches the layers when a new stress value arrives
/// (every 1.5–3 s). Drawing the icon from the app at 20 fps cost ~8% CPU; this costs
/// effectively nothing in-process.
///
/// Energy: every visible layer change makes the WindowServer re-composite the menubar
/// (≈ 0.75% of a core per fps, measured). So the wave only *moves* above the Normal band
/// (stress > 50), in discrete 12 fps steps; in the Normal band it holds its phase and
/// changes only through the per-sample easing. Changes below half a pixel are skipped.
final class LiquidIconAnimator {
    private static let iconSide: CGFloat = 18
    private static let easeDuration: CFTimeInterval = 0.5
    /// Wave steps per second. Every step makes the WindowServer re-composite the menubar.
    private static let frameRate = 12.0
    /// Relative wave-speed change below which the running loop is left untouched.
    private static let speedChangeThreshold = 0.05
    private static let waveAnimationKey = "wave"
    /// Normal-state fill is opaque like a template glyph; warning/critical colors are softened.
    private static let coloredFillAlpha: CGFloat = 0.95
    /// Stress change (percentage points) below which the layers are left untouched:
    /// 1.5% of the ~15.5 pt oval is under half a Retina pixel.
    private static let minVisibleChange = 1.5
    /// Hysteresis around the Normal/Warning boundary (points): the icon turns amber above
    /// 50 + margin and back to neutral below 50 − margin, so stress hovering near 50
    /// doesn't flip the color or start/stop the wave. The 80 boundary is continuous
    /// (same color and speed on both sides), so it needs none.
    private static let bandHysteresis = 3.0

    private let geometry = UnderPressureIconRenderer.geometry(side: LiquidIconAnimator.iconSide)
    private let view = IconLayerView(side: LiquidIconAnimator.iconSide)
    private let ringLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private let liquidLayer = CALayer()
    private let levelLayer = CALayer()
    private let waveLayer = CAShapeLayer()

    private var stress = 0.0
    /// Stress the layers currently show (last value actually applied).
    private var appliedStress: Double?
    private var waveSpeed = 0.0
    /// Past the Normal band (with hysteresis); decides color and wave motion.
    private var isAboveNormal = false

    /// Stress used for color and wave shape: pinned to the side of the 50 boundary the
    /// hysteresis says we are on. The fill level always uses the real stress.
    private var appearanceStress: Double {
        let boundary = StressAppearance.warningStart
        return isAboveNormal ? max(stress, boundary.nextUp) : min(stress, boundary)
    }

    init(button: NSStatusBarButton?) {
        buildLayers()
        if let button {
            view.frame = NSRect(
                x: (button.bounds.width - Self.iconSide) / 2,
                y: (button.bounds.height - Self.iconSide) / 2,
                width: Self.iconSide,
                height: Self.iconSide
            )
            view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            button.addSubview(view)
        }
        view.onAppearanceChange = { [weak self] in
            self?.withoutAnimation { self?.applyColors() }
        }
        withoutAnimation { apply() }
    }

    /// Eases the liquid toward `stress` (0…100): level, wave shape and color over 0.5 s;
    /// the wave loop starts, stops or changes speed without a phase jump.
    func setStress(_ stress: Double) {
        self.stress = min(max(stress, 0), 100)
        if let appliedStress, abs(self.stress - appliedStress) < Self.minVisibleChange {
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.easeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        apply()
        CATransaction.commit()
    }

    // MARK: - Layers

    private func buildLayers() {
        guard let root = view.layer else { return }
        let oval = geometry.oval
        let bounds = CGRect(x: 0, y: 0, width: Self.iconSide, height: Self.iconSide)

        maskLayer.frame = bounds
        maskLayer.path = CGPath(ellipseIn: oval, transform: nil)
        liquidLayer.frame = bounds
        liquidLayer.mask = maskLayer

        levelLayer.anchorPoint = .zero
        levelLayer.bounds = .zero
        levelLayer.addSublayer(waveLayer)
        liquidLayer.addSublayer(levelLayer)

        ringLayer.frame = bounds
        ringLayer.path = CGPath(ellipseIn: oval, transform: nil)
        ringLayer.fillColor = nil
        ringLayer.lineWidth = geometry.lineWidth

        root.addSublayer(liquidLayer)
        root.addSublayer(ringLayer)
    }

    private func apply() {
        appliedStress = stress
        if stress >= StressAppearance.warningStart + Self.bandHysteresis {
            isAboveNormal = true
        } else if stress <= StressAppearance.warningStart - Self.bandHysteresis {
            isAboveNormal = false
        }
        let fill = CGFloat(stress / 100)
        levelLayer.position = CGPoint(x: 0, y: geometry.surfaceY(fill: fill))
        waveLayer.path = wavePath(fill: fill)
        applyColors()
        updateWaveMotion()
    }

    /// Strip one wavelength wider than the oval so the loop translation never shows an edge.
    private func wavePath(fill: CGFloat) -> CGPath {
        UnderPressureIconRenderer.liquidPath(
            minX: geometry.oval.minX,
            maxX: geometry.oval.maxX + geometry.waveLength,
            waveLength: geometry.waveLength,
            amplitude: geometry.waveAmplitude(
                fill: fill,
                amplitudeScale: CGFloat(StressAppearance.amplitudeScale(stress: appearanceStress))
            ),
            choppiness: CGFloat(StressAppearance.choppiness(stress: appearanceStress)),
            depth: geometry.oval.height + 2,
            step: geometry.scale * 0.5
        )
    }

    private func applyColors() {
        let tint = StressAppearance.color(stress: appearanceStress)
        let color = resolved(tint ?? .labelColor)
        ringLayer.strokeColor = color
        waveLayer.fillColor = tint == nil ? color : color.copy(alpha: Self.coloredFillAlpha)
    }

    /// Runs the wave loop only above the Normal band; (re)starts it at a new speed or
    /// freezes it, always continuing from the current on-screen phase.
    private func updateWaveMotion() {
        let isRunning = waveLayer.animation(forKey: Self.waveAnimationKey) != nil
        let shouldRun = isAboveNormal
        let speed = StressAppearance.waveSpeed(stress: appearanceStress)
        let offset = waveLayer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0

        guard shouldRun else {
            guard isRunning else { return }
            // Freeze where it is: pin the model value, then drop the loop.
            withoutAnimation {
                waveLayer.setValue(offset, forKeyPath: "transform.translation.x")
            }
            waveLayer.removeAnimation(forKey: Self.waveAnimationKey)
            return
        }
        guard !isRunning || abs(speed - waveSpeed) > waveSpeed * Self.speedChangeThreshold else { return }

        let waveLength = geometry.waveLength
        let duration = 2 * .pi / speed
        let progress = min(max(-offset / waveLength, 0), 1)

        // Discrete steps: the layer only changes `frameRate` times per second, so the
        // WindowServer re-composites the menubar at that rate instead of every display
        // refresh (`preferredFrameRateRange` is not honored for the menubar).
        let steps = max(Int((duration * Self.frameRate).rounded()), 4)
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = (0..<steps).map { -waveLength * CGFloat($0) / CGFloat(steps) }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.timeOffset = Double(progress) * duration
        animation.repeatCount = .infinity
        waveLayer.add(animation, forKey: Self.waveAnimationKey)
        waveSpeed = speed
    }

    /// Dynamic system colors resolve per appearance (light/dark menubar).
    private func resolved(_ color: NSColor) -> CGColor {
        var cgColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cgColor = color.cgColor
        }
        return cgColor
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// Layer host inside the status button: transparent to clicks, and forwards appearance
/// and backing-scale changes so the vector layers stay correctly tinted and crisp.
private final class IconLayerView: NSView {
    var onAppearanceChange: (() -> Void)?

    init(side: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let layer else { return }
        applyContentsScale(window?.backingScaleFactor ?? 2, to: layer)
    }

    /// Shape layers rasterize at `contentsScale`; the default of 1 would blur on Retina.
    private func applyContentsScale(_ scale: CGFloat, to layer: CALayer) {
        layer.contentsScale = scale
        layer.mask.map { applyContentsScale(scale, to: $0) }
        layer.sublayers?.forEach { applyContentsScale(scale, to: $0) }
    }
}
