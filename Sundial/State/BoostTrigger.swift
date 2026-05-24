// ABOUTME: Pure hysteresis state machine that decides when to engage/disengage the EDR boost.
// ABOUTME: No side effects, no timers — just step(brightness, now) → Transition. SundialManager
// ABOUTME: owns the side effects; this struct owns the logic, and so is testable in isolation.

import Foundation

struct BoostTrigger {

    enum State: Equatable {
        /// Waiting for sustained high brightness. `consecutiveHigh` counts up toward the engage threshold.
        case dormant(consecutiveHigh: Int)
        /// EDR boost is active. `lowSince` is non-nil once brightness drops below the disengage threshold
        /// and we're waiting out the dwell window before actually disengaging.
        case engaged(lowSince: Date?)
    }

    enum Transition: Equatable {
        case noChange
        case engaged
        case disengaged
    }

    // MARK: - Tunables

    /// Slider value at or above which the boost should engage. Note: macOS auto-brightness
    /// reserves headroom below 1.0 — observed cap is ~0.98 in direct sun on Apple Silicon
    /// (the OS keeps a small margin for True Tone / Night Shift / HDR rendering). So 0.95
    /// is the practical "user wants max brightness" reading, not 0.99 or 1.0.
    var engageThreshold: Double = 0.95
    /// Slider value at or below which the disengage countdown starts. The gap between this
    /// and `engageThreshold` is the dead zone — it stops the boost flutter-oscillating when
    /// brightness sits near the top of the range.
    var disengageThreshold: Double = 0.85
    var engageRequiredReads: Int = 2
    var disengageDwellSeconds: TimeInterval = 10.0

    // MARK: - State

    private(set) var state: State = .dormant(consecutiveHigh: 0)

    // MARK: - API

    /// Feed a brightness reading and the current time; returns a transition if the state machine
    /// changed gears this step.
    mutating func step(brightness: Double, now: Date) -> Transition {
        switch state {
        case .dormant(let count):
            if brightness >= engageThreshold {
                let next = count + 1
                if next >= engageRequiredReads {
                    state = .engaged(lowSince: nil)
                    return .engaged
                }
                state = .dormant(consecutiveHigh: next)
            } else {
                state = .dormant(consecutiveHigh: 0)
            }
        case .engaged(let lowSince):
            if brightness <= disengageThreshold {
                if let start = lowSince {
                    if now.timeIntervalSince(start) >= disengageDwellSeconds {
                        state = .dormant(consecutiveHigh: 0)
                        return .disengaged
                    }
                } else {
                    state = .engaged(lowSince: now)
                }
            } else {
                // Brightness recovered — abandon the disengage countdown.
                state = .engaged(lowSince: nil)
            }
        }
        return .noChange
    }

    mutating func reset() {
        state = .dormant(consecutiveHigh: 0)
    }
}
