import CoreMotion
import Foundation

/// Must be launched through LaunchServices: TCC checks the responsible process, so a terminal-launched
/// build SIGABRTs inside `startDeviceMotionUpdates` (see `spike/README.md`).
@MainActor
final class HeadphoneMotionTracker: HeadTrackingProviding {
    let events: AsyncStream<HeadTrackingEvent>

    var wearState: WearState { machine.state }

    private static let watchdogInterval: Duration = .milliseconds(250)

    private static let authorizationProbeTimeout: Duration = .seconds(2)

    private let continuation: AsyncStream<HeadTrackingEvent>.Continuation
    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue
    private var machine = WearStateMachine()
    private var watchdog: Task<Void, Never>?
    private var connectionDelegate: ConnectionDelegate?
    private var isRunning = false
    private var isProbingAuthorization = false
    private var hasDiscardedFirstSample = false
    /// Bumped on every `start()` so callbacks that land after their run ended are dropped.
    private var generation = 0

    init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))

        queue = OperationQueue()
        queue.name = "dev.wesley.privacypods.head-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    // MARK: - Authorization

    static var authorizationStatus: PermissionStatus {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    /// CoreMotion has no request call: the prompt fires on the first `startDeviceMotionUpdates`, so
    /// this opens the stream until the first sample or the timeout, then closes it.
    func requestAuthorization() async -> PermissionStatus {
        guard !isRunning, !isProbingAuthorization else { return Self.authorizationStatus }
        isProbingAuthorization = true
        defer { isProbingAuthorization = false }

        let (firstSample, arrived) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1))
        manager.startDeviceMotionUpdates(to: queue) { @Sendable _, _ in arrived.yield(()) }
        let timeout = Task {
            try? await Task.sleep(for: Self.authorizationProbeTimeout)
            arrived.finish()
        }

        for await _ in firstSample { break }
        timeout.cancel()

        // `start()` can claim the stream while the prompt is on screen; never stop a live run.
        if !isRunning { manager.stopDeviceMotionUpdates() }
        return Self.authorizationStatus
    }

    // MARK: - HeadTrackingProviding

    func start() {
        guard !isRunning else { return }

        let authorization = Self.authorizationStatus
        let started = WearStateMachine.Signal.started(
            authorization: authorization,
            headphonesAvailable: manager.isDeviceMotionAvailable
        )

        guard authorization != .denied else {
            // Nothing latched: access can be granted while running and the next start() must open the stream.
            apply(started)
            Log.headTracking.error("Motion access refused; head tracking stays idle.")
            return
        }

        isRunning = true
        hasDiscardedFirstSample = false
        generation &+= 1
        let generation = self.generation
        apply(started)

        // Close any probe's stream first so the run owns it.
        if isProbingAuthorization { manager.stopDeviceMotionUpdates() }

        let delegate = ConnectionDelegate { [weak self] connected in
            self?.headphones(connected: connected, generation: generation)
        }
        connectionDelegate = delegate
        manager.delegate = delegate
        manager.startConnectionStatusUpdates()

        // `@Sendable` stops the closure inheriting main actor isolation, which Swift 6 asserts at runtime.
        manager.startDeviceMotionUpdates(to: queue) { @Sendable [weak self] motion, error in
            let arrivedAt = Date()
            if let error {
                let failure = WearStateMachine.Failure(error)
                let description = error.localizedDescription
                Task { @MainActor in
                    self?.motionFailed(failure, description, generation: generation)
                }
                return
            }
            guard let motion else { return }
            let sample = MotionSample(motion, arrivedAt: arrivedAt)
            Task { @MainActor in self?.received(sample, generation: generation) }
        }

        startWatchdog()
        Log.headTracking.info("Head tracking started.")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        watchdog?.cancel()
        watchdog = nil
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        manager.delegate = nil
        connectionDelegate = nil

        apply(.stopped)
        Log.headTracking.info("Head tracking stopped.")
    }

    // MARK: - Stream plumbing

    private func isCurrent(_ generation: Int) -> Bool {
        isRunning && generation == self.generation
    }

    private func received(_ sample: MotionSample, generation: Int) {
        guard isCurrent(generation) else { return }
        apply(.sampleArrived, at: sample.timestamp)

        // The first sample of each run is bogus: it proves liveness but must not reach the classifier.
        guard hasDiscardedFirstSample else {
            hasDiscardedFirstSample = true
            return
        }
        continuation.yield(.sample(sample))
    }

    private func headphones(connected: Bool, generation: Int) {
        guard isCurrent(generation) else { return }
        apply(connected ? .headphonesConnected : .headphonesDisconnected)
    }

    private func motionFailed(
        _ failure: WearStateMachine.Failure,
        _ description: String,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        Log.headTracking.error("Head motion updates failed: \(description, privacy: .public)")

        // TCC can answer mid-stream with a generic error; the authorization status names the cause.
        let resolved: WearStateMachine.Failure =
            Self.authorizationStatus == .denied ? .notAuthorized : failure
        apply(.failed(resolved))
    }

    private func apply(_ signal: WearStateMachine.Signal, at now: Date = Date()) {
        guard let state = machine.apply(signal, at: now) else { return }
        Log.headTracking.info("Wear state: \(String(describing: state), privacy: .public)")
        continuation.yield(.wearState(state))
    }

    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.watchdogInterval) } catch { return }
                guard let self else { return }
                apply(.tick)
            }
        }
    }
}

// MARK: - CoreMotion bridging

private extension MotionSample {
    init(_ motion: CMDeviceMotion, arrivedAt: Date) {
        let acceleration = motion.userAcceleration
        self.init(
            pose: HeadPose(
                yaw: Degrees(radians: motion.attitude.yaw),
                pitch: Degrees(radians: motion.attitude.pitch)),
            userAcceleration: Vector3(x: acceleration.x, y: acceleration.y, z: acceleration.z),
            timestamp: arrivedAt
        )
    }
}

extension WearStateMachine.Failure {
    /// CoreMotion reports refusal via the handler error, with two different codes depending on the service.
    init(_ error: any Error) {
        let refusals: Set<UInt32> = [
            CMErrorNotAuthorized.rawValue,
            CMErrorMotionActivityNotAuthorized.rawValue,
        ]
        let error = error as NSError
        let refused = error.domain == CMErrorDomain && refusals.contains(UInt32(error.code))
        self = refused ? .notAuthorized : .unavailable
    }
}

private final class ConnectionDelegate: NSObject, CMHeadphoneMotionManagerDelegate {
    private let onChange: @Sendable @MainActor (Bool) -> Void

    init(onChange: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Log.headTracking.info("Headphones connected.")
        let onChange = onChange
        Task { @MainActor in onChange(true) }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Log.headTracking.info("Headphones disconnected.")
        let onChange = onChange
        Task { @MainActor in onChange(false) }
    }
}
