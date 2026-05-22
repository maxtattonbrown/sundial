// ABOUTME: Master state for Sundial — owns isOn, the dormant/engaged trigger, and feature orchestration.
// ABOUTME: Brightness samples flow in from BrightnessPoller; the state machine engages EDR boost only
// ABOUTME: when the OS brightness slider has saturated, and disengages with hysteresis to avoid flutter.

import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class SundialManager {
    static let shared = SundialManager()

    enum BoostState { case dormant, engaged }

    private let defaultsKey = "Sundial.isOn"

    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: defaultsKey)
            if isOn { onEnable() } else { onDisable() }
        }
    }
    var state: BoostState = .dormant
    var currentOSBrightness: Double = 0.0
    var batteryCostMinutesPerHour: Int? = nil
    var batteryPercent: Int = 100

    private let edr = EDRBoost()
    private let keyboard = KeyboardBacklight()
    private let cost = BatteryCost()
    private var poller: BrightnessPoller?

    private var aboveThresholdCount = 0
    private var belowThresholdStart: Date?

    // Hysteresis thresholds. Asymmetric so brightness flutter at the top of the range
    // doesn't oscillate the boost — engage requires sustained saturation, disengage requires
    // sustained drop. Same shape as a thermostat.
    private let engageThreshold: Double = 0.99
    private let disengageThreshold: Double = 0.95
    private let engageRequiredReads = 2
    private let disengageDwellSeconds: TimeInterval = 10.0

    private init() {
        self.isOn = UserDefaults.standard.bool(forKey: defaultsKey)

        poller = BrightnessPoller(interval: 3.0) { [weak self] brightness in
            self?.handleBrightness(brightness)
        }
        poller?.start()

        if isOn { onEnable() }
    }

    // MARK: - Toggle lifecycle

    private func onEnable() {
        keyboard.engage()
    }

    private func onDisable() {
        edr.disengage()
        keyboard.disengage()
        state = .dormant
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
        aboveThresholdCount = 0
        belowThresholdStart = nil
    }

    // MARK: - Reactive trigger

    private func handleBrightness(_ brightness: Double) {
        currentOSBrightness = brightness
        batteryPercent = cost.batteryPercent()

        guard isOn else { return }

        switch state {
        case .dormant:
            if brightness >= engageThreshold {
                aboveThresholdCount += 1
                if aboveThresholdCount >= engageRequiredReads {
                    engage()
                }
            } else {
                aboveThresholdCount = 0
            }
        case .engaged:
            if brightness <= disengageThreshold {
                if belowThresholdStart == nil {
                    belowThresholdStart = Date()
                } else if Date().timeIntervalSince(belowThresholdStart!) >= disengageDwellSeconds {
                    disengage()
                }
            } else {
                belowThresholdStart = nil
            }
        }
    }

    private func engage() {
        cost.startSampling()
        edr.engage()
        state = .engaged
        aboveThresholdCount = 0
        belowThresholdStart = nil
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
        belowThresholdStart = nil
        aboveThresholdCount = 0
        batteryCostMinutesPerHour = nil
        cost.stopSampling()
    }
}
