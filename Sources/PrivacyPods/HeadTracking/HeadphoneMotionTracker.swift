import CoreMotion
import Foundation

/// `HeadTrackingProviding` on top of `CMHeadphoneMotionManager`.
///
/// The only place in the app that imports CoreMotion. Everything leaves here as Core value
/// types: `MotionSample` for each update and `WearState` whenever the answer to "can we read a
/// head right now" changes.
///
/// The app must be launched through LaunchServices. TCC checks the *responsible* process for
/// `NSMotionUsageDescription`, so a build run straight from a terminal is killed with SIGABRT
/// inside `startDeviceMotionUpdates` and no Swift error ever reaches the handler.
/// See `spike/README.md`.
@MainActor
final class HeadphoneMotionTracker: HeadTrackingProviding {
    let events: AsyncStream<HeadTrackingEvent>

    var wearState: WearState { machine.state }

    /// Frequent enough that a gap is noticed well inside the grace window the overlay applies
    /// on top of it.
    private static let watchdogInterval: Duration = .milliseconds(250)

    /// Long enough for TCC to put the prompt up and for the first sample to follow a grant,
    /// short enough that a refusal does not leave the sensor open.
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
    /// Bumped on every `start()`. CoreMotion callbacks hop to the main actor, so a sample can
    /// land after the run that produced it ended; stamping each run lets the late one be
    /// dropped instead of counting against the next run's first-sample discard.
    private var generation = 0

    init() {
        // ~50 Hz of samples; a bounded buffer keeps a stalled consumer from growing without
        // limit, and two seconds of backlog is already far more than anyone downstream wants.
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

    /// Puts the TCC prompt on screen and reports what it settled on.
    ///
    /// CoreMotion has no request call: the prompt fires on the first `startDeviceMotionUpdates`,
    /// so asking means opening the stream. This opens it only until the first sample arrives or
    /// the timeout expires, then closes it again, so asking about a permission never leaves the
    /// sensor running behind the app's own enabled/unlocked gate. Once access has been refused
    /// there is nothing left to prompt and `Permission.motion.settingsURL` is the only way back.
    func requestAuthorization() async -> PermissionStatus {
        // A live run already opened the stream, and a second probe would fight the first.
        guard !isRunning, !isProbingAuthorization else { return Self.authorizationStatus }
        isProbingAuthorization = true
        defer { isProbingAuthorization = false }

        let (firstSample, arrived) = AsyncStream.makeStream(of: Void.self,
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
            // Nothing is latched: access can be granted in System Settings while the app is
            // running, and the next start() has to be able to open the stream.
            apply(started)
            Log.headTracking.error("Motion access refused; head tracking stays idle.")
            return
        }

        isRunning = true
        hasDiscardedFirstSample = false
        generation &+= 1
        let generation = self.generation
        apply(started)

        // An authorization probe may still hold the stream open. Close it before installing the
        // run's handler, so the run owns the stream whatever CoreMotion does with a second
        // `startDeviceMotionUpdates` on an already-active manager.
        if isProbingAuthorization { manager.stopDeviceMotionUpdates() }

        let delegate = ConnectionDelegate { [weak self] connected in
            self?.headphones(connected: connected, generation: generation)
        }
        connectionDelegate = delegate
        manager.delegate = delegate
        manager.startConnectionStatusUpdates()

        // CoreMotion calls back on `queue`, not the main actor. `@Sendable` stops the closure from
        // inheriting this class's isolation, which Swift 6 would otherwise assert at runtime.
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

    /// Whether a callback stamped with `generation` still belongs to the run in progress.
    private func isCurrent(_ generation: Int) -> Bool {
        isRunning && generation == self.generation
    }

    private func received(_ sample: MotionSample, generation: Int) {
        guard isCurrent(generation) else { return }
        apply(.sampleArrived, at: sample.timestamp)

        // The first update of every run carries a bogus attitude and roughly 1 g of "user"
        // acceleration before the filter settles. It still proves the stream is alive, so it
        // feeds the wear state, but it must not reach the classifier.
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

    private func motionFailed(_ failure: WearStateMachine.Failure,
                              _ description: String,
                              generation: Int) {
        guard isCurrent(generation) else { return }
        Log.headTracking.error("Head motion updates failed: \(description, privacy: .public)")

        // TCC can answer while the stream is open, in which case the handler error itself is
        // generic and the authorization status is the only thing that names the cause.
        let resolved: WearStateMachine.Failure =
            Self.authorizationStatus == .denied ? .notAuthorized : failure
        apply(.failed(resolved))
    }

    private func apply(_ signal: WearStateMachine.Signal, at now: Date = Date()) {
        guard let state = machine.apply(signal, at: now) else { return }
        Log.headTracking.info("Wear state: \(String(describing: state), privacy: .public)")
        continuation.yield(.wearState(state))
    }

    /// Silence is the only thing AirPods do when they leave a head, so nobody downstream can
    /// ask about it; the tracker has to volunteer it.
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
    /// CoreMotion reports radians and a boot-relative timestamp. The app works in degrees and
    /// wall-clock arrival time, which is also the clock the gap watchdog measures against.
    ///
    /// `attitude.yaw` is rotation about the reference frame's vertical axis, so it is the head
    /// turning left and right whatever the AirPods' own axes are; `attitude.pitch` is the nod.
    /// Neither is meaningful in absolute terms — the frame is arbitrary and drifts — so only
    /// the offset from a `DisplayAnchor` is ever used.
    init(_ motion: CMDeviceMotion, arrivedAt: Date) {
        let acceleration = motion.userAcceleration
        self.init(
            pose: HeadPose(yaw: Degrees(radians: motion.attitude.yaw),
                           pitch: Degrees(radians: motion.attitude.pitch)),
            userAcceleration: Vector3(x: acceleration.x, y: acceleration.y, z: acceleration.z),
            timestamp: arrivedAt
        )
    }
}

extension WearStateMachine.Failure {
    /// CoreMotion reports a refusal on the update handler rather than by changing
    /// `authorizationStatus()`, and uses two different codes for it depending on which motion
    /// service refused. Everything else is the sensor being unavailable.
    init(_ error: any Error) {
        let refusals: Set<UInt32> = [CMErrorNotAuthorized.rawValue,
                                     CMErrorMotionActivityNotAuthorized.rawValue]
        let error = error as NSError
        let refused = error.domain == CMErrorDomain && refusals.contains(UInt32(error.code))
        self = refused ? .notAuthorized : .unavailable
    }
}

/// CoreMotion delivers connect and disconnect on the motion queue, so the delegate is a plain
/// object whose only job is to hop each callback onto the main actor.
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
