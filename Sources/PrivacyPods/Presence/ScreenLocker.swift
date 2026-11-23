import CoreGraphics
import Foundation

/// Locks through `SACLockScreenImmediate` in the private `login.framework`: stable for a decade,
/// what the lock-screen menu item calls, and still resolving on macOS 26.6. (`CGSession -suspend`
/// is gone: `User.menu` no longer exists on macOS 26.)
///
/// The fallback, `pmset displaysleepnow`, only sleeps the displays. It locks only if "Require
/// password" is set to immediately, which is why `lock()` reports whether anything took effect.
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

    func lock() -> Bool {
        if lockViaLoginFramework() { return true }
        Log.presence.error("Falling back to display sleep; this only locks if the password delay is immediate")
        return sleepDisplays()
    }

    /// Never removed: they live as long as the app.
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
