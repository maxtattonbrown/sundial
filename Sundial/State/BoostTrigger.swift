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
    /// Brightness reading low enough to indicate the user has unambiguously left the sun
    /// (gone indoors). Short dwell — no chance of accidental re-engagement at this level.
    var fastDisengageThreshold: Double = 0.60
    var engageRequiredReads: Int = 2
    var disengageDwellSeconds: TimeInterval = 10.0
    /// Dwell time for the fast-disengage path. Tight because the brightness drop is decisive.
    var fastDisengageDwellSeconds: TimeInterval = 1.5

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
            // Two-tier disengage: a fast path for unambiguous "left the sun" events (brightness
            // far below the threshold), and a slower path for ambiguous near-threshold dips
            // (a passing cloud). The fast path can pre-empt the slow one — if brightness drops
            // below the fast threshold mid-dwell, the effective dwell shortens immediately.
            let effectiveDwell: TimeInterval?
            if brightness <= fastDisengageThreshold {
                effectiveDwell = fastDisengageDwellSeconds
            } else if brightness <= disengageThreshold {
                effectiveDwell = disengageDwellSeconds
            } else {
                // Brightness recovered above the disengage threshold — abandon the countdown.
                state = .engaged(lowSince: nil)
                effectiveDwell = nil
            }

            if let dwell = effectiveDwell {
                if let start = lowSince {
                    if now.timeIntervalSince(start) >= dwell {
                        state = .dormant(consecutiveHigh: 0)
                        return .disengaged
                    }
                } else {
                    state = .engaged(lowSince: now)
                }
            }
        }
        return .noChange
    }

    mutating func reset() {
        state = .dormant(consecutiveHigh: 0)
    }
}
