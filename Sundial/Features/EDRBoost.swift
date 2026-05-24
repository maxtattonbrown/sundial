// ABOUTME: The headline feature — pushes the panel past its SDR brightness cap by requesting EDR headroom.
// ABOUTME: For each NSScreen, creates a borderless transparent NSWindow at .screenSaver level hosting a
// ABOUTME: CAMetalLayer with wantsExtendedDynamicRangeContent = true. Engage/disengage are animated
// ABOUTME: with eased curves (800ms in, 1.2s out) so the screen reads as "the sun came out" rather than
// ABOUTME: "an app flicked on a light."

import AppKit
import Metal
import QuartzCore

@MainActor
final class EDRBoost {
    private var windows: [NSWindow] = []
    private var metalViews: [EDRMetalView] = []
    private let device = MTLCreateSystemDefaultDevice()

    /// EDR brightness multiplier (post-premultiplication). Live-tunable while engaged.
    var boostStrength: Float = 2.5 {
        didSet {
            // If currently engaged, glide to the new target rather than snapping.
            if !metalViews.isEmpty {
                metalViews.forEach { $0.animate(to: boostStrength, over: 0.3, curve: .easeOut) }
            }
        }
    }

    func engage() {
        guard windows.isEmpty else { return }
        guard let device else {
            print("[Sundial] No Metal device available — cannot engage EDR boost")
            return
        }

        for screen in NSScreen.screens {
            let (window, view) = makeWindow(for: screen, device: device)
            window.orderFront(nil)
            windows.append(window)
            metalViews.append(view)
            // Fade up from 0 to target over 800ms — feels like sun coming out from behind a cloud.
            view.animate(to: boostStrength, over: 0.8, curve: .easeOut)
        }
    }

    func disengage() {
        guard !windows.isEmpty else { return }
        let viewsToClose = metalViews
        let windowsToClose = windows
        metalViews.removeAll()
        windows.removeAll()

        // Fade down over 1.2s — sun-fading-behind-a-cloud feel is slightly slower than the rise.
        for view in viewsToClose {
            view.animate(to: 0.0, over: 1.2, curve: .easeIn) {
                // No-op per view; we wait for the whole batch to settle below.
            }
        }
        // Close all windows after the fade completes. One timer beats N completion handlers
        // racing each other.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            for window in windowsToClose {
                window.orderOut(nil)
                window.close()
            }
            _ = self  // keep reference until cleanup
        }
    }

    private func makeWindow(for screen: NSScreen, device: MTLDevice) -> (NSWindow, EDRMetalView) {
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

        let metalView = EDRMetalView(frame: frame, device: device)
        window.contentView = metalView
        return (window, metalView)
    }
}

// MARK: - Animation curves

enum EaseCurve {
    case linear, easeIn, easeOut, easeInOut

    /// Apply curve to a normalised t in [0, 1].
    func apply(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        switch self {
        case .linear: return clamped
        case .easeIn: return clamped * clamped * clamped               // cubic in
        case .easeOut:
            // Cubic out — fast start, slow settle. Matches the perceptual shape of sun
            // emerging from cloud cover.
            let inv = 1 - clamped
            return 1 - inv * inv * inv
        case .easeInOut:
            return clamped < 0.5
                ? 4 * clamped * clamped * clamped
                : 1 - pow(-2 * clamped + 2, 3) / 2
        }
    }
}

// MARK: - EDRMetalView

/// NSView backed by a CAMetalLayer configured for EDR. Owns its own redraw timer — runs at
/// 60Hz while animating between strengths, drops to 1Hz when settled (cheap idle).
@MainActor
final class EDRMetalView: NSView {
    private let metalLayer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue?
    private var redrawTimer: Timer?

    /// Value used by the next render() call. Animates toward `targetStrength`.
    private var currentStrength: Float = 0
    private var startStrength: Float = 0
    private var targetStrength: Float = 0
    private var animationStart: Date?
    private var animationDuration: TimeInterval = 0
    private var animationCurve: EaseCurve = .easeOut
    private var animationCompletion: (() -> Void)?

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

    // MARK: - Animation API

    /// Smoothly transition currentStrength to `target` over `duration`. The 1Hz idle timer
    /// gets swapped for a 60Hz animation timer for the duration of the transition.
    func animate(to target: Float, over duration: TimeInterval, curve: EaseCurve = .easeOut, completion: (() -> Void)? = nil) {
        // Apply any pending completion from a previous animation first.
        animationCompletion?()
        startStrength = currentStrength
        targetStrength = target
        animationStart = Date()
        animationDuration = duration
        animationCurve = curve
        animationCompletion = completion
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
            let done = animationCompletion
            animationCompletion = nil
            done?()
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
        // CAMetalLayer + rgba16Float uses premultiplied alpha — values written to clearColor are
        // the final framebuffer pixel values, already premultiplied. RGB > 1.0 in extendedLinearDisplayP3
        // is what asks the system for EDR headroom; alpha controls how much our overlay contributes to
        // the composite. See CLAUDE.md Gotchas for the trap.
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
