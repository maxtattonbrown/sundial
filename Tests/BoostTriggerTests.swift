// ABOUTME: Unit tests for the BoostTrigger hysteresis state machine.
// ABOUTME: All time is injected via a synthetic Date — no Thread.sleep, no flakes, runs in microseconds.

import XCTest
@testable import Sundial

final class BoostTriggerTests: XCTestCase {

    /// Helper — feed a sequence of (brightness, secondsFromStart) pairs and collect transitions.
    private func run(
        _ trigger: inout BoostTrigger,
        events: [(brightness: Double, offset: TimeInterval)]
    ) -> [BoostTrigger.Transition] {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        return events.map { event in
            let now = start.addingTimeInterval(event.offset)
            return trigger.step(brightness: event.brightness, now: now)
        }
    }

    // MARK: - Engage

    func test_engagesAfterTwoConsecutiveHighReads() {
        var trigger = BoostTrigger()
        let transitions = run(&trigger, events: [
            (1.0, 0),
            (1.0, 3),
        ])
        XCTAssertEqual(transitions, [.noChange, .engaged])
        XCTAssertEqual(trigger.state, .engaged(lowSince: nil))
    }

    func test_doesNotEngageOnSingleSpike() {
        var trigger = BoostTrigger()
        let transitions = run(&trigger, events: [
            (1.0, 0),
            (0.7, 3),
            (1.0, 6),
            (0.8, 9),
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .noChange])
        XCTAssertEqual(trigger.state, .dormant(consecutiveHigh: 0))
    }

    func test_consecutiveCounterResetsOnDropBelowThreshold() {
        var trigger = BoostTrigger()
        let transitions = run(&trigger, events: [
            (1.0, 0),   // count = 1
            (0.80, 3),   // reset
            (1.0, 6),   // count = 1 (NOT 2)
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange])
    }

    // MARK: - Disengage hysteresis

    func test_disengagesOnlyAfterTenSecondsBelowThreshold() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged
        XCTAssertEqual(trigger.state, .engaged(lowSince: nil))

