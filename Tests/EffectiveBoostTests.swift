// ABOUTME: Tests for the dynamic boost math — translates (slider ceiling, current irradiance,
// ABOUTME: solar availability) into the actual EDR multiplier rendered by the Metal layer.

import XCTest
@testable import Sundial

@MainActor
final class EffectiveBoostTests: XCTestCase {

    // MARK: - Solar unavailable

    func test_returnsSliderValueWhenSolarUnavailable() {
        // Location denied or offline — fall back to the user's slider preference directly.
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 2.5, irradiance: 800, solarAvailable: false),
            2.5
        )
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 4.0, irradiance: 0, solarAvailable: false),
            4.0
        )
    }

    // MARK: - Boundary irradiance values

    func test_atFloorIrradianceReturnsFloor() {
        // Below the lowAnchor (200 W/m²) the boost sits at its floor (1.5×).
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 2.5, irradiance: 200, solarAvailable: true),
            1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 2.5, irradiance: 0, solarAvailable: true),
            1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 4.0, irradiance: 50, solarAvailable: true),
            1.5,
            accuracy: 0.001
        )
    }

    func test_atCeilingIrradianceReturnsSlider() {
        // v0.5 recalibration: highAnchor moved from 1000 → 800 W/m² so UK reality (peak ~800)
        // actually hits the ceiling. At 800+ W/m² the boost saturates at the ceiling.
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 2.5, irradiance: 800, solarAvailable: true),
            2.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 4.0, irradiance: 1500, solarAvailable: true),
            4.0,
            accuracy: 0.001
        )
    }

    // MARK: - Linear ramp between anchors

    func test_midRangeIsHalfwayBetweenFloorAndSlider() {
        // Irradiance 500 W/m² = (500 − 200) / 600 = 0.5 of the way from low to high.
        // Slider 2.5 → effective = 1.5 + 0.5 × (2.5 − 1.5) = 2.0
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 2.5, irradiance: 500, solarAvailable: true),
            2.0,
            accuracy: 0.001
        )
        // Slider 4.0 → effective = 1.5 + 0.5 × (4.0 − 1.5) = 2.75
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 4.0, irradiance: 500, solarAvailable: true),
            2.75,
            accuracy: 0.001
        )
    }

    func test_threeQuartersWayUp() {
        // Irradiance 650 W/m² = (650 − 200) / 600 = 0.75 → effective = 1.5 + 0.75 × (ceiling − 1.5)
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 2.5, irradiance: 650, solarAvailable: true),
            2.25,
            accuracy: 0.001
        )
    }

    // MARK: - Slider edge cases

    func test_sliderBelowFloorJustReturnsFloor() {
        // The slider's UI range is 1.5-4.0, but defend against a hypothetical 1.0 anyway.
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 1.0, irradiance: 1000, solarAvailable: true),
            1.5,
            accuracy: 0.001
        )
    }

    func test_sliderAtFloorMeansNoVariability() {
        // If user explicitly set slider to 1.5 (the floor), the boost is always 1.5 regardless
        // of irradiance — there's no headroom to scale into.
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 1.5, irradiance: 200, solarAvailable: true),
            1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SundialManager.computeEffectiveBoost(ceiling: 1.5, irradiance: 1000, solarAvailable: true),
            1.5,
            accuracy: 0.001
        )
    }
}
