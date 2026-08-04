import CoreGraphics
import Foundation

/// Profiles controlling how mouse paths are generated.
public enum MouseMovementProfile: Sendable, Equatable, Codable {
    /// Linear interpolation between the current and target coordinate.
    case linear
    /// Human-style motion with eased velocity, micro-jitter, and subtle overshoot.
    case human(HumanMouseProfileConfiguration = .default)

    private enum CodingKeys: String, CodingKey { case kind, profile }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "linear":
            self = .linear
        case "human":
            let profile = try container.decodeIfPresent(HumanMouseProfileConfiguration.self, forKey: .profile) ??
                .default
            self = .human(profile)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown MouseMovementProfile kind: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear:
            try container.encode("linear", forKey: .kind)
        case let .human(profile):
            try container.encode("human", forKey: .kind)
            try container.encode(profile, forKey: .profile)
        }
    }
}

/// Tunable values for the human-style mouse movement profile.
public struct HumanMouseProfileConfiguration: Sendable, Equatable, Codable {
    public var jitterAmplitude: CGFloat
    public var overshootProbability: Double
    public var overshootFractionRange: ClosedRange<Double>
    public var settleRadius: CGFloat
    public var randomSeed: UInt64?

    public init(
        jitterAmplitude: CGFloat = 0.35,
        overshootProbability: Double = 0.2,
        overshootFractionRange: ClosedRange<Double> = 0.02...0.06,
        settleRadius: CGFloat = 6,
        randomSeed: UInt64? = nil)
    {
        self.jitterAmplitude = jitterAmplitude
        self.overshootProbability = overshootProbability
        self.overshootFractionRange = overshootFractionRange
        self.settleRadius = settleRadius
        self.randomSeed = randomSeed
    }

    public static let `default` = HumanMouseProfileConfiguration()
}

public struct HumanMousePath: Sendable, Equatable {
    public let points: [CGPoint]
    public let duration: Int

    public init(points: [CGPoint], duration: Int) {
        self.points = points
        self.duration = duration
    }
}

/// Peekaboo's deterministic human pointer generator, separated from event posting.
public struct HumanMousePathGenerator: Sendable {
    public let start: CGPoint
    public let target: CGPoint
    public let distance: CGFloat
    public let duration: Int
    public let stepsHint: Int
    public let configuration: HumanMouseProfileConfiguration

    public init(
        start: CGPoint,
        target: CGPoint,
        distance: CGFloat? = nil,
        duration: Int,
        stepsHint: Int,
        configuration: HumanMouseProfileConfiguration = .default)
    {
        self.start = start
        self.target = target
        self.distance = distance ?? hypot(target.x - start.x, target.y - start.y)
        self.duration = duration
        self.stepsHint = stepsHint
        self.configuration = configuration
    }

    public func generate() -> HumanMousePath {
        var rng = HumanMouseRandom(seed: self.configuration.randomSeed)
        let sampleCount = min(max(self.stepsHint, 1), 96)
        guard self.distance > 0.5, sampleCount > 1 else {
            return HumanMousePath(points: [self.target], duration: self.duration)
        }

        let delta = CGVector(dx: self.target.x - self.start.x, dy: self.target.y - self.start.y)
        let direction = CGVector(dx: delta.dx / self.distance, dy: delta.dy / self.distance)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let curveDirection: CGFloat = rng.nextSignedUnit() < 0 ? -1 : 1
        let curveMagnitude = min(self.distance * 0.10, 42)
            * CGFloat(rng.nextDouble(in: 0.55...1.0))
            * curveDirection

        let control1 = CGPoint(
            x: self.start.x + (delta.dx * 0.28) + (normal.dx * curveMagnitude),
            y: self.start.y + (delta.dy * 0.28) + (normal.dy * curveMagnitude))

        let shouldOvershoot = Self.shouldOvershoot(
            distance: self.distance,
            probability: self.configuration.overshootProbability,
            rng: &rng)
        let overshootDistance = shouldOvershoot
            ? self.distance * CGFloat(rng.nextDouble(in: self.configuration.overshootFractionRange))
            : 0
        let control2 = CGPoint(
            x: self.target.x + (direction.dx * overshootDistance) - (normal.dx * curveMagnitude * 0.22),
            y: self.target.y + (direction.dy * overshootDistance) - (normal.dy * curveMagnitude * 0.22))

        var samples: [CGPoint] = []
        samples.reserveCapacity(sampleCount)
        for index in 1...sampleCount {
            let time = CGFloat(index) / CGFloat(sampleCount)
            let progress = Self.minimumJerkProgress(time)
            var point = Self.cubicBezier(
                from: self.start,
                control1: control1,
                control2: control2,
                to: self.target,
                progress: progress)

            if index < sampleCount {
                let distanceRemaining = self.distance * (1 - progress)
                let settleTaper = min(1, distanceRemaining / max(self.configuration.settleRadius, 0.001))
                let jitter = CGFloat(rng.nextSignedUnit())
                    * self.configuration.jitterAmplitude
                    * CGFloat(sin(Double.pi * Double(progress)))
                    * settleTaper
                point.x += normal.dx * jitter
                point.y += normal.dy * jitter
            }
            samples.append(point)
        }

        samples[samples.count - 1] = self.target
        return HumanMousePath(points: samples, duration: self.duration)
    }

    private static func shouldOvershoot(
        distance: CGFloat,
        probability: Double,
        rng: inout HumanMouseRandom) -> Bool
    {
        guard distance > 120 else { return false }
        return rng.nextDouble() < probability
    }

    private static func minimumJerkProgress(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return (10 * pow(t, 3)) - (15 * pow(t, 4)) + (6 * pow(t, 5))
    }

    private static func cubicBezier(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        progress: CGFloat) -> CGPoint
    {
        let inverse = 1 - progress
        let startWeight = pow(inverse, 3)
        let control1Weight = 3 * pow(inverse, 2) * progress
        let control2Weight = 3 * inverse * pow(progress, 2)
        let endWeight = pow(progress, 3)
        return CGPoint(
            x: (start.x * startWeight) + (control1.x * control1Weight) +
                (control2.x * control2Weight) + (end.x * endWeight),
            y: (start.y * startWeight) + (control1.y * control1Weight) +
                (control2.y * control2Weight) + (end.y * endWeight))
    }
}

private struct HumanMouseRandom: RandomNumberGenerator {
    private var generator: SeededGenerator

    init(seed: UInt64?) {
        let resolvedSeed = seed ?? UInt64(Date().timeIntervalSinceReferenceDate * 1_000_000)
        self.generator = SeededGenerator(seed: resolvedSeed)
    }

    mutating func next() -> UInt64 {
        self.generator.next()
    }

    mutating func nextDouble() -> Double {
        Double(self.next()) / Double(UInt64.max)
    }

    mutating func nextSignedUnit() -> Double {
        (self.nextDouble() * 2) - 1
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let value = self.nextDouble()
        return (value * (range.upperBound - range.lowerBound)) + range.lowerBound
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x123_4567_89AB_CDEF : seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
