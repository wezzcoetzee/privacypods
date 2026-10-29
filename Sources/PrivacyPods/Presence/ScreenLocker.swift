import CoreGraphics
import Foundation

/// Locks the screen, and tracks whether it is already locked.
///
/// Locking goes through `SACLockScreenImmediate` in the private `login.framework`. It is private
/// but has been stable for a decade and is what the lock-screen menu item itself calls; verified
/// to still resolve by `dlsym` on macOS 26.6. The old `CGSession -suspend` fallback is gone
/// rather than unused: `/System/Library/CoreServices/Menu Extras/User.menu` no longer exists on
/// macOS 26, so that path could only ever have failed.
///
/// The fallback is `pmset displaysleepnow`, which needs no private symbol and no permission.
/// **It sleeps the displays; it only locks if the user has "Require password after screen saver
/// begins or display is turned off" set to immediately.** That caveat is why it is the fallback
/// and not the primary, and why `lock()` reports whether anything took effect instead of
/// returning silently.
///
/// The lock state matters as much as the lock: nothing should blur a screen that is already
/// covered by the lock window, and the away timers have to be cleared on unlock.
@MainActor
final class ScreenLocker: ScreenLocking {
    private static let loginFrameworkPath =
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    private static let pmsetPath = "/usr/bin/pmset"

    let events: AsyncStream<Bool>

    private(set) var isLocked: Bool {
        didSet {
            guard isLocked != oldValue else { return }
            continuation.yield(isLocked)
        }
    }

    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
        isLocked = Self.screenIsLocked()
        observe("com.apple.screenIsLocked", locked: true)
        observe("com.apple.screenIsUnlocked", locked: false)
    }

    deinit {
        continuation.finish()
    }

    /// Locks the screen, reporting whether any mechanism took effect. `false` means the Mac is
    /// still showing whatever it was showing, which is worth surfacing rather than swallowing.
    @discardableResult
    func lock() -> Bool {
        if lockViaLoginFramework() { return true }
        Log.presence.error("Falling back to display sleep; this only locks if the password delay is immediate")
        return sleepDisplays()
    }

    /// The observers live as long as the app does, so they are never removed.
    private func observe(_ name: String, locked: Bool) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLocked = locked
            }
        }
    }

    private func lockViaLoginFramework() -> Bool {
        guard let handle = dlopen(Self.loginFrameworkPath, RTLD_LAZY) else {
            Log.presence.error("Could not open login.framework")
            return false
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            Log.presence.error("login.framework has no SACLockScreenImmediate")
            return false
        }

        let lockScreen = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        let status = lockScreen()
        guard status == 0 else {
            Log.presence.error("SACLockScreenImmediate failed with status \(status)")
            return false
        }
        return true
    }

    private func sleepDisplays() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmsetPath)
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
        } catch {
            Log.presence.error("pmset displaysleepnow failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Log.presence.error("pmset displaysleepnow exited \(process.terminationStatus)")
            return false
        }
        return true
    }

    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
