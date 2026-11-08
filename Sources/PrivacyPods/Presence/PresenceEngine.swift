import Foundation

/// Combines head motion, gait, Bluetooth proximity, gaze and input into a `PresenceState`.
///
/// The engine is plumbing; the judgement lives in `AwayEvidence` and `GaitDetector`, which are
/// pure and tested. Its own jobs are to own the gait detector and the proximity monitor, to tick
/// once a second so that time-based evidence (an AirPods disconnect nobody has typed through)
/// resolves without waiting for an event, and to publish state changes.
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

    private let continuation: AsyncStream<PresenceState>.Continuation
    private let timeSource: any TimeSource
    private let proximity: BluetoothProximityMonitor
    private let tickInterval: TimeInterval
    private var gait: GaitDetector
    private var evidence: AwayEvidence
    private var ticker: Task<Void, Never>?

    init(
        configuration: AwayEvidence.Configuration = .default,
        gait: GaitDetector = GaitDetector(),
        proximity: BluetoothProximityMonitor? = nil,
        timeSource: any TimeSource = SystemTimeSource(),
        tickInterval: TimeInterval = 1
    ) {
        (events, continuation) = AsyncStream.makeStream()
        self.evidence = AwayEvidence(configuration: configuration)
        self.gait = gait
        self.proximity = proximity ?? BluetoothProximityMonitor(timeSource: timeSource)
        self.timeSource = timeSource
        self.tickInterval = tickInterval
    }

    deinit {
        continuation.finish()
    }

    func start() {
        guard ticker == nil else { return }
        // Proximity starts with the first worn sample instead (see `ingest`): it only corroborates
        // a walk-away from AirPods that were on, and listing paired devices raises the Bluetooth
        // prompt, which should come when the AirPods connect rather than the moment the app opens.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.tickInterval))
                guard !Task.isCancelled else { return }
                self.evaluate()
            }
        }
    }

    /// Stops and forgets everything. The app calls this on unlock, so a session that ended with
    /// the user away does not colour the one that starts when they come back.
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
            evidence.observe(wear: wear, at: timeSource.now)
            if !wear.isWorn { gait.reset() }
            if wear.isWorn, ticker != nil { proximity.start() }
        }
        evaluate()
    }

    func ingest(_ activity: InputActivity) {
        // `.sustained` implies `.activity`; both mean a human touched the machine.
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
        state = evidence.resolve(at: timeSource.now)
    }
}
