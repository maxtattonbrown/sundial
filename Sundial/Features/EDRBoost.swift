// ABOUTME: The headline feature — pushes the panel past its SDR brightness cap by requesting EDR
// ABOUTME: headroom, with a right-edge "I'm boosting harder now" indicator that flashes on engage
// ABOUTME: and on intensity step-ups, then fades out so it isn't there the whole time.

import AppKit
import Metal
import QuartzCore

@MainActor
final class EDRBoost {
    private var windows: [NSWindow] = []
    private var contents: [BoostWindowContent] = []
    private let device = MTLCreateSystemDefaultDevice()

    /// Currently-rendered EDR multiplier. Drives the Metal layer clear colour. Set indirectly via
    /// `setEffectiveStrength(_:)` so the indicator flash logic can react to step-ups.
    private(set) var effectiveStrength: Float = 0

    /// "Intensity must rise by at least this much (post-floor) to be worth flashing." Below this
    /// the boost still smoothly animates to the new value; the indicator just doesn't fire so
    /// minor fluctuations aren't distracting.
    private let flashThreshold: Float = 0.3

    func engage() {
        guard windows.isEmpty else { return }
        guard let device else {
            print("[Sundial] No Metal device available — cannot engage EDR boost")
            return
        }

        for screen in NSScreen.screens {
            let (window, content) = makeWindow(for: screen, device: device)
            window.orderFront(nil)
            windows.append(window)
            contents.append(content)
        }
    }

    func disengage() {
        guard !windows.isEmpty else { return }
        let contentsToClose = contents
        let windowsToClose = windows
        contents.removeAll()
        windows.removeAll()
        effectiveStrength = 0

        // Fade EDR strength down over 1.2s — sun-fading-behind-a-cloud feel. Indicator stays
        // silent on disengage (the screen visibly dimming IS the signal).
        for content in contentsToClose {
            content.animate(to: 0.0, over: 1.2, curve: .easeIn)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            for window in windowsToClose {
                window.orderOut(nil)
                window.close()
            }
            _ = self
        }
    }

    /// Set the *currently-rendered* boost intensity. If this is the initial engage (previous = 0)
    /// or a meaningful step-up, the right-edge indicator flashes for ~3s. Smooth animation to the
    /// new value either way.
    func setEffectiveStrength(_ newValue: Float, animationDuration: TimeInterval = 0.5) {
        guard !contents.isEmpty else { return }
        let oldValue = effectiveStrength
        effectiveStrength = newValue

        // First-time engage: longer fade-in (matches the original sun-from-cloud feel).
        let duration: TimeInterval = (oldValue == 0) ? 0.8 : animationDuration
        let curve: EaseCurve = (oldValue == 0) ? .easeOut : .easeOut

        for content in contents {
            content.animate(to: newValue, over: duration, curve: curve)
        }

        let isInitialEngage = (oldValue == 0 && newValue > 0)
        let isMeaningfulStepUp = (newValue - oldValue) > flashThreshold
        if isInitialEngage || isMeaningfulStepUp {
            for content in contents {
                content.flashIndicator()
            }
        }
    }

    private func makeWindow(for screen: NSScreen, device: MTLDevice) -> (NSWindow, BoostWindowContent) {
        let frame = screen.frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false

        let content = BoostWindowContent(frame: frame, device: device)
        window.contentView = content
        return (window, content)
    }
}

// MARK: - Animation curves

enum EaseCurve {
    case linear, easeIn, easeOut, easeInOut

    func apply(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        switch self {
        case .linear: return clamped
        case .easeIn: return clamped * clamped * clamped
        case .easeOut:
            let inv = 1 - clamped
            return 1 - inv * inv * inv
        case .easeInOut:
            return clamped < 0.5
                ? 4 * clamped * clamped * clamped
                : 1 - pow(-2 * clamped + 2, 3) / 2
        }
    }
}

// MARK: - BoostWindowContent

/// The window's contentView. Wraps the EDR Metal layer (fullscreen) and a right-edge gradient
/// indicator layer that flashes on engage / step-up. Keeping these as sibling layers means we
/// don't need a second Metal pipeline for the indicator — Core Animation handles it.
@MainActor
final class BoostWindowContent: NSView {
    fileprivate let metalView: EDRMetalView
    private let indicatorLayer = CAGradientLayer()

