import Foundation

/// Detects walking from the rhythm in head acceleration.
///
/// Walking shows up in the AirPods as a steady 1.5–2.5 Hz bounce. The detector keeps a short
/// window of samples and asks, per axis: does this axis swing far enough to be motion rather
/// than noise, and does it cross its own mean at a walking cadence?
///
/// Per axis rather than on the magnitude of `userAcceleration`, because the device frame is
/// not aligned with the world — there is no axis that is reliably "vertical" — and taking the
/// magnitude folds the signal about zero, which doubles its apparent frequency.
struct GaitDetector {
    struct Configuration: Hashable, Sendable {
        /// Steps per second that count as walking.
        var cadence: ClosedRange<Double> = 1.5...2.5
        /// Minimum RMS deviation, in g, before a rhythm is motion rather than sensor noise.
        /// At rest the AirPods sit around ±0.01 g.
        var minimumAmplitude: Double = 0.03
        /// Both the analysis window and the "sustained for" requirement: the cadence has to hold
        /// across the whole window before it reads as walking.
        var window: TimeInterval = 2
        /// Samples further apart than this mean the stream restarted, so the window is dropped
        /// rather than joined across the gap.
        var maximumSampleGap: TimeInterval = 0.5
        /// How often the window is re-analysed. Samples arrive at ~50 Hz and the answer cannot
        /// change meaningfully between two of them.
        var evaluationInterval: TimeInterval = 0.25

        static let `default` = Configuration()
    }

    private let configuration: Configuration
    private var window: [(time: Date, acceleration: Vector3)] = []
    private var lastEvaluation: Date?

    private(set) var isWalking = false

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func ingest(_ sample: MotionSample) {
        if let last = window.last,
           sample.timestamp.timeIntervalSince(last.time) > configuration.maximumSampleGap {
            reset()
        }

        window.append((sample.timestamp, sample.userAcceleration))
        let cutoff = sample.timestamp.addingTimeInterval(-configuration.window)
        window.removeAll { $0.time < cutoff }

        guard shouldEvaluate(at: sample.timestamp) else { return }
        isWalking = windowShowsGait()
    }

    mutating func reset() {
        window.removeAll()
        lastEvaluation = nil
        isWalking = false
    }

    private mutating func shouldEvaluate(at time: Date) -> Bool {
        guard let lastEvaluation else {
            self.lastEvaluation = time
            return true
        }
        guard time.timeIntervalSince(lastEvaluation) >= configuration.evaluationInterval else { return false }
        self.lastEvaluation = time
        return true
    }

    private func windowShowsGait() -> Bool {
        guard let first = window.first, let last = window.last,
              last.time.timeIntervalSince(first.time) >= configuration.window * 0.9,
              window.count >= 8
        else { return false }

        let times = window.map(\.time)
        let axes: [KeyPath<Vector3, Double>] = [\.x, \.y, \.z]
        return axes.contains { axis in
            hasWalkingCadence(window.map { $0.acceleration[keyPath: axis] }, at: times)
        }
    }

    /// Counts how often the axis swings back up through its own mean, and reads the cadence off
    /// the interval between those crossings. The hysteresis band scales with the signal, so a
    /// noisy-but-still axis cannot rattle out a plausible step rate.
    private func hasWalkingCadence(_ values: [Double], at times: [Date]) -> Bool {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let rms = variance.squareRoot()
        guard rms >= configuration.minimumAmplitude else { return false }

        let hysteresis = rms / 2
        var crossings: [Date] = []
        var belowBand = false
        for (value, time) in zip(values, times) {
            if value < mean - hysteresis {
                belowBand = true
            } else if belowBand, value > mean + hysteresis {
                crossings.append(time)
                belowBand = false
            }
        }

        guard crossings.count >= 3, let first = crossings.first, let last = crossings.last else { return false }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return false }
        return configuration.cadence.contains(Double(crossings.count - 1) / span)
    }
}
