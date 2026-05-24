// ABOUTME: Popover content. v0.5 redesign — a single unified bar communicates the entire state:
// ABOUTME: continuous brightness fill (left) → 4 boost chunks (right). One visual replaces the
// ABOUTME: separate progress bar / boost multiplier / bolts the popover used to have.

import SwiftUI

struct SundialView: View {
    @Bindable var manager: SundialManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            UnifiedBar(manager: manager)

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
        .frame(width: 280)
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
    private var batteryBlock: some View {
        switch manager.powerState {
        case .discharging(let timeRemaining):
            HStack(spacing: 8) {
                Image(systemName: "battery.\(min(100, manager.batteryPercent / 25 * 25))")
                    .foregroundStyle(batteryColor)
                    .font(.subheadline)
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
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                Text(manager.dailyLog.formattedMinutes)
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                Image(systemName: "pills.fill").foregroundStyle(vitaminDColor)
                Text("\(manager.dailyLog.vitaminDPercent)%")
                    .monospacedDigit()
            }
            Spacer()
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

// MARK: - UnifiedBar

/// One bar that tells the entire story: continuous brightness fill on the left (filling toward
/// the engage threshold), discrete boost-intensity chunks on the right (lighting up as the sun
/// strengthens). Replaces what used to be a separate progress bar, boost label, and bolt count.
struct UnifiedBar: View {
    @Bindable var manager: SundialManager

    /// Thresholds at which each chunk lights. Engaged-at-floor lights chunk 0; peak boost
    /// lights all four. Mapped to the dynamic-boost range (1.5–3.0 ceiling).
    private let chunkThresholds: [Double] = [1.5, 2.0, 2.5, 2.8]

    var body: some View {
        HStack(spacing: 8) {
            brightnessBar
                .frame(height: 8)
                .frame(maxWidth: .infinity)

            HStack(spacing: 3) {
                ForEach(0..<chunkThresholds.count, id: \.self) { i in
                    Capsule()
                        .fill(chunkFill(at: i))
                        .frame(width: 9, height: 8)
                }
            }

            Text(readoutLabel)
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(readoutColor)
                .frame(width: 38, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.3), value: manager.engageProgress)
        .animation(.easeOut(duration: 0.3), value: manager.currentEffectiveBoost)
    }

    private var brightnessBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.18))
                Capsule()
                    .fill(brightnessGradient)
                    .frame(width: max(0, geo.size.width * manager.engageProgress))
            }
        }
    }

    private var brightnessGradient: LinearGradient {
        // Cool dim → warm bright. At fully engaged, the gradient reaches its warmest point.
        LinearGradient(
            colors: [Color.blue.opacity(0.35), .yellow.opacity(0.8), .orange],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func chunkFill(at index: Int) -> Color {
        guard manager.state == .engaged, manager.currentEffectiveBoost > 0 else {
            return .gray.opacity(0.18)
        }
        return manager.currentEffectiveBoost >= chunkThresholds[index] ? .orange : .gray.opacity(0.18)
    }

    private var readoutLabel: String {
        if !manager.isOn { return "Off" }
        if manager.state == .engaged {
            return String(format: "%.1f×", manager.currentEffectiveBoost)
        }
        return "—"
    }

    private var readoutColor: Color {
        if !manager.isOn { return .secondary }
        if manager.state == .engaged { return .orange }
        return .secondary
    }
}
