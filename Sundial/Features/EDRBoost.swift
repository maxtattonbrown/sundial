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
    private let device = MTLCreateSystemDefaultDevice()

    func engage() {
        guard windows.isEmpty else { return }
        guard let device else {
            print("[Sundial] No Metal device available — cannot engage EDR boost")
            return
        }

        for screen in NSScreen.screens {
            let window = makeWindow(for: screen, device: device)
            window.orderFront(nil)
            windows.append(window)
        }
    }

    func disengage() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    private func makeWindow(for screen: NSScreen, device: MTLDevice) -> NSWindow {
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
        return window
    }
}

/// NSView backed by a CAMetalLayer configured for EDR. Renders a low-alpha extended-range
/// frame; the system grants EDR headroom in response, which lifts the panel's overall backlight.
@MainActor
final class EDRMetalView: NSView {
    private let metalLayer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue?
    private var displayLink: CVDisplayLink?

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
        layer = metalLayer

        // Initial draw — and one per layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.render()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
        render()
    }

    private func render() {
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        // Premultiplied EDR pixel: (R,G,B) already multiplied by alpha. We want the panel to
        // "see" extended-range white at low effective opacity. The actual luminance contribution
        // to the composite is small (so the screen doesn't look obviously washed out), but the
        // EDR signal lifts the backlight ceiling for the whole display.
        let alpha: Float = 0.04
        let edrWhite: Float = 4.0 * alpha   // premultiplied
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red:   Double(edrWhite),
            green: Double(edrWhite),
            blue:  Double(edrWhite),
            alpha: Double(alpha)
        )
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
