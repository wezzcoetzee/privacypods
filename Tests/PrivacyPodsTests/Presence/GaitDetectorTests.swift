import Foundation
import Testing
@testable import PrivacyPods

@Suite("Gait detection")
struct GaitDetectorTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// A head bobbing at `cadence` Hz on one axis, sampled at the ~50 Hz the AirPods deliver.
    /// The bias stands in for the residual offset CoreMotion leaves in `userAcceleration`, and
    /// proves the detector measures swing about the mean rather than about zero.
    private func walk(
        cadence: Double,
        amplitude: Double,
        seconds: TimeInterval,
        bias: Double = 0.2,
        from origin: Date
    ) -> [MotionSample] {
        let rate = 50.0
        return (0..<Int(seconds * rate)).map { step in
            let time = Double(step) / rate
            let value = bias + amplitude * sin(2 * .pi * cadence * time)
            return MotionSample(
                pose: .zero,
                userAcceleration: Vector3(x: 0.004, y: value, z: -0.003),
                timestamp: origin.addingTimeInterval(time)
            )
        }
    }

    private func detector(fed samples: [MotionSample]) -> GaitDetector {
        var detector = GaitDetector()
        for sample in samples { detector.ingest(sample) }
        return detector
    }

    @Test("A two-hertz bounce reads as walking")
    func walkingCadence() {
        #expect(detector(fed: walk(cadence: 2, amplitude: 0.08, seconds: 4, from: start)).isWalking)
        #expect(detector(fed: walk(cadence: 1.6, amplitude: 0.05, seconds: 4, from: start)).isWalking)
    }

    @Test("Sitting still is not walking")
    func stillness() {
        #expect(!detector(fed: walk(cadence: 2, amplitude: 0.008, seconds: 4, from: start)).isWalking)
    }

    @Test("Rhythms outside the walking band are ignored")
    func cadenceBand() {
        #expect(!detector(fed: walk(cadence: 0.5, amplitude: 0.12, seconds: 6, from: start)).isWalking)
        #expect(!detector(fed: walk(cadence: 5, amplitude: 0.12, seconds: 4, from: start)).isWalking)
    }

    @Test("Walking stops when the rhythm does")
    func stoppingClearsWalking() {
        var detector = GaitDetector()
        for sample in walk(cadence: 2, amplitude: 0.08, seconds: 4, from: start) { detector.ingest(sample) }
        #expect(detector.isWalking)

        let stopped = start.addingTimeInterval(4)
        for sample in walk(cadence: 2, amplitude: 0.005, seconds: 3, from: stopped) { detector.ingest(sample) }
        #expect(!detector.isWalking)
    }

    @Test("A break in the stream does not fabricate a rhythm")
    func streamGapClearsTheWindow() {
        var detector = GaitDetector()
        for sample in walk(cadence: 2, amplitude: 0.08, seconds: 4, from: start) { detector.ingest(sample) }
        #expect(detector.isWalking)

        let afterGap = start.addingTimeInterval(20)
        for sample in walk(cadence: 2, amplitude: 0.08, seconds: 1, from: afterGap) { detector.ingest(sample) }
        #expect(!detector.isWalking)
    }
}
