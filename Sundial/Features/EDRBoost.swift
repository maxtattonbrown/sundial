// ABOUTME: The headline feature — pushes the panel past its SDR brightness cap by requesting EDR headroom.
// ABOUTME: For each NSScreen, creates a borderless transparent NSWindow at .screenSaver level hosting a
// ABOUTME: CAMetalLayer with wantsExtendedDynamicRangeContent = true. Rendering values > 1.0 in extended-
// ABOUTME: linear colour space causes mini-LED to lift its backlight ceiling, which brightens *all* on-screen
// ABOUTME: content (other apps included). Our pixels are nearly transparent so the visual cost is minimal.

import AppKit
import Metal
import QuartzCore

@MainActor
final class EDRBoost {
    private var windows: [NSWindow] = []
    private var metalViews: [EDRMetalView] = []
    private let device = MTLCreateSystemDefaultDevice()

    /// EDR brightness multiplier (post-premultiplication). Live-tunable while engaged — the next
    /// render frame (1Hz) picks it up.
    var boostStrength: Float = 2.5 {
        didSet { metalViews.forEach { $0.boostStrength = boostStrength } }
    }

    func engage() {
        guard windows.isEmpty else { return }
        guard let device else {
            print("[Sundial] No Metal device available — cannot engage EDR boost")
            return
        }

        for screen in NSScreen.screens {
            let (window, view) = makeWindow(for: screen, device: device)
            view.boostStrength = boostStrength
            window.orderFront(nil)
            windows.append(window)
            metalViews.append(view)
        }
    }

    func disengage() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        metalViews.removeAll()
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
        // .screenSaver puts it above everything including fullscreen apps and the dock.
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

/// NSView backed by a CAMetalLayer configured for EDR. Presents a continuous stream of
/// extended-range frames (values > 1.0 in extendedLinearDisplayP3) — that signal is what
/// the system uses to grant EDR headroom, which lifts the panel's overall backlight.
@MainActor
final class EDRMetalView: NSView {
    private let metalLayer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue?
    private var redrawTimer: Timer?

    /// Brightness multiplier requested from the panel. 2.0 = +1 stop above SDR, 3.0 ≈ +1.5 stops.
    /// The visible luminance contribution is `boostStrength * alpha`, so a high multiplier with
    /// low alpha lets the panel ceiling rise without our overlay washing out the screen.
    /// Live-tuned from outside; the next 1Hz render picks up the new value.
    var boostStrength: Float = 2.5
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
        // Critical for Retina: the drawable must be in pixels, not points.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        layer = metalLayer

        DispatchQueue.main.async { [weak self] in
            self?.render()
            self?.startContinuousRedraw()
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

    /// Re-present at ~1 Hz. Cheap insurance against the system revoking EDR headroom when the
    /// layer goes idle. If it turns out to be unnecessary on this hardware, drop the timer.
    private func startContinuousRedraw() {
        redrawTimer?.invalidate()
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    private func render() {
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        // CAMetalLayer with rgba16Float uses premultiplied alpha — the values written to clearColor
        // ARE the final framebuffer pixel values, already premultiplied. Writing values >1.0 in
        // extendedLinearDisplayP3 is what asks the system for EDR headroom; the panel responds by
        // lifting its backlight ceiling, which brightens ALL on-screen content.
        let premulRGB = Double(boostStrength)
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
