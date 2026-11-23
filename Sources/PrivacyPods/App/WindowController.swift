import AppKit
import SwiftUI

/// A closed window is dropped, not hidden: a cached one would keep `StatusView`'s TCC poll running forever.
/// Not minimizable: in an accessory app a minimized window lands in the Dock with no app icon.
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

    /// While any display is covered, app windows sit just above the sheet so the row a covered display points at is not hidden.
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
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
