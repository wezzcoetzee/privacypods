import AppKit
import Observation

/// The menu bar item: an icon that reflects tracking/wear/gaze state, and the menu the spec
/// asks for (status line, enable toggle, re-anchor, blur mode picker, settings, quit).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let windows: WindowController

    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var blurModeItems: [BlurMode: NSMenuItem] = [:]

    init(coordinator: AppCoordinator, windows: WindowController) {
        self.coordinator = coordinator
        self.windows = windows
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "PrivacyPods")
        let menu = NSMenu()
        menu.delegate = self
        buildMenu(menu)
        statusItem.menu = menu

        observeState()
    }

    private func buildMenu(_ menu: NSMenu) {
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        enabledItem.target = self
        menu.addItem(enabledItem)

        let reanchor = NSMenuItem(title: "Re-anchor Now", action: #selector(reanchorNow), keyEquivalent: "")
        reanchor.target = self
        menu.addItem(reanchor)
        menu.addItem(.separator())

        let blurMenu = NSMenu()
        for mode in BlurMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectBlurMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            blurModeItems[mode] = item
            blurMenu.addItem(item)
        }
        let blurModeItem = NSMenuItem(title: "Blur Mode", action: nil, keyEquivalent: "")
        blurModeItem.submenu = blurMenu
        menu.addItem(blurModeItem)
        menu.addItem(.separator())

        let calibration = NSMenuItem(title: "Calibration…", action: #selector(openCalibration), keyEquivalent: "")
        calibration.target = self
        menu.addItem(calibration)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit PrivacyPods", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    /// Keeps the status item's icon current outside of menu clicks by re-subscribing to the
    /// `@Observable` coordinator every time a tracked property changes.
    private func observeState() {
        withObservationTracking {
            _ = coordinator.wearState
            _ = coordinator.gazeState
            _ = coordinator.presenceState
            // The away escalation can fail to lock on its own timer, with no other state moving.
            _ = coordinator.didFailToLock
            _ = coordinator.settings.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeState()
            }
        }
        refresh()
    }

    private func refresh() {
        statusLineItem.title = coordinator.statusLine
        enabledItem.state = coordinator.settings.settings.isEnabled ? .on : .off
        launchAtLoginItem.state = coordinator.settings.settings.launchAtLogin ? .on : .off
        let currentMode = coordinator.settings.settings.blurMode
        for (mode, item) in blurModeItems {
            item.state = mode == currentMode ? .on : .off
        }
        statusItem.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: coordinator.statusLine)
    }

    private var iconName: String {
        guard coordinator.settings.settings.isEnabled else { return "eye.slash" }
        guard !coordinator.presenceState.isAway else { return "figure.walk.departure" }
        guard coordinator.wearState.isWorn else { return "airpods.gen3" }
        switch coordinator.gazeState {
        case .looking: return "eye"
        case .away: return "eye.trianglebadge.exclamationmark"
        case .unknown: return "eye.slash"
        }
    }

    @objc private func toggleEnabled() {
        coordinator.setEnabled(!coordinator.settings.settings.isEnabled)
    }

    @objc private func toggleLaunchAtLogin() {
        coordinator.settings.settings.launchAtLogin.toggle()
    }

    @objc private func reanchorNow() {
        coordinator.reanchorNow()
    }

    @objc private func selectBlurMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? BlurMode else { return }
        coordinator.settings.settings.blurMode = mode
    }

    @objc private func openSettings() {
        windows.showSettings()
    }

    @objc private func openCalibration() {
        windows.showCalibration()
    }
}
