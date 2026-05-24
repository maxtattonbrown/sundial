// ABOUTME: Master state for Sundial — owns isOn, drives the BoostTrigger, runs side effects,
// ABOUTME: aggregates daily stats via DailySunLog, wires solar context for the "Today in the Sun" UI.
// ABOUTME: Trigger logic is in BoostTrigger (testable); this class is the orchestration layer.

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

    /// Multiplier written into the EDR layer's clear colour. 1.5 = subtle, 2.5 = default, 4.0 = aggressive.
    /// Range is intentionally narrow — higher than ~4 starts to wash content out at our 5% overlay alpha.
    var boostStrength: Double {
        didSet {
            UserDefaults.standard.set(boostStrength, forKey: strengthKey)
            edr.boostStrength = Float(boostStrength)
        }
    }

    // MARK: - Published live state

    var state: BoostState = .dormant
    var currentOSBrightness: Double = 0.0
    var batteryCostMinutesPerHour: Int? = nil
    var batteryPercent: Int = 100
    var accessibilityGranted: Bool = false

    let solar = SolarContext()
    let dailyLog = DailySunLog()

    // MARK: - Collaborators

    private let edr = EDRBoost()
    private let keyboard = KeyboardBacklight()
    private let cost = BatteryCost()
    private var poller: BrightnessPoller?
    private var trigger = BoostTrigger()

    private let pollIntervalSeconds: Double = 3.0

    // MARK: - Init

    private init() {
        self.isOn = UserDefaults.standard.bool(forKey: isOnKey)

        let storedStrength = UserDefaults.standard.object(forKey: strengthKey) as? Double
        self.boostStrength = storedStrength ?? 2.5

        edr.boostStrength = Float(boostStrength)

        poller = BrightnessPoller(interval: pollIntervalSeconds) { [weak self] brightness in
            self?.handleBrightness(brightness)
        }
        poller?.start()

        accessibilityGranted = keyboard.isAccessibilityGranted

        // Solar context starts whenever Sundial is on. Don't fire a location prompt at launch
        // for users who haven't even toggled it yet.
        if isOn {
            onEnable()
        }
    }

    // MARK: - Toggle lifecycle

    private func onEnable() {
        accessibilityGranted = keyboard.isAccessibilityGranted
        keyboard.engage()
        solar.start()
    }

    private func onDisable() {
        edr.disengage()
        keyboard.disengage()
        state = .dormant
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
        trigger.reset()
    }

    // MARK: - Reactive trigger + daily tick

    private func handleBrightness(_ brightness: Double) {
        currentOSBrightness = brightness
        batteryPercent = cost.batteryPercent()
        accessibilityGranted = keyboard.isAccessibilityGranted

        // Tally engaged time even after the toggle is flipped off mid-poll — but only if it was
        // already engaged at the start of this poll cycle.
        if state == .engaged {
            dailyLog.tick(
                durationMinutes: pollIntervalSeconds / 60.0,
                uvIndex: solar.currentUVIndex,
                irradiance: solar.currentIrradiance
            )
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
        Task { @MainActor [weak self] in
            // Give the panel ~8s to settle into the higher draw before sampling.
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
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
    }

    // MARK: - Manual user actions

    /// Opens System Settings → Privacy & Security → Accessibility so the user can grant permission.
    func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
