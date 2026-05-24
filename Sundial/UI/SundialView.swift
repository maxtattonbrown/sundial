// ABOUTME: Popover content — master toggle, current OS brightness reading, dormant/engaged state, battery cost.
// ABOUTME: Pure SwiftUI; bound to SundialManager via @Bindable for two-way isOn binding.

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
                batteryBlock
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 280)
        // The PopoverPanel container is intentionally transparent so SwiftUI materials
        // render cleanly — so the background lives here. `.regularMaterial` matches
        // Apple's own menu bar extras (Control Center, Wi-Fi, battery).
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
                Text("Engages when the OS brightness slider is pinned at max.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
}
