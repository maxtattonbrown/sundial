// ABOUTME: Tests for the Vitamin D math and the time-weighted UV average. The model is
// ABOUTME: optimistic-fuzzy by design, but we still want the bones (averages, rollover) to be correct.
// ABOUTME: Uses an isolated UserDefaults suite per test — `UserDefaults.standard` is the *app's*
// ABOUTME: plist (test target shares the host process), so polluting it leaks fake data into Sundial.

import XCTest
@testable import Sundial

@MainActor
final class DailySunLogTests: XCTestCase {

    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "Sundial.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    /// Build a log backed by this test's isolated suite — never touches `UserDefaults.standard`.
    private func makeLog() -> DailySunLog {
        DailySunLog(defaults: defaults)
    }

    func test_startsEmpty() {
        let log = makeLog()
        XCTAssertEqual(log.today.totalMinutes, 0)
        XCTAssertEqual(log.vitaminDPercent, 0)
        XCTAssertEqual(log.tanFraction, 0)
    }

    func test_uv5_twentyMinutes_isAround100Percent() {
        let log = makeLog()
        // 0.5 min ticks (each tick represents 30s of engaged time) × 40 = 20 min
        for _ in 0..<40 {
            log.tick(durationMinutes: 0.5, uvIndex: 5.0, irradiance: 850.0)
        }
        XCTAssertEqual(log.today.totalMinutes, 20.0, accuracy: 0.01)
        XCTAssertEqual(log.averageUVDuringBoost, 5.0, accuracy: 0.01)
        XCTAssertEqual(log.vitaminDPercent, 100, "UV5 × 20min should be the round-100 reference point")
    }

    func test_uv3_twentyMinutes_isAround60Percent() {
        let log = makeLog()
        log.tick(durationMinutes: 20.0, uvIndex: 3.0, irradiance: 500.0)
        XCTAssertEqual(log.vitaminDPercent, 60)
    }

    func test_uvBelowOne_givesNoVitaminD() {
        let log = makeLog()
        log.tick(durationMinutes: 120.0, uvIndex: 0.5, irradiance: 100.0)
        XCTAssertEqual(log.vitaminDPercent, 0, "Below UV1, UVB synthesis is negligible — count as zero")
    }

    func test_vitaminDIsCappedAt100() {
        let log = makeLog()
        log.tick(durationMinutes: 120.0, uvIndex: 8.0, irradiance: 950.0)
        XCTAssertEqual(log.vitaminDPercent, 100, "Don't show >100% even if you spent all day in Madrid")
    }

    func test_peakIrradianceTracksMaximum() {
        let log = makeLog()
        log.tick(durationMinutes: 1.0, uvIndex: 3.0, irradiance: 500.0)
        log.tick(durationMinutes: 1.0, uvIndex: 5.0, irradiance: 900.0)
        log.tick(durationMinutes: 1.0, uvIndex: 4.0, irradiance: 700.0)
        XCTAssertEqual(log.today.peakIrradiance, 900.0)
    }

    func test_averageUVIsTimeWeighted() {
        let log = makeLog()
        // 10 minutes at UV 2, then 10 minutes at UV 8 → equal-weighted average should be 5.
        log.tick(durationMinutes: 10.0, uvIndex: 2.0, irradiance: 200.0)
        log.tick(durationMinutes: 10.0, uvIndex: 8.0, irradiance: 900.0)
        XCTAssertEqual(log.averageUVDuringBoost, 5.0, accuracy: 0.01)
    }

    func test_averageUVRespectsUnequalWeights() {
        let log = makeLog()
        // 5 minutes at UV 2, then 15 minutes at UV 6 → (2*5 + 6*15)/20 = 5.0
        log.tick(durationMinutes: 5.0, uvIndex: 2.0, irradiance: 200.0)
        log.tick(durationMinutes: 15.0, uvIndex: 6.0, irradiance: 800.0)
        XCTAssertEqual(log.averageUVDuringBoost, 5.0, accuracy: 0.01)
    }

    func test_tanFractionSaturatesAt120Minutes() {
        let log = makeLog()
        log.tick(durationMinutes: 60.0, uvIndex: 5.0, irradiance: 800.0)
        XCTAssertEqual(log.tanFraction, 0.5, accuracy: 0.01)
        log.tick(durationMinutes: 60.0, uvIndex: 5.0, irradiance: 800.0)
        XCTAssertEqual(log.tanFraction, 1.0, accuracy: 0.01)
        log.tick(durationMinutes: 60.0, uvIndex: 5.0, irradiance: 800.0)
        XCTAssertEqual(log.tanFraction, 1.0, "Tan saturates — 3 hours doesn't look more orange than 2 hours")
    }

    func test_formattedMinutes() {
        let log = makeLog()
        log.tick(durationMinutes: 0, uvIndex: 0, irradiance: 0)
        XCTAssertEqual(log.formattedMinutes, "0 min")
        log.tick(durationMinutes: 45, uvIndex: 5, irradiance: 800)
        XCTAssertEqual(log.formattedMinutes, "45 min")
        log.tick(durationMinutes: 30, uvIndex: 5, irradiance: 800)
        XCTAssertEqual(log.formattedMinutes, "1h 15m")
    }

    func test_persistsAcrossInstancesInTheSameSuite() {
        let log = makeLog()
        log.tick(durationMinutes: 20.0, uvIndex: 5.0, irradiance: 850.0)

        // New instance pointed at the same isolated suite should see the same data.
        let log2 = DailySunLog(defaults: defaults)
        XCTAssertEqual(log2.today.totalMinutes, 20.0, accuracy: 0.01)
        XCTAssertEqual(log2.vitaminDPercent, 100)
    }

    func test_doesNotLeakIntoStandardDefaults() {
        let log = makeLog()
        log.tick(durationMinutes: 30.0, uvIndex: 5.0, irradiance: 800.0)

        // A fresh log pointed at .standard must NOT see what we just wrote — confirmation the
        // isolation works. (The standard suite may have its own leftover data; we only care that
        // the *value we just wrote* didn't end up there.)
        let standardData = UserDefaults.standard.data(forKey: "Sundial.DailySunLog.v1")
        if let data = standardData,
           let day = try? JSONDecoder().decode(DailySunLog.Day.self, from: data) {
            XCTAssertNotEqual(day.totalMinutes, 30.0, "Test isolation failed — data leaked to .standard")
        }
    }
}
