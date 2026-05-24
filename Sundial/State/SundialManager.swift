// ABOUTME: Master state for Sundial — owns isOn, drives the BoostTrigger, runs side effects.
// ABOUTME: Trigger logic lives in BoostTrigger (testable). This class owns side effects (EDR, keyboard,
// ABOUTME: battery cost), UI-bound published state, and the BrightnessPoller subscription.

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

    // MARK: - Collaborators

    private let edr = EDRBoost()
    private let keyboard = KeyboardBacklight()
    private let cost = BatteryCost()
    private var poller: BrightnessPoller?
    private var trigger = BoostTrigger()

    // MARK: - Init

    private init() {
        // UserDefaults.standard.bool(forKey:) returns false for missing keys — fine default.
        self.isOn = UserDefaults.standard.bool(forKey: isOnKey)

        // For numeric values we need a manual default to preserve "missing" semantics.
        let storedStrength = UserDefaults.standard.object(forKey: strengthKey) as? Double
        self.boostStrength = storedStrength ?? 2.5

        edr.boostStrength = Float(boostStrength)

        poller = BrightnessPoller(interval: 3.0) { [weak self] brightness in
            self?.handleBrightness(brightness)
        }
        poller?.start()

        accessibilityGranted = keyboard.isAccessibilityGranted

        if isOn { onEnable() }
    }

    // MARK: - Toggle lifecycle

    private func onEnable() {
        accessibilityGranted = keyboard.isAccessibilityGranted
        keyboard.engage()
    }

    private func onDisable() {
        edr.disengage()
        keyboard.disengage()
        state = .dormant
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
        trigger.reset()
    }

    // MARK: - Reactive trigger

    private func handleBrightness(_ brightness: Double) {
        currentOSBrightness = brightness
        batteryPercent = cost.batteryPercent()
        accessibilityGranted = keyboard.isAccessibilityGranted

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
