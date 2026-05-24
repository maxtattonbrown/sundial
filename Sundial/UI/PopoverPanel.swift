// ABOUTME: Custom NSPanel for the menu bar popover — transparent, floating, non-activating.
// ABOUTME: Forked from ~/Projects/desk-controller/Sources/PopoverPanel.swift.

import AppKit
import SwiftUI

// MARK: - Panel

final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Hosting view that accepts the first mouse click — no "click to activate" dead click.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Status Bar Controller

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: PopoverPanel
    private let hostingView: ClickThroughHostingView<AnyView>
    private var clickMonitor: Any?
    private let manager: SundialManager
    private var iconObservation: NSKeyValueObservation?

    init(manager: SundialManager) {
        self.manager = manager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        panel = PopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 240),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = false

        let rootView = AnyView(SundialView(manager: manager))
        hostingView = ClickThroughHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true

        let container = NSView()
        container.wantsLayer = true
        panel.contentView = container
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        super.init()

        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
        }

        hostingView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidResize),
            name: NSView.frameDidChangeNotification, object: hostingView
        )

        // Refresh icon on a slow timer — the @Observable manager updates state internally
        // but we don't have a SwiftUI binding here. A 2s timer is plenty since icon changes
        // are coarse (dormant ↔ engaged ↔ low battery).
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
    }

    deinit {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    /// When the boost is pushing hard (effective > 2.0×), swap the menu bar icon for a 🕶️ emoji
    /// title. Otherwise use an SF Symbol sun, optionally warm-tinted by the day's accumulated
    /// boost minutes.
    private func updateMenuBarPresentation() {
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip(for: manager)
        manager.dailyLog.rolloverIfNeeded()

        let isWearingShades = manager.currentEffectiveBoost > 2.0

        if isWearingShades {
            // Emoji-as-title — the sun "puts on sunglasses." More legible than a composited
            // SF Symbol, and instantly recognisable.
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: "🕶️",
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
            return
        }

        button.attributedTitle = NSAttributedString()
        button.image = sunImage(for: manager)
    }

    private func sunImage(for manager: SundialManager) -> NSImage? {
        // Outline when dormant or off, filled when boosting, warning-filled when engaged + low battery.
        let baseName: String
        if !manager.isOn {
            baseName = "sun.max"
        } else if manager.batteryPercent < 30 && manager.state == .engaged {
            baseName = "sun.max.trianglebadge.exclamationmark"
        } else if manager.state == .engaged {
            baseName = "sun.max.fill"
        } else {
            baseName = "sun.max"
        }

        // Tan tint accumulates across the day's boost minutes, resets at midnight.
        let tan = manager.dailyLog.tanFraction
        if tan < 0.05 {
            let image = NSImage(systemSymbolName: baseName, accessibilityDescription: "Sundial")
            image?.isTemplate = true
            return image
        }

        let neutralGray = NSColor(white: 0.5, alpha: 1.0)
        let tint = neutralGray.blended(withFraction: tan, of: NSColor.systemOrange) ?? .systemOrange
        let config = NSImage.SymbolConfiguration(paletteColors: [tint])
        let image = NSImage(systemSymbolName: baseName, accessibilityDescription: "Sundial")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    private func tooltip(for manager: SundialManager) -> String {
        if !manager.isOn {
            return "Sundial — Off"
        }
        switch manager.state {
        case .dormant:
            return "Sundial — Waiting for sun"
        case .engaged:
            let strength = String(format: "%.1f×", manager.currentEffectiveBoost)
            if let cost = manager.batteryCostMinutesPerHour {
                return "Sundial — Boosting \(strength) (≈ −\(cost) min/hr battery)"
            }
            return "Sundial — Boosting \(strength)"
        }
    }

    private func refreshIcon() {
        updateMenuBarPresentation()
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let idealSize = hostingView.fittingSize
        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let x = buttonRect.midX - idealSize.width / 2
        let y = buttonRect.minY - idealSize.height - 4

        panel.setFrame(
            NSRect(x: x, y: y, width: idealSize.width, height: idealSize.height),
            display: true
        )
        panel.makeKeyAndOrderFront(nil)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    @objc private func contentDidResize() {
        guard panel.isVisible else { return }
        let idealSize = hostingView.fittingSize
        var frame = panel.frame
        let heightDiff = idealSize.height - frame.height
        frame.origin.y -= heightDiff
        frame.size = idealSize
        panel.setFrame(frame, display: true, animate: true)
    }
}