        // Brightness drops at t=6 and stays low.
        let transitions = run(&trigger, events: [
            (0.80, 6),   // begin dwell
            (0.80, 9),   // 3s in — no transition
            (0.80, 12),  // 6s in — no transition
            (0.80, 15),  // 9s in — no transition
            (0.80, 16),  // 10s in — disengage
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .noChange, .disengaged])
        XCTAssertEqual(trigger.state, .dormant(consecutiveHigh: 0))
    }

    func test_brightnessRecoveryAbandonsDisengageCountdown() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged

        let transitions = run(&trigger, events: [
            (0.80, 6),   // begin dwell
            (1.0, 9),   // recovered — abandon countdown
            (0.80, 12),  // start dwell again, only 0s in
            (0.80, 15),  // 3s in
            (0.80, 21),  // 9s in — still engaged
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .noChange, .noChange])
        // Still engaged, with low countdown that started at t=12.
        if case .engaged(let lowSince) = trigger.state {
            XCTAssertNotNil(lowSince)
        } else {
            XCTFail("Expected engaged state with active countdown")
        }
    }

    // MARK: - Threshold boundaries

    func test_engageThresholdIsInclusive() {
        var trigger = BoostTrigger()
        let transitions = run(&trigger, events: [
            (0.95, 0),
            (0.95, 3),
        ])
        XCTAssertEqual(transitions, [.noChange, .engaged])
    }

    func test_disengageThresholdIsInclusive() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged

        let transitions = run(&trigger, events: [
            (0.85, 6),   // exactly at threshold — start dwell
            (0.85, 17),  // 11s in — disengage
        ])
        XCTAssertEqual(transitions, [.noChange, .disengaged])
    }

    func test_betweenThresholdsCountsAsBoostedNotDisengaging() {
        // 0.90 is below engage (0.95) but above disengage (0.85) — should keep us engaged
        // without starting the disengage countdown.
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged

        let transitions = run(&trigger, events: [
            (0.90, 6),
            (0.90, 100),
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange])
        XCTAssertEqual(trigger.state, .engaged(lowSince: nil))
    }

    /// macOS auto-brightness caps the slider value at ~0.98 even in direct sun on Apple
    /// Silicon. Sundial v0.2.0-v0.2.1 had a 0.99 engage threshold and would never fire
    /// in real outdoor conditions — this test pins the regression that prompted v0.2.2.
    func test_engagesWhenAutoBrightnessCapsBelow1() {
        var trigger = BoostTrigger()
        let transitions = run(&trigger, events: [
            (0.98, 0),   // sustained reading at the practical OS ceiling
            (0.98, 3),
        ])
        XCTAssertEqual(transitions, [.noChange, .engaged],
            "Real outdoor brightness caps below 1.0 — the trigger must still engage")
    }

    // MARK: - Fast disengage (going indoors)

    /// Walking inside drops brightness from ~0.95 to ~0.3 quickly. The standard 10s dwell felt
    /// laggy — added a fast path triggered by brightness ≤ 0.60 that disengages in 1.5s.
    func test_fastDisengageOnDeepBrightnessDrop() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged

        let transitions = run(&trigger, events: [
            (0.30, 6),   // brightness collapses — start fast dwell
            (0.30, 8),   // 2s in — past the 1.5s fast threshold
        ])
        XCTAssertEqual(transitions, [.noChange, .disengaged],
            "Deep brightness drops should fast-disengage in ~1.5s rather than the 10s standard dwell")
    }

    /// A brightness drop that's below the fast threshold but the fast dwell hasn't elapsed yet
    /// should not disengage. Verifies the timing window.
    func test_fastDisengageRequiresDwell() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])

        let transitions = run(&trigger, events: [
            (0.30, 6),   // start fast dwell
            (0.30, 7),   // 1s in — still under 1.5s threshold
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange])
        if case .engaged = trigger.state {
            // Still engaged — correct
        } else {
            XCTFail("Expected to still be engaged after only 1s of fast dwell")
        }
    }

    /// A slow drift down (cloud cover, late afternoon) should NOT fast-disengage — needs the
    /// standard 10s dwell so brief flutter near the threshold doesn't kick the boost off.
    func test_slowDriftUsesStandardDwell() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])

        let transitions = run(&trigger, events: [
            (0.80, 6),    // below disengage threshold (0.85) but above fast threshold (0.60)
            (0.80, 9),    // 3s in — standard dwell isn't done yet
            (0.80, 13),   // 7s in
            (0.80, 17),   // 11s in — disengage
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .disengaged])
    }

    /// Brightness drops into the slow zone, then drops further into the fast zone mid-dwell.
    /// The fast threshold should take over immediately — the dwell is then "1.5s since the
    /// drop began," which has already passed.
    func test_dropFromSlowToFastShortcutsTheDwell() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])

        let transitions = run(&trigger, events: [
            (0.80, 6),   // start slow dwell
            (0.30, 9),   // 3s in, drop further — now in fast zone, should disengage (3s > 1.5s)
        ])
        XCTAssertEqual(transitions, [.noChange, .disengaged],
            "Once brightness crosses into the fast zone, the dwell shortens — if elapsed already exceeds 1.5s, disengage")
    }

    // MARK: - Reset

    func test_resetReturnsToDormantWithZeroCount() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0)])  // count = 1
        trigger.reset()
        XCTAssertEqual(trigger.state, .dormant(consecutiveHigh: 0))
    }

    // MARK: - Custom configuration

    func test_engageRequiredReadsIsRespected() {
        var trigger = BoostTrigger()
        trigger.engageRequiredReads = 4
        let transitions = run(&trigger, events: [
            (1.0, 0),
            (1.0, 3),
            (1.0, 6),
            (1.0, 9),
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .engaged])
    }

    func test_disengageDwellIsRespected() {
        var trigger = BoostTrigger()
        trigger.disengageDwellSeconds = 30.0
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])

        let transitions = run(&trigger, events: [
            (0.80, 6),
            (0.80, 15),   // 9s in
            (0.80, 26),   // 20s in
            (0.80, 36),   // 30s in — disengage
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .disengaged])
    }
}
