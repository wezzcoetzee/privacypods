import Foundation

/// Decides which display the user is looking at, by comparing the live head pose against the
/// anchor recorded for each display.
///
/// The classifier has no timer. Samples arrive at roughly 50 Hz and carry their own timestamps,
/// so the grace window is measured in sample time; when samples stop, the head tracker's
/// watchdog reports the gap and the answer becomes `.unknown` rather than ageing towards `.away`.
/// Anchoring is the one place that asks what time it is, because it has to know whether the pose
/// it is about to record is still the one the user is holding.
@MainActor
final class GazeClassifier: GazeClassifying {
    let events: AsyncStream<GazeState>
    private(set) var state: GazeState = .unknown
    private(set) var cone: AcceptanceCone
    private(set) var awayGrace: TimeInterval

    var anchors: [DisplayID: DisplayAnchor] { store.anchors }

    /// How stale the newest sample may be and still describe where the head is now. Samples
    /// arrive at roughly 50 Hz, so a live one is ~20 ms old; the slack is for a scheduling
    /// hiccup, not for the 1.5 s the head tracker waits before it calls a gap a gap.
    private static let anchorFreshness: TimeInterval = 0.25

    private let time: any TimeSource
    private let continuation: AsyncStream<GazeState>.Continuation
    private var store = DisplayAnchorStore()
    /// The newest sample, or `nil` while there is no trustworthy head data to anchor or judge.
    private var latest: MotionSample?
    /// When the pose first left every cone, or `nil` while it is inside one.
    private var outsideSince: Date?

    init(cone: AcceptanceCone = .default, awayGrace: TimeInterval = 0.7, time: any TimeSource = SystemTimeSource()) {
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
            // A short silence keeps its anchors: the reference frame survives it, and dropping
            // them would force a re-anchor every time the stream hiccups. Losing the headphones
            // themselves ends the session, and the next one starts in a new frame.
            if wear != .unknown(.sampleGap) { store.removeAll() }
            latest = nil
            outsideSince = nil
            transition(to: .unknown)
        }
    }

    func anchor(_ display: DisplayID, source: DisplayAnchor.Source) {
        // Every burst of typing tries to anchor, so a refusal here is the normal state of
        // affairs whenever the AirPods are off or quiet; it is a trace, not an event.
        guard let latest else {
            Log.gaze.debug("Ignoring \(String(describing: source), privacy: .public) anchor: no live head data")
            return
        }
        // The sample-gap watchdog takes up to ~1.75 s to declare a gap, and until it does the
        // newest sample is whatever the head was doing before the stream went quiet. Anchoring
        // a display to that pose would teach the app a lie and hold it until the next burst.
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
            // The grace window is there to smooth over glances, not to keep reporting a display
            // that has been unplugged.
            outsideSince = nil
            transition(to: .unknown)
        }
        reclassify()
    }

    /// Applies changed settings. Takes effect on the current pose rather than the next sample,
    /// so widening the cone in the settings window unblurs immediately.
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
        // With nothing anchored there is no basis for a judgement, and calling that "away" would
        // blur every display before the user has ever anchored one.
        guard !store.anchors.isEmpty else {
            outsideSince = nil
            transition(to: .unknown)
            return
        }
        let since = outsideSince ?? sample.timestamp
        outsideSince = since
        if sample.timestamp.timeIntervalSince(since) >= awayGrace { transition(to: .away) }
    }

    /// The anchored display whose cone the pose sits deepest inside, or `nil` if it is outside
    /// all of them. Candidates are compared on the fraction of their own cone they use, so a
    /// wide cone and a tall one are judged on the same scale; the display id breaks exact ties
    /// so two identical anchors cannot flicker against each other.
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
