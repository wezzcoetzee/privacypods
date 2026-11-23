import AppKit
import Observation

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    /// Internal so the UI snapshot harness can open the menu exactly as a click would.
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let windows: WindowController

    private let menu = NSMenu()
    private let statusLineItem = NSMenuItem()
    /// AppKit draws disabled items in the tertiary colour whatever the attributed title says, so the status line is a plain label.
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private static let detailWidth: CGFloat = 260
    private var transientItems: [NSMenuItem] = []
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let pauseMenu = NSMenu()
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
        let menuFontSize = NSFont.menuFont(ofSize: 0).pointSize
        statusLabel.font = .systemFont(ofSize: menuFontSize, weight: .semibold)
        statusLabel.textColor = .labelColor
        detailLabel.font = .menuFont(ofSize: menuFontSize)
        detailLabel.textColor = .labelColor
        detailLabel.maximumNumberOfLines = 0
        detailLabel.preferredMaxLayoutWidth = Self.detailWidth
        let stack = NSStackView(views: [statusLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        statusLineItem.view = stack
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        pauseMenu.addItem(action("For 1 Hour", #selector(pauseForAnHour)))
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

        // macOS 26 gives "Settings…" a gear and draws no custom menu images, so "Status…" gets none.
        menu.addItem(action("Status…", #selector(openStatus)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("About PrivacyPods", #selector(showAbout)))
        menu.addItem(action("PrivacyPods Help", #selector(showHelp)))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit PrivacyPods", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // TCC sends no change notifications; opening the menu is a cheap moment to ask again.
        coordinator.refreshPermissions()
        refresh()
    }

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
        let nextStep = status.nextStep(
            hotkey: coordinator.isReanchorHotkeyAvailable ? settings.reanchorHotkey.label : nil,
            canType: coordinator.canType
        )
        let detail = [status.effect, nextStep].compactMap { $0 }.joined(separator: " ")
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        statusLineItem.view?.setAccessibilityLabel(detail.isEmpty ? status.title : "\(status.title). \(detail)")
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
        reanchorItem.keyEquivalent = coordinator.isReanchorHotkeyAvailable ? settings.reanchorHotkey.keyEquivalent ?? "" : ""
        reanchorItem.keyEquivalentModifierMask = settings.reanchorHotkey.modifiers.eventFlags
        for (mode, item) in blurModeItems {
            item.state = mode == settings.blurMode ? .on : .off
        }

        let issues = coordinator.issues
        let icon = StatusIcon(status: status, issues: issues, coversView: coordinator.coversView)
        let issueNote = issues.contains(where: \.badgesIcon) ? ", needs attention" : ""
        statusItem.button?.image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: "PrivacyPods: \(status.summary)\(issueNote)")
        statusItem.button?.appearsDisabled = icon.isDimmed
    }

    private func rebuildTransientItems(status: AppStatus) {
        transientItems.forEach(menu.removeItem)
        transientItems = coordinator.issues.map { issue in
            let item: NSMenuItem
            switch issue {
            case .permission:
                item = action(issue.title, #selector(requestPermission(_:)))
            case .captureFailed:
                item = action(issue.title, #selector(retryCapture))
            case .hotkeyTaken:
                item = action(issue.title, #selector(openSettings))
            case .lockFailed, .lockUntested, .failModeUnchosen:
                item = action(issue.title, #selector(openStatus))
            }
            item.representedObject = issue
            return item
        }
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

    @objc private func showHelp() {
        NSWorkspace.shared.open(Self.helpURL)
    }

    private static let helpURL = URL(string: "https://github.com/wezzcoetzee/privacypods#supported-headphones")!

    @objc private func openStatus() {
        windows.showStatus()
    }

}
