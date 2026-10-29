import Foundation

/// The composition root. Builds every provider `AppCoordinator` needs and hands each one over
/// typed as its Core protocol, which is the only thing `AppCoordinator` is allowed to know
/// about. This file is the single place where a concrete implementation is named, so swapping
/// one out is a one-line change here.
@MainActor
enum ProviderFactory {
    static func makeCoordinator(settings: SettingsStore) -> AppCoordinator {
        // The auditor reports on Motion, and the tracker is the only thing that can prompt for
        // it: CoreMotion's prompt fires on the first `startDeviceMotionUpdates`.
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
