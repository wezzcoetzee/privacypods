import Foundation

/// Plumbing around `AwayEvidence` and `GaitDetector`. Ticks once a second so time-based evidence
/// (a disconnect nobody has typed through) resolves without waiting for an event.
@MainActor
final class PresenceEngine: PresenceProviding {
    let events: AsyncStream<PresenceState>

    private(set) var state: PresenceState = .unknown {
        didSet {
            guard state != oldValue else { return }
            Log.presence.debug("Presence \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)")
            continuation.yield(state)
        }
    }

    private static let tickInterval: Duration = .seconds(1)

    private let continuation: AsyncStream<PresenceState>.Continuation
    private let proximity = BluetoothProximityMonitor()
    private var gait = GaitDetector()
    private var evidence = AwayEvidence()
    private var ticker: Task<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    func start() {
        guard ticker == nil else { return }
        // Proximity starts with the first worn sample instead (see `ingest`): listing paired
        // devices raises the Bluetooth prompt, which should come when the AirPods connect.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.evaluate()
            }
        }
    }

    /// Forgets everything, so a session that ended with the user away does not colour the next.
    func stop() {
        ticker?.cancel()
        ticker = nil
        proximity.stop()
        gait.reset()
        evidence.reset()
        state = .unknown
    }

    func ingest(_ event: HeadTrackingEvent) {
        switch event {
        case .sample(let sample):
            gait.ingest(sample)
        case .wearState(let wear):
            evidence.observe(wear: wear, at: Date())
            if !wear.isWorn { gait.reset() }
            if wear.isWorn, ticker != nil { proximity.start() }
        }
        evaluate()
    }

    func ingest(_ activity: InputActivity) {
        evidence.observeInput(at: activity.timestamp)
        evaluate()
    }

    func ingest(gaze: GazeState) {
        evidence.observe(gaze: gaze)
        evaluate()
    }

    private func evaluate() {
        evidence.isWalking = gait.isWalking
        evidence.proximity = proximity.trend
        state = evidence.resolve(at: Date())
    }
}
