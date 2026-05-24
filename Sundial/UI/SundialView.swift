// ABOUTME: Popover content. v0.4 redesign — icons-first, minimal explanatory text, native macOS
// ABOUTME: feel matching Control Center / battery menu. No slider, no hint paragraphs. State
// ABOUTME: communicated through a progress bar (dormant) or boost multiplier + bolts (engaged).

import SwiftUI

struct SundialView: View {
    @Bindable var manager: SundialManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusBlock

            Divider()
            batteryBlock

            if manager.solar.availability == .ready {
                Divider()
                todayBlock
            } else if manager.isOn && manager.solar.availability == .noLocation {
                Divider()
                locationPrompt
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 260)
        .background(.regularMaterial)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            Text("Sundial")
                .font(.headline)
            Spacer()
            Toggle("", isOn: $manager.isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        if manager.isOn {
            switch manager.state {
            case .dormant:
                dormantStatus
            case .engaged:
                engagedStatus
            }
        } else {
            HStack(spacing: 8) {
                Circle().fill(.gray).frame(width: 7, height: 7)
                Text("Off").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var dormantStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(.yellow).frame(width: 7, height: 7)
                Text("Waiting for sun").font(.subheadline)
                Spacer()
            }
            // Progress bar showing how close brightness is to the engage threshold.
            ProgressView(value: manager.engageProgress)
                .progressViewStyle(.linear)
                .tint(progressTint)
        }
    }

    private var engagedStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(.orange).frame(width: 7, height: 7)
            Text("Boosting").font(.subheadline)
            Spacer()
            Text(String(format: "%.1f×", manager.currentEffectiveBoost))
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var batteryBlock: some View {
        switch manager.powerState {
        case .discharging(let timeRemaining):
            HStack(spacing: 8) {
                if manager.state == .engaged && manager.boostBoltCount > 0 {
                    HStack(spacing: 1) {
                        ForEach(0..<manager.boostBoltCount, id: \.self) { _ in
                            Image(systemName: "bolt.fill")
                                .font(.subheadline)
                                .foregroundStyle(.yellow)
                        }
                    }
                } else {
                    Image(systemName: "battery.\(manager.batteryPercent / 25 * 25)")
                        .foregroundStyle(batteryColor)
                        .font(.subheadline)
                }
                if let timeRemaining {
                    Text(timeRemaining)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(batteryColor)
                } else {
                    Text("\(manager.batteryPercent)%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(batteryColor)
                }
                Spacer()
            }
        case .charging:
            HStack(spacing: 8) {
                Image(systemName: "battery.100.bolt").foregroundStyle(.green).font(.subheadline)
                Text("Charging").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        case .charged:
            HStack(spacing: 8) {
                Image(systemName: "powerplug").foregroundStyle(.secondary).font(.subheadline)
                Text("Plugged in").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        case .unknown:
            EmptyView()
        }
    }

    private var todayBlock: some View {
        HStack(spacing: 14) {
            // Boost minutes today
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                Text(manager.dailyLog.formattedMinutes)
                    .monospacedDigit()
            }
            // Vitamin D %
            HStack(spacing: 4) {
                Image(systemName: "pills.fill").foregroundStyle(vitaminDColor)
                Text("\(manager.dailyLog.vitaminDPercent)%")
                    .monospacedDigit()
            }
            Spacer()
            // Sunset
            if let sunset = manager.solar.sunsetToday {
                HStack(spacing: 4) {
                    Image(systemName: "sunset.fill").foregroundStyle(.orange.opacity(0.7))
                    Text(formatTime(sunset))
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var locationPrompt: some View {
        Button("Grant location to track sun position") {
            manager.solar.openLocationSettings()
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
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

    private var progressTint: Color {
        // Pale at low brightness, warmer as we approach the engage threshold.
        if manager.engageProgress > 0.85 { return .orange }
        if manager.engageProgress > 0.6 { return .yellow }
        return .blue.opacity(0.5)
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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
