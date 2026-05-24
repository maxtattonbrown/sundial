// ABOUTME: Tests for the Vitamin D math and the time-weighted UV average. The model is
// ABOUTME: optimistic-fuzzy by design, but we still want the bones (averages, rollover) to be correct.

import XCTest
@testable import Sundial

@MainActor
final class DailySunLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "Sundial.DailySunLog.v1")
    }

    func test_startsEmpty() {
        let log = DailySunLog()
        XCTAssertEqual(log.today.totalMinutes, 0)
        XCTAssertEqual(log.vitaminDPercent, 0)
        XCTAssertEqual(log.tanFraction, 0)
    }

    func test_uv5_twentyMinutes_isAround100Percent() {
        let log = DailySunLog()
        // 0.5 min ticks (each tick represents 30s of engaged time) × 40 = 20 min
        for _ in 0..<40 {
            log.tick(durationMinutes: 0.5, uvIndex: 5.0, irradiance: 850.0)
        }
        XCTAssertEqual(log.today.totalMinutes, 20.0, accuracy: 0.01)
        XCTAssertEqual(log.averageUVDuringBoost, 5.0, accuracy: 0.01)
        XCTAssertEqual(log.vitaminDPercent, 100, "UV5 × 20min should be the round-100 reference point")
    }

    func test_uv3_twentyMinutes_isAround60Percent() {
        let log = DailySunLog()
        log.tick(durationMinutes: 20.0, uvIndex: 3.0, irradiance: 500.0)
        XCTAssertEqual(log.vitaminDPercent, 60)
    }

    func test_uvBelowOne_givesNoVitaminD() {
        let log = DailySunLog()
        log.tick(durationMinutes: 120.0, uvIndex: 0.5, irradiance: 100.0)
        XCTAssertEqual(log.vitaminDPercent, 0, "Below UV1, UVB synthesis is negligible — count as zero")
    }

    func test_vitaminDIsCappedAt100() {
        let log = DailySunLog()
        log.tick(durationMinutes: 120.0, uvIndex: 8.0, irradiance: 950.0)
        XCTAssertEqual(log.vitaminDPercent, 100, "Don't show >100% even if you spent all day in Madrid")
    }

    func test_peakIrradianceTracksMaximum() {
        let log = DailySunLog()
        log.tick(durationMinutes: 1.0, uvIndex: 3.0, irradiance: 500.0)
        log.tick(durationMinutes: 1.0, uvIndex: 5.0, irradiance: 900.0)
        log.tick(durationMinutes: 1.0, uvIndex: 4.0, irradiance: 700.0)
        XCTAssertEqual(log.today.peakIrradiance, 900.0)
    }

    func test_averageUVIsTimeWeighted() {
        let log = DailySunLog()
        // 10 minutes at UV 2, then 10 minutes at UV 8 → equal-weighted average should be 5.
        log.tick(durationMinutes: 10.0, uvIndex: 2.0, irradiance: 200.0)
        log.tick(durationMinutes: 10.0, uvIndex: 8.0, irradiance: 900.0)
        XCTAssertEqual(log.averageUVDuringBoost, 5.0, accuracy: 0.01)
    }

    func test_averageUVRespectsUnequalWeights() {
        let log = DailySunLog()
        // 5 minutes at UV 2, then 15 minutes at UV 6 → (2*5 + 6*15)/20 = 5.0
        log.tick(durationMinutes: 5.0, uvIndex: 2.0, irradiance: 200.0)
        log.tick(durationMinutes: 15.0, uvIndex: 6.0, irradiance: 800.0)
        XCTAssertEqual(log.averageUVDuringBoost, 5.0, accuracy: 0.01)
    }

    func test_tanFractionSaturatesAt120Minutes() {
        let log = DailySunLog()
        log.tick(durationMinutes: 60.0, uvIndex: 5.0, irradiance: 800.0)
        XCTAssertEqual(log.tanFraction, 0.5, accuracy: 0.01)
        log.tick(durationMinutes: 60.0, uvIndex: 5.0, irradiance: 800.0)
        XCTAssertEqual(log.tanFraction, 1.0, accuracy: 0.01)
        log.tick(durationMinutes: 60.0, uvIndex: 5.0, irradiance: 800.0)
        XCTAssertEqual(log.tanFraction, 1.0, "Tan saturates — 3 hours doesn't look more orange than 2 hours")
    }

    func test_formattedMinutes() {
        let log = DailySunLog()
        log.tick(durationMinutes: 0, uvIndex: 0, irradiance: 0)
        XCTAssertEqual(log.formattedMinutes, "0 min")
        log.tick(durationMinutes: 45, uvIndex: 5, irradiance: 800)
        XCTAssertEqual(log.formattedMinutes, "45 min")
        log.tick(durationMinutes: 30, uvIndex: 5, irradiance: 800)
        XCTAssertEqual(log.formattedMinutes, "1h 15m")
    }

    func test_persistsToUserDefaults() {
        let log = DailySunLog()
        log.tick(durationMinutes: 20.0, uvIndex: 5.0, irradiance: 850.0)
        // New instance loads the same data
        let log2 = DailySunLog()
        XCTAssertEqual(log2.today.totalMinutes, 20.0, accuracy: 0.01)
        XCTAssertEqual(log2.vitaminDPercent, 100)
    }
}
