// ABOUTME: App entry — menu-bar-only (LSUIElement=YES in Info.plist suppresses the Dock icon).
// ABOUTME: NSApplicationDelegateAdaptor wires the status bar controller once the app finishes launching.

import SwiftUI

@main
struct SundialApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(manager: .shared)
    }
}
