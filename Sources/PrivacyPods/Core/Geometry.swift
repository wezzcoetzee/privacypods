import Foundation

/// Exists so CoreMotion's radians can never be mixed with the degrees the rest of the app uses.
struct Degrees: Hashable, Sendable {
    var value: Double

    init(_ value: Double) { self.value = value }
    init(radians: Double) { self.value = radians * 180 / .pi }

    var magnitude: Double { abs(value) }

    /// Wrapped to `(-180, 180]`, so a head turn across the yaw wrap point is not a 350 degree swing.
    var normalized: Degrees {
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped <= -180 { wrapped += 360 }
        return Degrees(wrapped)
    }

    static func - (lhs: Degrees, rhs: Degrees) -> Degrees { Degrees(lhs.value - rhs.value) }
}

extension Degrees: Codable {
    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Double.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension Degrees: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self.init(Double(value)) }
}

/// In the headphones' own reference frame, which is set when the motion stream starts and drifts,
/// so only offsets from an anchor recorded in the same session mean anything.
struct HeadPose: Hashable, Sendable {
    /// Positive means the user turned to their left.
    var yaw: Degrees
    /// Positive means chin up.
    var pitch: Degrees

    func offset(from other: HeadPose) -> HeadPose {
        HeadPose(yaw: (yaw - other.yaw).normalized, pitch: (pitch - other.pitch).normalized)
    }
}

/// Rectangular rather than circular: displays are wider than they are tall.
struct AcceptanceCone: Hashable, Sendable, Codable {
    var yawHalfAngle: Degrees
    var pitchHalfAngle: Degrees

    static let `default` = AcceptanceCone(yawHalfAngle: 25, pitchHalfAngle: 20)

    /// `0` at dead centre, `1` on the boundary. Compare displays on this rather than raw degrees,
    /// so a wide cone and a tall one are judged on the same scale.
    func normalizedDistance(_ offset: HeadPose) -> Double {
        max(
            offset.yaw.magnitude / max(yawHalfAngle.magnitude, .ulpOfOne),
            offset.pitch.magnitude / max(pitchHalfAngle.magnitude, .ulpOfOne))
    }

    func contains(_ offset: HeadPose) -> Bool { normalizedDistance(offset) <= 1 }
}

struct Vector3: Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

struct MotionSample: Hashable, Sendable {
    var pose: HeadPose
    /// Gravity-removed, in g.
    var userAcceleration: Vector3
    var timestamp: Date
}
