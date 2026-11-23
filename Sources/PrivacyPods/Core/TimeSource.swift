import Foundation

/// Only for types that own a timer they cannot hand to their caller. Pure state machines take
/// `now: Date` as a parameter instead.
protocol TimeSource: Sendable {
    var now: Date { get }
}

struct SystemTimeSource: TimeSource {
    var now: Date { Date() }
}
