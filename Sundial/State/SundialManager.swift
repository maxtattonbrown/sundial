// ABOUTME: Master state for Sundial — owns isOn, drives the BoostTrigger, runs side effects,
// ABOUTME: aggregates daily stats via DailySunLog, computes the *dynamic* effective boost from
// ABOUTME: live solar irradiance and re-applies it on every poll so the boost follows the sun.

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
    private let strengthKey = "Sundial.boostStrength"

    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: isOnKey)
            if isOn { onEnable() } else { onDisable() }
        }
    }

    /// User-set CEILING on boost intensity. The *actual* boost (`currentEffectiveBoost`) scales
    /// up from 1.5× at low irradiance toward this value at peak sun. Range 1.5–4.0.
    var boostStrength: Double {
        didSet {
            UserDefaults.standard.set(boostStrength, forKey: strengthKey)
            if state == .engaged { applyEffectiveBoost() }
        }
    }

    // MARK: - Published live state

    var state: BoostState = .dormant
    var currentOSBrightness: Double = 0.0
    var batteryCostMinutesPerHour: Int? = nil
    var batteryPercent: Int = 100
    /// The boost multiplier currently being rendered — distinct from `boostStrength` (the ceiling).
    /// Updated continuously based on `SolarContext.currentIrradiance`.
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

        let storedStrength = UserDefaults.standard.object(forKey: strengthKey) as? Double
        self.boostStrength = storedStrength ?? 2.5

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

        if state == .engaged {
            dailyLog.tick(
                durationMinutes: pollIntervalSeconds / 60.0,
                uvIndex: solar.currentUVIndex,
                irradiance: solar.currentIrradiance
            )
            // Re-evaluate the effective boost every poll so the EDR layer tracks live irradiance.
            // EDRBoost only flashes the indicator if the new value is a meaningful step UP.
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

    /// Computes the boost intensity for the current moment and pushes it to the EDR layer.
    private func applyEffectiveBoost() {
        let target = Self.computeEffectiveBoost(
            slider: boostStrength,
            irradiance: solar.currentIrradiance,
            solarAvailable: solar.availability == .ready
        )
        currentEffectiveBoost = target
        edr.setEffectiveStrength(Float(target))
    }

    /// Pure function — translate (slider ceiling, current irradiance) into a boost multiplier.
    ///
    /// Behaviour:
    /// - If solar data isn't ready (location denied / offline), honour the slider value
    ///   directly so the user's preference still has effect.
    /// - Otherwise, ramp linearly from 1.5× at ≤200 W/m² to the slider value at ≥1000 W/m².
    ///   The floor of 1.5 ensures Sundial still does *something* when engaged in low-irradiance
    ///   conditions (user pinned brightness to max but sun is weak).
    static func computeEffectiveBoost(slider: Double, irradiance: Double, solarAvailable: Bool) -> Double {
        guard solarAvailable else { return slider }
        let floor: Double = 1.5
        let ceiling = max(floor, slider)
        let lowAnchor: Double = 200
        let highAnchor: Double = 1000
        let normalised = max(0, min(1, (irradiance - lowAnchor) / (highAnchor - lowAnchor)))
        return floor + (ceiling - floor) * normalised
    }
}
