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
            (0.5, 3),   // reset
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
            (0.5, 6),   // begin dwell
            (0.5, 9),   // 3s in — no transition
            (0.5, 12),  // 6s in — no transition
            (0.5, 15),  // 9s in — no transition
            (0.5, 16),  // 10s in — disengage
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .noChange, .disengaged])
        XCTAssertEqual(trigger.state, .dormant(consecutiveHigh: 0))
    }

    func test_brightnessRecoveryAbandonsDisengageCountdown() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged

        let transitions = run(&trigger, events: [
            (0.5, 6),   // begin dwell
            (1.0, 9),   // recovered — abandon countdown
            (0.5, 12),  // start dwell again, only 0s in
            (0.5, 15),  // 3s in
            (0.5, 21),  // 9s in — still engaged
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
            (0.99, 0),
            (0.99, 3),
        ])
        XCTAssertEqual(transitions, [.noChange, .engaged])
    }

    func test_disengageThresholdIsInclusive() {
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged

        let transitions = run(&trigger, events: [
            (0.95, 6),   // exactly at threshold — start dwell
            (0.95, 17),  // 11s in — disengage
        ])
        XCTAssertEqual(transitions, [.noChange, .disengaged])
    }

    func test_betweenThresholdsCountsAsBoostedNotDisengaging() {
        // 0.96 is below engage (0.99) but above disengage (0.95) — should keep us engaged
        // without starting the disengage countdown.
        var trigger = BoostTrigger()
        _ = run(&trigger, events: [(1.0, 0), (1.0, 3)])  // engaged

        let transitions = run(&trigger, events: [
            (0.96, 6),
            (0.96, 100),
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange])
        XCTAssertEqual(trigger.state, .engaged(lowSince: nil))
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
            (0.5, 6),
            (0.5, 15),   // 9s in
            (0.5, 26),   // 20s in
            (0.5, 36),   // 30s in — disengage
        ])
        XCTAssertEqual(transitions, [.noChange, .noChange, .noChange, .disengaged])
    }
}
