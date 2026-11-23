import Foundation

/// Detects walking as a 1.5 to 2.5 Hz bounce in head acceleration.
///
/// Analysed per axis rather than on the magnitude: the device frame has no reliably vertical
/// axis, and the magnitude folds the signal about zero, which doubles its apparent frequency.
struct GaitDetector {
    private static let cadence: ClosedRange<Double> = 1.5...2.5
    /// RMS deviation in g. At rest the AirPods sit around ±0.01 g.
    private static let minimumAmplitude: Double = 0.03
    /// Also how long the cadence must hold before it reads as walking.
    private static let window: TimeInterval = 2
    /// Samples further apart than this mean the stream restarted; the window is dropped, not joined.
    private static let maximumSampleGap: TimeInterval = 0.5
    private static let evaluationInterval: TimeInterval = 0.25

    private var window: [(time: Date, acceleration: Vector3)] = []
    private var lastEvaluation: Date?

    private(set) var isWalking = false

    mutating func ingest(_ sample: MotionSample) {
        if let last = window.last, sample.timestamp.timeIntervalSince(last.time) > Self.maximumSampleGap {
            reset()
        }

        window.append((sample.timestamp, sample.userAcceleration))
        let cutoff = sample.timestamp.addingTimeInterval(-Self.window)
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
        guard time.timeIntervalSince(lastEvaluation) >= Self.evaluationInterval else { return false }
        self.lastEvaluation = time
        return true
    }

    private func windowShowsGait() -> Bool {
        guard let first = window.first, let last = window.last,
            last.time.timeIntervalSince(first.time) >= Self.window * 0.9,
            window.count >= 8
        else { return false }

        let times = window.map(\.time)
        let axes: [KeyPath<Vector3, Double>] = [\.x, \.y, \.z]
        return axes.contains { axis in
            hasWalkingCadence(window.map { $0.acceleration[keyPath: axis] }, at: times)
        }
    }

    /// Reads the cadence off upward crossings of the axis's own mean. The hysteresis band scales
    /// with the signal, so a noisy-but-still axis cannot rattle out a plausible step rate.
    private func hasWalkingCadence(_ values: [Double], at times: [Date]) -> Bool {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let rms = variance.squareRoot()
        guard rms >= Self.minimumAmplitude else { return false }

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
        return Self.cadence.contains(Double(crossings.count - 1) / span)
    }
}
