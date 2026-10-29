import Foundation

/// "Now", injected so stateful drivers can be stepped in tests.
///
/// Pure state machines should take `now: Date` as a parameter instead of holding one of these.
/// Reach for `TimeSource` only where a type owns a timer it cannot hand off to its caller.
protocol TimeSource: Sendable {
    var now: Date { get }
}

struct SystemTimeSource: TimeSource {
    init() {}
    var now: Date { Date() }
}
