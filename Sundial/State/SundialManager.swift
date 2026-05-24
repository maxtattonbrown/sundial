// ABOUTME: Master state for Sundial — owns isOn, drives the BoostTrigger, runs side effects,
// ABOUTME: aggregates daily stats via DailySunLog, computes the effective boost from live solar
// ABOUTME: irradiance. From v0.4 the boost ceiling is internal (no user-facing slider) — the
// ABOUTME: system is fully self-tuning between a 1.5× floor and a 3.0× ceiling driven by the sun.

import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class SundialManager {
    static let shared = SundialManager()

    enum BoostState { case dormant, engaged }

    // MARK: - Persisted

    private let isOnKey = "Sundial.isOn"

    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: isOnKey)
            if isOn { onEnable() } else { onDisable() }
        }
    }

    /// Internal cap on the dynamic boost. Not user-configurable in v0.4 — chosen so the boost is
    /// noticeable at peak sun without washing out content at our 5% overlay alpha.
    private let boostCeiling: Double = 3.0

    // MARK: - Published live state

    var state: BoostState = .dormant
    var currentOSBrightness: Double = 0.0
    var batteryCostMinutesPerHour: Int? = nil
    var batteryPercent: Int = 100
    var powerState: BatteryCost.PowerState = .unknown
    /// The boost multiplier currently being rendered.
    var currentEffectiveBoost: Double = 0

    let solar = SolarContext()
    let dailyLog = DailySunLog()

    // MARK: - Collaborators

    private let edr = EDRBoost()
    private let cost = BatteryCost()
    private var poller: BrightnessPoller?
    private var trigger = BoostTrigger()

    private let pollIntervalSeconds: Double = 3.0

    // MARK: - Init

    private init() {
        self.isOn = UserDefaults.standard.bool(forKey: isOnKey)

        poller = BrightnessPoller(interval: pollIntervalSeconds) { [weak self] brightness in
            self?.handleBrightness(brightness)
        }
        poller?.start()

        if isOn {
            onEnable()
        }
    }

    // MARK: - Toggle lifecycle

    private func onEnable() {
        solar.start()
    }

    private func onDisable() {
        edr.disengage()
        state = .dormant
        currentEffectiveBoost = 0
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
        trigger.reset()
    }

    // MARK: - Reactive trigger + daily tick

    private func handleBrightness(_ brightness: Double) {
        currentOSBrightness = brightness
        batteryPercent = cost.batteryPercent()
        powerState = cost.powerState()

        if state == .engaged {
            dailyLog.tick(
                durationMinutes: pollIntervalSeconds / 60.0,
                uvIndex: solar.currentUVIndex,
                irradiance: solar.currentIrradiance
            )
            applyEffectiveBoost()
        }

        guard isOn else { return }

        switch trigger.step(brightness: brightness, now: Date()) {
        case .engaged: engage()
        case .disengaged: disengage()
        case .noChange: break
        }
    }

    private func engage() {
        cost.startSampling()
        edr.engage()
        state = .engaged
        applyEffectiveBoost()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            if self.state == .engaged {
                self.batteryCostMinutesPerHour = self.cost.estimateMinutesLostPerHour()
            }
        }
    }

    private func disengage() {
        edr.disengage()
        state = .dormant
        currentEffectiveBoost = 0
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
    }

    // MARK: - Effective boost

    private func applyEffectiveBoost() {
        let target = Self.computeEffectiveBoost(
            ceiling: boostCeiling,
            irradiance: solar.currentIrradiance,
            solarAvailable: solar.availability == .ready
        )
        currentEffectiveBoost = target
        edr.setEffectiveStrength(Float(target))
    }

    /// Pure function — translate (boost ceiling, current irradiance, availability) into a multiplier.
    ///
    /// Behaviour:
    /// - If solar data isn't ready (location denied / offline), fall back to the ceiling so the
    ///   boost still does something useful.
    /// - Otherwise, ramp linearly from 1.5× at ≤200 W/m² to the ceiling at ≥1000 W/m². The floor
    ///   ensures Sundial does *something* when engaged in low-irradiance conditions.
    static func computeEffectiveBoost(ceiling: Double, irradiance: Double, solarAvailable: Bool) -> Double {
        guard solarAvailable else { return ceiling }
        let floor: Double = 1.5
        let cap = max(floor, ceiling)
        let lowAnchor: Double = 200
        let highAnchor: Double = 1000
        let normalised = max(0, min(1, (irradiance - lowAnchor) / (highAnchor - lowAnchor)))
        return floor + (cap - floor) * normalised
    }

    // MARK: - Derived display values

    /// 0.0–1.0 representing how close brightness is to the engage threshold (0.95). Once engaged
    /// it stays at 1.0. Used to drive the dormant-state progress bar in the popover.
    var engageProgress: Double {
        let threshold = 0.95
        if state == .engaged { return 1.0 }
        return min(1.0, max(0.0, currentOSBrightness / threshold))
    }

    /// 1, 2 or 3 lightning bolts indicating how hard Sundial is currently working.
    /// Mapped from the effective boost (1.5–3.0 range).
    var boostBoltCount: Int {
        let boost = currentEffectiveBoost
        if boost <= 0 { return 0 }
        if boost <= 1.7 { return 1 }
        if boost <= 2.4 { return 2 }
        return 3
    }
}
