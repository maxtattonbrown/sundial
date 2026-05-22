// ABOUTME: Polls the OS display brightness every N seconds via the private DisplayServices framework.
// ABOUTME: Resolved at runtime with dlopen + dlsym so the build doesn't depend on private headers.
// ABOUTME: If the symbol can't be found (future macOS), polling silently stops and Sundial stays dormant.

import Foundation
import CoreGraphics

@MainActor
final class BrightnessPoller {
    typealias Callback = (Double) -> Void

    private let interval: TimeInterval
    private let callback: Callback
    private var timer: Timer?

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private let getBrightness: GetBrightnessFn?

    init(interval: TimeInterval, callback: @escaping Callback) {
        self.interval = interval
        self.callback = callback

        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_NOW)
        if let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            self.getBrightness = unsafeBitCast(sym, to: GetBrightnessFn.self)
        } else {
            self.getBrightness = nil
            print("[Sundial] DisplayServicesGetBrightness unavailable — brightness polling disabled")
        }
    }

    func start() {
        stop()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let getBrightness else { return }
        let displayID = CGMainDisplayID()
        var brightness: Float = 0
        let result = getBrightness(displayID, &brightness)
        guard result == 0 else { return }
        callback(Double(brightness))
    }
}
