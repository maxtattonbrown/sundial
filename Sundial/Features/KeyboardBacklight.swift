// ABOUTME: Drops the keyboard backlight to zero while Sundial is on, restores on toggle-off.
// ABOUTME: Uses NSEvent.systemDefined illumination-down/up events (the same events the F5/F6
// ABOUTME: keys generate). Requires Accessibility permission to inject; silently no-ops if denied
// ABOUTME: so the rest of Sundial keeps working. UI surfaces the "needs Accessibility" state.

import AppKit

@MainActor
final class KeyboardBacklight {
    private var pressedDown = 0

    // Apple's NXKeyType values for keyboard illumination.
    private let NX_KEYTYPE_ILLUMINATION_UP: UInt32 = 20
    private let NX_KEYTYPE_ILLUMINATION_DOWN: UInt32 = 21

    /// Whether macOS has trusted this process to inject input events. Read on every check —
    /// the user can flip it in System Settings while Sundial is running.
    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func engage() {
        guard isAccessibilityGranted else {
            print("[Sundial] Accessibility not granted — keyboard backlight feature inactive")
            return
        }
        // Press illumination-down enough times to guarantee zero from any starting level.
        // Apple's hardware uses 16 steps, so 24 is comfortably saturating.
        for _ in 0..<24 {
            postIlluminationEvent(keyType: NX_KEYTYPE_ILLUMINATION_DOWN)
            pressedDown += 1
        }
    }

    func disengage() {
        guard isAccessibilityGranted, pressedDown > 0 else { return }
        for _ in 0..<pressedDown {
            postIlluminationEvent(keyType: NX_KEYTYPE_ILLUMINATION_UP)
        }
        pressedDown = 0
    }

    /// Posts a "media-key"-style aux event (NSEvent.EventType.systemDefined, subtype 8) carrying
    /// an Apple key-type code in the high half of data1. This is the documented mechanism for
    /// simulating hardware media keys like brightness and keyboard illumination.
    private func postIlluminationEvent(keyType: UInt32) {
        let downData1 = Int((keyType << 16) | (0xA << 8))
        let upData1   = Int((keyType << 16) | (0xB << 8))

        for data1 in [downData1, upData1] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ), let cg = event.cgEvent else { continue }
            cg.post(tap: .cghidEventTap)
        }
    }
}
