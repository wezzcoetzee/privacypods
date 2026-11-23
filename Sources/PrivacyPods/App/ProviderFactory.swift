import Foundation

@MainActor
enum ProviderFactory {
    static func makeCoordinator(settings: SettingsStore) -> AppCoordinator {
        // CoreMotion's prompt fires on the first `startDeviceMotionUpdates`, so only the tracker can prompt for Motion.
        let headTracking = HeadphoneMotionTracker()

        return AppCoordinator(
            headTracking: headTracking,
            inputActivity: InputActivityMonitor(),
            hotkey: ReanchorHotkeyMonitor(),
            gaze: GazeClassifier(cone: settings.settings.acceptanceCone, awayGrace: settings.settings.awayGrace),
            overlay: BlurOverlayController(),
            presence: PresenceEngine(),
            screenLock: ScreenLocker(),
            permissions: PermissionAuditor(motion: headTracking),
            settings: settings
        )
    }
}
