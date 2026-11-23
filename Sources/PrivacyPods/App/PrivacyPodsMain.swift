import AppKit

@main
enum PrivacyPodsMain {
    @MainActor static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private var coordinator: AppCoordinator?
    private var windows: WindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test bundle is hosted inside the app; bail under XCTest so sensors, overlay and hotkey do not start.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Log.app.info("PrivacyPods launched")

        // A pause with no end does not outlive the app.
        if !settings.settings.isEnabled, settings.settings.resumeAt == nil {
            settings.settings.isEnabled = true
        }

        let coordinator = ProviderFactory.makeCoordinator(settings: settings)
        let windows = WindowController(coordinator: coordinator)
        self.coordinator = coordinator
        self.windows = windows
        statusItemController = StatusItemController(coordinator: coordinator, windows: windows)
        NSApp.mainMenu = makeMainMenu()
        coordinator.start()

        if shouldOpenStatus(coordinator.permissions) {
            windows.showStatus()
            UserDefaults.standard.set(true, forKey: Self.statusShownKey)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    private func shouldOpenStatus(_ permissions: any PermissionAuditing) -> Bool {
        !UserDefaults.standard.bool(forKey: Self.statusShownKey)
            || [.denied, .unavailable].contains(permissions.status(of: .motion))
    }

    private static let statusShownKey = "dev.wesley.privacypods.statusShownOnce"

    /// Hidden in an accessory app, but its key equivalents still reach the key window (⌘W, ⌘,).
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit PrivacyPods", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for submenu in [appMenu, windowMenu] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }

    @objc private func showSettings() {
        windows?.showSettings()
    }
}
