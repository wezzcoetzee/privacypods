import Foundation

/// Has no timer: the grace window is measured in sample time, so when samples stop the tracker's
/// watchdog reports a gap and the answer becomes `.unknown` rather than ageing towards `.away`.
/// Only anchoring reads the clock, to know whether the newest pose is still the one being held.
@MainActor
final class GazeClassifier: GazeClassifying {
    let events: AsyncStream<GazeState>
    private(set) var state: GazeState = .unknown
    private var cone: AcceptanceCone
    private var awayGrace: TimeInterval

    var anchors: [DisplayID: DisplayAnchor] { store.anchors }

    /// A live sample is ~20 ms old; the slack is for a scheduling hiccup, not for the 1.5 s the
    /// tracker waits before calling a gap.
    private static let anchorFreshness: TimeInterval = 0.25

    private let time: any TimeSource
    private let continuation: AsyncStream<GazeState>.Continuation
    private var store = DisplayAnchorStore()
    private var latest: MotionSample?
    private var outsideSince: Date?

    init(cone: AcceptanceCone, awayGrace: TimeInterval, time: any TimeSource = SystemTimeSource()) {
        self.cone = cone
        self.awayGrace = awayGrace
        self.time = time
        (events, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    func ingest(_ event: HeadTrackingEvent) {
        switch event {
        case .sample(let sample):
            latest = sample
            classify(sample)
        case .wearState(let wear):
            guard !wear.isWorn else { return }
            // A sample gap keeps its anchors because the reference frame survives it. Losing the
            // headphones ends the session, and the next one starts in a new frame.
            if wear != .unknown(.sampleGap) { store.removeAll() }
            latest = nil
            outsideSince = nil
            transition(to: .unknown)
        }
    }

    func anchor(_ display: DisplayID, source: DisplayAnchor.Source) {
        guard let latest else {
            Log.gaze.debug("Ignoring \(String(describing: source), privacy: .public) anchor: no live head data")
            return
        }
        // The watchdog takes up to ~1.75 s to declare a gap; until then the newest sample may be
        // where the head was before the stream went quiet.
        let age = time.now.timeIntervalSince(latest.timestamp)
        guard age < Self.anchorFreshness else {
            Log.gaze.debug("Ignoring \(String(describing: source), privacy: .public) anchor: head data is \(age, format: .fixed(precision: 2)) s stale")
            return
        }
        store.record(latest.pose, for: display, source: source, at: latest.timestamp)
        classify(latest)
    }

    func retainOnly(_ displays: Set<DisplayID>) {
        store.retainOnly(displays)
        if let focused = state.display, !displays.contains(focused) {
            outsideSince = nil
            transition(to: .unknown)
        }
        reclassify()
    }

    func update(cone: AcceptanceCone, awayGrace: TimeInterval) {
        self.cone = cone
        self.awayGrace = awayGrace
        reclassify()
    }

    private func reclassify() {
        if let latest { classify(latest) }
    }

    private func classify(_ sample: MotionSample) {
        if let nearest = nearestAnchoredDisplay(to: sample.pose) {
            outsideSince = nil
            transition(to: .looking(nearest))
            return
        }
        // Calling this "away" would blur every display before the user has anchored one.
        guard !store.anchors.isEmpty else {
            outsideSince = nil
            transition(to: .unknown)
            return
        }
        let since = outsideSince ?? sample.timestamp
        outsideSince = since
        if sample.timestamp.timeIntervalSince(since) >= awayGrace { transition(to: .away) }
    }

    /// The display id breaks exact ties, so two identical anchors cannot flicker.
    private func nearestAnchoredDisplay(to pose: HeadPose) -> DisplayID? {
        store.anchors.values
            .map { (display: $0.display, distance: cone.normalizedDistance(pose.offset(from: $0.pose))) }
            .filter { $0.distance <= 1 }
            .min { ($0.distance, $0.display.rawValue) < ($1.distance, $1.display.rawValue) }?
            .display
    }

    private func transition(to next: GazeState) {
        guard next != state else { return }
        state = next
        Log.gaze.debug("Gaze \(String(describing: next), privacy: .public)")
        continuation.yield(next)
    }
}
