// ABOUTME: The headline feature — pushes the panel past its SDR brightness cap by requesting EDR
// ABOUTME: headroom. Engage/disengage are animated with eased curves (800ms in, 1.2s out). Effective
// ABOUTME: strength is set by SundialManager based on live solar irradiance — the boost follows the sun.

import AppKit
import Metal
import QuartzCore

@MainActor
final class EDRBoost {
    private var windows: [NSWindow] = []
    private var metalViews: [EDRMetalView] = []
    private let device = MTLCreateSystemDefaultDevice()

    /// Currently-rendered EDR multiplier. Set indirectly via `setEffectiveStrength(_:)`.
    private(set) var effectiveStrength: Float = 0

    /// Returns `true` if EDR overlay windows are now showing (or were already), `false` if no
    /// Metal device is available. SundialManager checks this so it doesn't set wrapper state to
    /// `.engaged` while the underlying GPU path is dead.
    @discardableResult
    func engage() -> Bool {
        if !windows.isEmpty { return true }
        guard let device else {
            print("[Sundial] No Metal device available — cannot engage EDR boost")
            return false
        }

        for screen in NSScreen.screens {
            let (window, view) = makeWindow(for: screen, device: device)
            window.orderFront(nil)
            windows.append(window)
            metalViews.append(view)
        }
        return !metalViews.isEmpty
    }

    func disengage() {
        guard !windows.isEmpty else { return }
        let viewsToClose = metalViews
        let windowsToClose = windows
        metalViews.removeAll()
        windows.removeAll()
        effectiveStrength = 0

        // Fade EDR strength down over 1.2s — sun-fading-behind-a-cloud feel.
        for view in viewsToClose {
            view.animate(to: 0.0, over: 1.2, curve: .easeIn)
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

    /// Set the currently-rendered boost intensity. Smoothly animates to the new value over 500ms
    /// (or 800ms on the initial engage — matches the original sun-from-cloud feel).
    func setEffectiveStrength(_ newValue: Float) {
        guard !metalViews.isEmpty else { return }
        let oldValue = effectiveStrength
        effectiveStrength = newValue
        let duration: TimeInterval = (oldValue == 0) ? 0.8 : 0.5
        for view in metalViews {
            view.animate(to: newValue, over: duration, curve: .easeOut)
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

    private func startIdleTimer() {
        redrawTimer?.invalidate()
        // .common mode keeps the timer firing while the menu-bar popover is open (which switches
        // the run loop to .eventTracking). Without this, the EDR redraw freezes during popover use.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    private func startAnimationTimer() {
        redrawTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.animationFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    private func animationFrame() {
        guard let start = animationStart else {
            startIdleTimer()
            return
        }
        // Defend against pathological inputs (duration = 0, NaN, or strength values that arrived
        // as NaN from a corrupted irradiance reading). NaN in MTLClearColor is undefined Metal
        // behaviour — snap to target and bail.
        guard animationDuration > 0,
              !targetStrength.isNaN, !startStrength.isNaN else {
            currentStrength = targetStrength.isNaN ? 0 : targetStrength
            animationStart = nil
            render()
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
