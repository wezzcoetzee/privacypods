import Foundation

/// An angle in degrees.
///
/// This exists so the radians CoreMotion hands out can never be silently mixed with the
/// degrees the rest of the app reasons about. Construct from radians with `init(radians:)`.
struct Degrees: Hashable, Sendable, Comparable {
    var value: Double

    init(_ value: Double) { self.value = value }
    init(radians: Double) { self.value = radians * 180 / .pi }

    var radians: Double { value * .pi / 180 }
    var magnitude: Double { abs(value) }

    /// The equivalent angle in `(-180, 180]`.
    ///
    /// Yaw wraps, so differences between two yaw readings must be normalised or a head turn
    /// across the wrap point reads as a 350 degree swing.
    var normalized: Degrees {
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped <= -180 { wrapped += 360 }
        return Degrees(wrapped)
    }

    static let zero = Degrees(0)

    static func < (lhs: Degrees, rhs: Degrees) -> Bool { lhs.value < rhs.value }
    static func + (lhs: Degrees, rhs: Degrees) -> Degrees { Degrees(lhs.value + rhs.value) }
    static func - (lhs: Degrees, rhs: Degrees) -> Degrees { Degrees(lhs.value - rhs.value) }
    static prefix func - (operand: Degrees) -> Degrees { Degrees(-operand.value) }
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

extension Degrees: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    init(integerLiteral value: Int) { self.init(Double(value)) }
    init(floatLiteral value: Double) { self.init(value) }
}

extension Degrees: CustomStringConvertible {
    var description: String { String(format: "%.1f°", value) }
}

/// Where the head is pointing, in the headphones' own reference frame.
///
/// Absolute values are meaningless: the frame is established when the motion stream starts and
/// drifts over minutes. Only offsets from a `DisplayAnchor` recorded in the same session mean
/// anything. Roll is not modelled; nothing in the app uses it.
struct HeadPose: Hashable, Sendable, Codable {
    /// Rotation about the vertical axis. Positive means the user turned to their left.
    var yaw: Degrees
    /// Rotation about the lateral axis. Positive means chin up.
    var pitch: Degrees

    static let zero = HeadPose(yaw: .zero, pitch: .zero)

    /// The shortest per-axis rotation from `other` to `self`, wrapped to `(-180, 180]`.
    func offset(from other: HeadPose) -> HeadPose {
        HeadPose(yaw: (yaw - other.yaw).normalized, pitch: (pitch - other.pitch).normalized)
    }
}

/// The region of head angles counted as "looking at this display".
///
/// A rectangular cone (independent yaw and pitch limits) rather than a circular one, because
/// displays are wider than they are tall and the head travels further horizontally.
struct AcceptanceCone: Hashable, Sendable, Codable {
    var yawHalfAngle: Degrees
    var pitchHalfAngle: Degrees

    static let `default` = AcceptanceCone(yawHalfAngle: 25, pitchHalfAngle: 20)

    /// How far into the cone an anchor offset sits: `0` is dead centre, `1` is the boundary,
    /// above `1` is outside. This is the tie-breaker when two displays' cones overlap; compare
    /// candidates on this value rather than on raw degrees, so a tall narrow cone and a wide
    /// short one are judged on the same scale.
    func normalizedDistance(_ offset: HeadPose) -> Double {
        max(offset.yaw.magnitude / max(yawHalfAngle.magnitude, .ulpOfOne),
            offset.pitch.magnitude / max(pitchHalfAngle.magnitude, .ulpOfOne))
    }

    func contains(_ offset: HeadPose) -> Bool { normalizedDistance(offset) <= 1 }
}

/// A three-axis reading in the device frame.
struct Vector3: Hashable, Sendable, Codable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vector3(x: 0, y: 0, z: 0)
}

/// One CoreMotion device-motion update, converted into the units the app reasons about.
struct MotionSample: Hashable, Sendable {
    var pose: HeadPose
    /// Gravity-removed acceleration in g. Gait detection looks for rhythm in this.
    var userAcceleration: Vector3
    var timestamp: Date
}
