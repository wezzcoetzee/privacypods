import AppKit
import SwiftUI

/// Opens the Settings and Calibration windows on demand and keeps at most one of each around.
/// The app has no dock icon and no main menu, so these are the only windows it ever shows.
///
/// A closed window is dropped rather than hidden. The calibration view polls TCC for as long as
/// it is alive, and a cached window keeps its hosting view — and therefore that poll — running
/// forever behind a window nobody can see.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    private enum Kind: Hashable {
        case settings
        case calibration
    }

    private let coordinator: AppCoordinator
    private var windows: [Kind: NSWindow] = [:]

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func showSettings() {
        show(.settings, title: "PrivacyPods Settings", size: NSSize(width: 480, height: 420)) {
            SettingsView(coordinator: coordinator, settings: coordinator.settings)
        }
    }

    func showCalibration() {
        show(.calibration, title: "PrivacyPods Calibration", size: NSSize(width: 520, height: 560)) {
            CalibrationView(coordinator: coordinator)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }

    private func show(_ kind: Kind, title: String, size: NSSize, content: () -> some View) {
        let window = windows[kind] ?? makeWindow(title: title, size: size, content: content())
        windows[kind] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, size: NSSize, content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        window.center()
        return window
    }
}
