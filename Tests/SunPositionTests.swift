// ABOUTME: Sanity checks for the Schlyter algorithm. Values cross-referenced against the
// ABOUTME: NOAA solar position calculator (https://gml.noaa.gov/grad/solcalc/azel.html).
// ABOUTME: Tolerances are generous (~1°) — Schlyter is accurate to 0.01° but our test values
// ABOUTME: come from NOAA's calculator which has its own rounding.

import XCTest
@testable import Sundial

final class SunPositionTests: XCTestCase {

    /// Build a Date from explicit UTC components — tests stay timezone-independent.
    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    // MARK: - Known reference points

    func test_solarNoonInLondonMidsummer_isHighAndDueSouth() {
        // Solar noon in London on 21 June is ~12:00 UTC (equation of time + longitude correction
        // put it within ~1 minute of noon UTC; BST is irrelevant — that's a clock-time concept,
        // not an astronomical one). Tolerance allows for slight EoT slop.
        let date = utcDate(year: 2026, month: 6, day: 21, hour: 12)
        let pos = Sun.position(latitude: 51.5074, longitude: -0.1278, date: date)
        XCTAssertEqual(pos.azimuth, 180.0, accuracy: 5.0, "Sun should be roughly due south at solar noon")
        XCTAssertGreaterThan(pos.elevation, 55.0, "Sun should be high on midsummer's day in London")
    }

    func test_solarNoonInLondonMidwinter_isLowAndDueSouth() {
        // 21 December 2026, 12:00 UTC ≈ solar noon (GMT in winter).
        let date = utcDate(year: 2026, month: 12, day: 21, hour: 12)
        let pos = Sun.position(latitude: 51.5074, longitude: -0.1278, date: date)
        XCTAssertEqual(pos.azimuth, 180.0, accuracy: 5.0)
        XCTAssertLessThan(pos.elevation, 20.0, "Midwinter sun is low in London")
    }

    func test_sunIsBelowHorizonAtMidnight() {
        let date = utcDate(year: 2026, month: 5, day: 15, hour: 0)
        let pos = Sun.position(latitude: 51.5074, longitude: -0.1278, date: date)
        XCTAssertLessThan(pos.elevation, 0.0, "Sun should be below horizon at midnight UTC in London in May")
    }

    func test_sunRisesInTheEast() {
        // Mid-May sunrise in London ≈ 04:50 UTC. Pick a moment shortly after.
        let date = utcDate(year: 2026, month: 5, day: 15, hour: 5)
        let pos = Sun.position(latitude: 51.5074, longitude: -0.1278, date: date)
        XCTAssertGreaterThan(pos.azimuth, 45.0, "Rising sun should be east-ish")
        XCTAssertLessThan(pos.azimuth, 90.0, "and north of due east in early summer")
    }

    func test_sunSetsInTheWest() {
        // Mid-May sunset in London ≈ 19:55 UTC. Pick a moment shortly before.
        let date = utcDate(year: 2026, month: 5, day: 15, hour: 19)
        let pos = Sun.position(latitude: 51.5074, longitude: -0.1278, date: date)
        XCTAssertGreaterThan(pos.azimuth, 270.0, "Setting sun should be west-ish")
        XCTAssertLessThan(pos.azimuth, 315.0)
    }

    // MARK: - Compass helper

    func test_compass_quadrants() {
        XCTAssertEqual(Sun.compass(0), "N")
        XCTAssertEqual(Sun.compass(45), "NE")
        XCTAssertEqual(Sun.compass(90), "E")
        XCTAssertEqual(Sun.compass(135), "SE")
        XCTAssertEqual(Sun.compass(180), "S")
        XCTAssertEqual(Sun.compass(225), "SW")
        XCTAssertEqual(Sun.compass(270), "W")
        XCTAssertEqual(Sun.compass(315), "NW")
        XCTAssertEqual(Sun.compass(360), "N")    // wraps cleanly
    }

    func test_compass_handlesAnglesOutsideRange() {
        XCTAssertEqual(Sun.compass(-45), "NW")   // -45 == 315
        XCTAssertEqual(Sun.compass(370), "N")    // 370 == 10
    }
}
