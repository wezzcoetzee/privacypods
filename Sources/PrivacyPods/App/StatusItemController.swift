import AppKit
import Observation

/// The menu bar item: a `StatusIcon`, and a menu that leads with the status line, then anything
/// the user needs to fix or know, then the controls.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    /// Internal so the UI snapshot harness can open the menu exactly as a click would.
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let windows: WindowController

    private let menu = NSMenu()
    private let statusLineItem = NSMenuItem()
    /// AppKit draws a disabled item in the tertiary colour whatever its attributed title says, and
    /// an enabled one highlights under the pointer. The status line is neither a control nor a
    /// footnote, so it is a plain label.
    private let statusLabel = NSTextField(labelWithString: "")
    /// Issue lines and the lock retry go straight after the status line and change with state, so
    /// they are rebuilt on every refresh rather than toggled.
    private var transientItems: [NSMenuItem] = []
    /// "Pause" with a submenu while running, "Resume" while paused: one slot, so the
    /// menu does not change length when the state flips.
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let pauseMenu = NSMenu()
    /// Anchors the display under the pointer, which is the one whose menu bar was just clicked.
    private let reanchorItem = NSMenuItem(title: "Anchor This Display", action: #selector(reanchorNow), keyEquivalent: "")
    private var blurModeItems: [BlurMode: NSMenuItem] = [:]
    private let blurModeItem = NSMenuItem(title: "Blur", action: nil, keyEquivalent: "")

    init(coordinator: AppCoordinator, windows: WindowController) {
        self.coordinator = coordinator
        self.windows = windows
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        buildMenu()
        statusItem.menu = menu

        observeState()
    }

    private func buildMenu() {
        statusLabel.font = .systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold)
        statusLabel.textColor = .labelColor
        let container = NSView()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        statusLineItem.view = container
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        pauseMenu.addItem(action("For 1 Hour", #selector(pauseForAnHour)))
        // A pause with no end does not survive a restart, and the title says so.
        pauseMenu.addItem(action("Until I Resume or Quit", #selector(pauseUntilResumed)))
        pauseItem.target = self
        menu.addItem(pauseItem)
        reanchorItem.target = self
        menu.addItem(reanchorItem)

        let blurMenu = NSMenu()
        for mode in BlurMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(selectBlurMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            blurModeItems[mode] = item
            blurMenu.addItem(item)
        }
        blurModeItem.submenu = blurMenu
        menu.addItem(blurModeItem)
        menu.addItem(.separator())

        // macOS 26 gives "Settings…" a gear by itself and, in this build, draws no custom menu
        // images, so "Status…" cannot be given a matching one.
        menu.addItem(action("Status…", #selector(openStatus)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("About PrivacyPods", #selector(showAbout)))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit PrivacyPods", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // TCC sends no change notifications; opening the menu is a cheap moment to ask again.
        coordinator.refreshPermissions()
        refresh()
    }

    /// Keeps the icon current outside of menu clicks by re-subscribing to the `@Observable`
    /// coordinator every time a tracked property changes.
    private func observeState() {
        withObservationTracking {
            _ = coordinator.status
            _ = coordinator.issues
            _ = coordinator.coversView
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeState()
            }
        }
        refresh()
    }

    private func refresh() {
        let status = coordinator.status
        let settings = coordinator.settings.settings

        statusLabel.stringValue = status.title
        statusLineItem.view?.setAccessibilityLabel(status.title)
        statusLineItem.view?.toolTip = status.nextStep(
            hotkey: coordinator.isReanchorHotkeyAvailable ? settings.reanchorHotkey.label : nil,
            canType: coordinator.canType
        )
        statusLineItem.view?.frame.size = statusLineItem.view?.fittingSize ?? .zero
        rebuildTransientItems(status: status)

        blurModeItem.title = settings.blurMode == .off ? "Blur: Off" : "Blur"
        if settings.isEnabled {
            pauseItem.title = "Pause"
            pauseItem.action = nil
            pauseItem.submenu = pauseMenu
        } else {
            pauseItem.submenu = nil
            pauseItem.title = "Resume"
            pauseItem.action = #selector(resume)
        }
        reanchorItem.isEnabled = coordinator.canReanchor
        reanchorItem.toolTip = coordinator.canReanchor ? nil : "Needs PrivacyPods running and AirPods in."
        // A shortcut another app holds does nothing; showing it would advertise a dead key.
        reanchorItem.keyEquivalent = coordinator.isReanchorHotkeyAvailable ? settings.reanchorHotkey.keyEquivalent ?? "" : ""
        reanchorItem.keyEquivalentModifierMask = settings.reanchorHotkey.modifiers.eventFlags
        for (mode, item) in blurModeItems {
            item.state = mode == settings.blurMode ? .on : .off
        }

        let issues = coordinator.issues
        let icon = StatusIcon(status: status, issues: issues, coversView: coordinator.coversView)
        // Spoken the same way the badge is shown, so VoiceOver and sight agree on severity.
        let issueNote = issues.contains(where: \.badgesIcon) ? ", needs attention" : ""
        statusItem.button?.image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: "PrivacyPods: \(status.title)\(issueNote)")
        statusItem.button?.appearsDisabled = icon.isDimmed
    }

    private func rebuildTransientItems(status: AppStatus) {
        transientItems.forEach(menu.removeItem)
        transientItems = coordinator.issues.map { issue in
            let item: NSMenuItem
            switch issue {
            case .permission:
                // Asks straight away, with Status behind the prompt for the why.
                item = action(issue.title, #selector(requestPermission(_:)))
            case .captureFailed:
                item = action(issue.title, #selector(retryCapture))
            case .hotkeyTaken:
                item = action(issue.title, #selector(openSettings))
            case .lockFailed, .lockUntested:
                item = action(issue.title, #selector(openStatus))
            }
            item.representedObject = issue
            return item
        }
        // The status line, then the things to fix as their own group under it.
        if !transientItems.isEmpty { transientItems.append(.separator()) }
        for (offset, item) in transientItems.enumerated() {
            menu.insertItem(item, at: 2 + offset)
        }
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func pauseForAnHour() {
        coordinator.pause(for: 60 * 60)
    }

    @objc private func pauseUntilResumed() {
        coordinator.pause(for: nil)
    }

    @objc private func resume() {
        coordinator.resume()
    }

    @objc private func reanchorNow() {
        coordinator.reanchorAfterMenu()
    }

    @objc private func selectBlurMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? BlurMode else { return }
        coordinator.settings.settings.blurMode = mode
    }

    @objc private func openSettings() {
        windows.showSettings()
    }

    @objc private func requestPermission(_ sender: NSMenuItem) {
        guard case .permission(let permission) = sender.representedObject as? Issue else { return }
        windows.showStatus()
        coordinator.request(permission)
    }

    @objc private func retryCapture() {
        coordinator.retryCapture()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openStatus() {
        windows.showStatus()
    }

}
