// ABOUTME: Popover content. v0.6 experiment — stripped to its essential core. One header, one
// ABOUTME: SunView, one footer. Everything else (battery row, today row, sunset countdown,
// ABOUTME: location prompt) deliberately deferred to be re-earned in v0.7+ if needed.

import SwiftUI

struct SundialView: View {
    @Bindable var manager: SundialManager

    var body: some View {
        VStack(spacing: 14) {
            header
            Divider()
            SunView(manager: manager)
            Divider()
            footer
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(width: 240)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sundial")
                .font(.headline)
            Spacer()
            Toggle("", isOn: $manager.isOn)
                .toggleStyle(.switch)
                .labelsHidden()
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
}
