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

/// An accessory-policy application: no dock icon, no main menu, no window until the user opens
/// Settings or Calibration from the status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private var coordinator: AppCoordinator?
    private var windows: WindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("PrivacyPods launched")

        let coordinator = ProviderFactory.makeCoordinator(settings: settings)
        let windows = WindowController(coordinator: coordinator)
        self.coordinator = coordinator
        self.windows = windows
        statusItemController = StatusItemController(coordinator: coordinator, windows: windows)
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