    init(frame: NSRect, device: MTLDevice) {
        self.metalView = EDRMetalView(frame: frame, device: device)
        super.init(frame: frame)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .clear

        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)

        // Right-edge stripe — 6pt wide, ~40% of screen height, vertically centred. Warm
        // sunlight palette, gradient fades to transparent at the top/bottom so it reads as
        // "a beam of light catching the edge" rather than a hard-edged bar.
        indicatorLayer.colors = [
            CGColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.0),
            CGColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1.0),
            CGColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.0),
        ]
        indicatorLayer.locations = [0.0, 0.5, 1.0]
        indicatorLayer.startPoint = CGPoint(x: 0.5, y: 0)
        indicatorLayer.endPoint = CGPoint(x: 0.5, y: 1)
        indicatorLayer.opacity = 0
        indicatorLayer.cornerRadius = 3
        indicatorLayer.shadowColor = CGColor(red: 1.0, green: 0.65, blue: 0.2, alpha: 1.0)
        indicatorLayer.shadowOpacity = 0.7
        indicatorLayer.shadowRadius = 12
        indicatorLayer.shadowOffset = .zero

        positionIndicator()
        layer?.addSublayer(indicatorLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layout() {
        super.layout()
        positionIndicator()
    }

    private func positionIndicator() {
        let stripeHeight = bounds.height * 0.4
        let stripeWidth: CGFloat = 6
        indicatorLayer.frame = CGRect(
            x: bounds.width - stripeWidth - 4,   // 4pt off the right edge for some breathing room
            y: (bounds.height - stripeHeight) / 2,
            width: stripeWidth,
            height: stripeHeight
        )
    }

    // MARK: - Public API used by EDRBoost

    func animate(to target: Float, over duration: TimeInterval, curve: EaseCurve) {
        metalView.animate(to: target, over: duration, curve: curve)
    }

    /// Fade in 400ms → hold 2s → fade out 800ms. Replaces any in-progress flash.
    func flashIndicator() {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 1.0, 0.0]
        anim.keyTimes = [0.0, 0.125, 0.875, 1.0]   // 0.4/3.2, then 2.4/3.2, then 1.0
        anim.duration = 3.2
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn),
        ]
        indicatorLayer.opacity = 0   // model layer ends at 0; presentation drives the animation
        indicatorLayer.add(anim, forKey: "flash")
    }
}

// MARK: - EDRMetalView

@MainActor
final class EDRMetalView: NSView {
    private let metalLayer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue?
    private var redrawTimer: Timer?

    private var currentStrength: Float = 0
    private var startStrength: Float = 0
    private var targetStrength: Float = 0
    private var animationStart: Date?
    private var animationDuration: TimeInterval = 0
    private var animationCurve: EaseCurve = .easeOut

    private let alpha: Float = 0.05

    init(frame: NSRect, device: MTLDevice) {
        self.commandQueue = device.makeCommandQueue()
        super.init(frame: frame)

        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        metalLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        layer = metalLayer

        DispatchQueue.main.async { [weak self] in
            self?.render()
            self?.startIdleTimer()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        redrawTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
        render()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        render()
    }

    func animate(to target: Float, over duration: TimeInterval, curve: EaseCurve = .easeOut) {
        startStrength = currentStrength
        targetStrength = target
        animationStart = Date()
        animationDuration = duration
        animationCurve = curve
        startAnimationTimer()
    }

    // MARK: - Timer management

    private func startIdleTimer() {
        redrawTimer?.invalidate()
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    private func startAnimationTimer() {
        redrawTimer?.invalidate()
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.animationFrame() }
        }
    }

    private func animationFrame() {
        guard let start = animationStart else {
            startIdleTimer()
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= animationDuration {
            currentStrength = targetStrength
            animationStart = nil
            render()
            startIdleTimer()
            return
        }
        let t = elapsed / animationDuration
        let eased = animationCurve.apply(t)
        currentStrength = startStrength + (targetStrength - startStrength) * Float(eased)
        render()
    }

    // MARK: - Drawing

    private func render() {
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        let premulRGB = Double(currentStrength)
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red:   premulRGB,
            green: premulRGB,
            blue:  premulRGB,
            alpha: Double(alpha)
        )
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
