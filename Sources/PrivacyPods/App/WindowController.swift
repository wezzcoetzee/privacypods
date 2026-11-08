import AppKit
import SwiftUI

/// Opens the Settings and Status windows on demand and keeps at most one of each around.
/// The app has no dock icon and only a hidden main menu, so these are the only windows it shows.
///
/// Both windows size themselves to their content and cannot be resized or minimized, the way
/// macOS settings windows behave. In an accessory app a minimized window would land in the Dock
/// with no app icon beside it, which is an easy way to lose it.
///
/// A closed window is dropped rather than hidden. The Status view polls TCC for as long as it is
/// alive, and a cached window would keep its hosting view, and so that poll, running forever
/// behind a window nobody can see.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    private enum Kind: Hashable {
        case settings
        case status
    }

    private let coordinator: AppCoordinator
    private var windows: [Kind: NSWindow] = [:]

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        followCoverage()
    }

    /// While any display is covered, the app's own windows sit just above the sheet, so the
    /// "Allow…" or "Change Re-anchor Shortcut…" a covered display points at is never hidden by it. The rest
    /// of the time they are ordinary windows.
    private func followCoverage() {
        withObservationTracking {
            applyLevel()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followCoverage() }
        }
    }

    private func applyLevel() {
        let level = coordinator.isCovering ? NSWindow.Level(rawValue: BlurOverlayWindow.level.rawValue + 1) : .normal
        windows.values.forEach { $0.level = level }
    }

    func showSettings() {
        show(.settings, title: "PrivacyPods Settings") {
            SettingsView(coordinator: coordinator, settings: coordinator.settings)
        }
    }

    func showStatus() {
        show(.status, title: "PrivacyPods Status") {
            StatusView(coordinator: coordinator) { [weak self] in self?.showSettings() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }

    private func show(_ kind: Kind, title: String, content: () -> some View) {
        let window = windows[kind] ?? makeWindow(title: title, content: content())
        windows[kind] = window
        applyLevel()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, content: some View) -> NSWindow {
        let host = NSHostingController(rootView: content)
        // The window follows the content, including when a notice row appears or goes.
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = title
        // The title bar joins the black content instead of sitting on it as a gray strip.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
