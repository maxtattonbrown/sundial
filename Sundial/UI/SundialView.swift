// ABOUTME: Popover content — master toggle, status, accessibility prompt, boost slider,
// ABOUTME: "Today in the Sun" panel (boost minutes + Vitamin D + sun position + sunset), battery.
// ABOUTME: Pure SwiftUI; bound to SundialManager via @Bindable.

import SwiftUI

struct SundialView: View {
    @Bindable var manager: SundialManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()
            statusBlock

            if manager.isOn {
                Divider()
                strengthSlider

                if manager.solar.availability == .ready {
                    Divider()
                    todayInTheSun
                } else if manager.solar.availability == .noLocation {
                    Divider()
                    locationPrompt
                }

                Divider()
                batteryBlock
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 280)
        .background(.regularMaterial)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sundial")
                    .font(.headline)
                Text("Outside mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $manager.isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(stateLabel)
                    .font(.subheadline)
                Spacer()
                Text("\(Int((manager.currentOSBrightness * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if manager.isOn && manager.state == .dormant {
                Text("Engages when the OS brightness slider is at the top (≥ 95%). macOS auto-brightness caps slightly below 1.0 in direct sun, so the threshold isn't literally max.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var strengthSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Boost ceiling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if manager.state == .engaged && manager.currentEffectiveBoost > 0 {
                    Text(String(format: "%.1f× now / %.1f× max", manager.currentEffectiveBoost, manager.boostStrength))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: "%.1f× max", manager.boostStrength))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Slider(
                value: $manager.boostStrength,
                in: 1.5...4.0,
                step: 0.1
            )
            .controlSize(.small)
            Text("Sundial boosts harder when the sun is stronger — up to this ceiling.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Today in the Sun

    private var todayInTheSun: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today in the sun")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)

            // Minutes engaged
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                Text(manager.dailyLog.formattedMinutes)
                    .font(.subheadline.monospacedDigit())
                Text("boosting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Vitamin D — optimistic-fuzzy
            HStack(spacing: 6) {
                Image(systemName: "pills.fill").foregroundStyle(vitaminDColor)
                Text("\(manager.dailyLog.vitaminDPercent)%")
                    .font(.subheadline.monospacedDigit())
                Text("Vitamin D")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("est.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Sun position
            HStack(spacing: 6) {
                Image(systemName: "location.north.circle.fill")
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(manager.solar.sunAzimuth))
                Text(sunPositionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(manager.solar.currentIrradiance.rounded())) W/m²")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            // Sunset countdown
            if let sunset = manager.solar.sunsetToday {
                HStack(spacing: 6) {
                    Image(systemName: "sunset.fill")
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(sunsetLabel(sunset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var locationPrompt: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Location is off")
                    .font(.caption)
                Text("Grant location to see sun position, Vitamin D estimate and sunset time.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Location Settings") {
                    manager.solar.openLocationSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    private var batteryBlock: some View {
        HStack(spacing: 8) {
            Image(systemName: batteryGlyph)
                .foregroundStyle(batteryColor)
                .font(.subheadline)
            if let mins = manager.batteryCostMinutesPerHour, manager.state == .engaged {
                VStack(alignment: .leading, spacing: 1) {
                    Text("≈ −\(mins) min / hr")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(batteryColor)
                    Text("extra drain while boosting")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Battery \(manager.batteryPercent)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit Sundial") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    private var stateColor: Color {
        if !manager.isOn { return .gray }
        switch manager.state {
        case .dormant: return .yellow
        case .engaged: return .orange
        }
    }

    private var stateLabel: String {
        if !manager.isOn { return "Off" }
        switch manager.state {
        case .dormant: return "Waiting for sun"
        case .engaged: return "Boosting"
        }
    }

    private var sunPositionLabel: String {
        let elev = Int(manager.solar.sunElevation.rounded())
        if elev <= 0 {
            return "Sun below horizon"
        }
        let dir = Sun.compass(manager.solar.sunAzimuth)
        return "Sun \(elev)° \(dir)"
    }

    private func sunsetLabel(_ sunset: Date) -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: sunset)
        let interval = sunset.timeIntervalSince(now)
        if interval < 0 {
            return "Sun set at \(timeStr)"
        }
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "Sunset \(timeStr) (in \(minutes) min)"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "Sunset \(timeStr) (in \(hours)h \(mins)m)"
    }

    private var batteryGlyph: String {
        let p = manager.batteryPercent
        if p >= 75 { return "battery.100" }
        if p >= 50 { return "battery.75" }
        if p >= 25 { return "battery.50" }
        return "battery.25"
    }

    private var batteryColor: Color {
        manager.batteryPercent < 30 ? .red : .secondary
    }

    private var vitaminDColor: Color {
        let p = manager.dailyLog.vitaminDPercent
        if p >= 80 { return .green }
        if p >= 40 { return .orange }
        return .secondary
    }
}
