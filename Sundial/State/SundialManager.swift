// ABOUTME: Master state for Sundial — owns isOn, drives the BoostTrigger, runs side effects,
// ABOUTME: aggregates daily stats via DailySunLog, computes the effective boost from live solar
// ABOUTME: irradiance. v0.5.1 hardens against several state-coherence bugs found in code review.

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

    /// Internal cap on the dynamic boost. Not user-configurable — chosen so the boost is
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

    /// Increments on every successful `engage()`. The deferred 8-second battery-cost sampling
    /// Task captures this value at scheduling and only writes back if the cycle is still current —
    /// engage → disengage → re-engage within 8s would otherwise let an old Task contaminate the
    /// new cycle's measurement.
    private var engageCycle: UInt64 = 0

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
        // Freeze brightness reading so the bar doesn't continue pulsing with ambient light while
        // the readout says "Off".
        currentOSBrightness = 0
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
        trigger.reset()
    }

    // MARK: - Reactive trigger + daily tick

    private func handleBrightness(_ brightness: Double) {
        // Battery readings update regardless of isOn — the battery section is visible either way.
        batteryPercent = cost.batteryPercent()
        powerState = cost.powerState()

        guard isOn else {
            // When toggled off, don't let live brightness keep filling the engageProgress bar.
            currentOSBrightness = 0
            return
        }

        currentOSBrightness = brightness

        // Run the trigger FIRST. The state machine decides whether we're engaging, staying put,
        // or disengaging. Then we react: log/animate only if we're still engaged AFTER the
        // transition. This ordering avoids two artifacts:
        //   1. dailyLog over-counting (the disengage tick would otherwise credit ~3s of sun
        //      exposure for a moment the user has already gone indoors).
        //   2. EDR animation flicker on the disengage tick (applyEffectiveBoost would have
        //      pushed a fresh non-zero target moments before disengage zeroed it).
        switch trigger.step(brightness: brightness, now: Date()) {
        case .engaged: engage()
        case .disengaged: disengage()
        case .noChange: break
        }

        if state == .engaged {
            dailyLog.tick(
                durationMinutes: pollIntervalSeconds / 60.0,
                uvIndex: solar.currentUVIndex,
                irradiance: solar.currentIrradiance
            )
            applyEffectiveBoost()
        }
    }

    private func engage() {
        // Guard: if EDRBoost couldn't actually start (no Metal device, e.g. some VM configs),
        // don't claim engagement in the wrapper — the popover would lie about "Boosting 2.5×"
        // while no overlay window exists. Resetting the trigger backs off the engage attempt
        // for the standard 2-read window.
        guard edr.engage() else {
            print("[Sundial] engage(): EDRBoost failed to start — staying dormant")
            trigger.reset()
            return
        }
        engageCycle &+= 1
        let myCycle = engageCycle
        cost.startSampling()
        state = .engaged
        applyEffectiveBoost()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            // Only write if we're still in the same engage cycle this Task was scheduled from.
            if self.state == .engaged && self.engageCycle == myCycle {
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
    /// - If solar data isn't ready (location denied / offline / first 15s of launch), return the
    ///   floor. We don't know the real conditions, so lighting all chunks at peak would be a lie
    ///   the user can't audit.
    /// - Otherwise, ramp linearly from 1.5× at ≤200 W/m² to the ceiling at ≥800 W/m². 800 (not
    ///   1000) is calibrated to real-world peaks — UK summer noon tops at 700-900 W/m², tropical
    ///   noon rarely sustains above 900 either.
    static func computeEffectiveBoost(ceiling: Double, irradiance: Double, solarAvailable: Bool) -> Double {
        let floor: Double = 1.5
        guard solarAvailable else { return floor }
        let cap = max(floor, ceiling)
        let lowAnchor: Double = 200
        let highAnchor: Double = 800
        let normalised = max(0, min(1, (irradiance - lowAnchor) / (highAnchor - lowAnchor)))
        return floor + (cap - floor) * normalised
    }

    // MARK: - Derived display values

    /// 0.0–1.0 representing how close brightness is to the engage threshold (0.95). Once engaged
    /// it stays at 1.0. Used to drive the brightness gradient in the popover.
    var engageProgress: Double {
        let threshold = 0.95
        if state == .engaged { return 1.0 }
        return min(1.0, max(0.0, currentOSBrightness / threshold))
    }
}
