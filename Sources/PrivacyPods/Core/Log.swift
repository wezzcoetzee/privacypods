import os

/// One `Logger` per module, so `log stream --subsystem dev.wesley.privacypods` is readable.
enum Log {
    private static let subsystem = "dev.wesley.privacypods"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let headTracking = Logger(subsystem: subsystem, category: "head-tracking")
    static let gaze = Logger(subsystem: subsystem, category: "gaze")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let presence = Logger(subsystem: subsystem, category: "presence")
}
