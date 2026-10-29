import Foundation
@testable import PrivacyPods

/// A `TimeSource` under the test's control. Shared by every module's tests; treat it as
/// frozen so parallel implementers do not need to coordinate edits.
final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}
