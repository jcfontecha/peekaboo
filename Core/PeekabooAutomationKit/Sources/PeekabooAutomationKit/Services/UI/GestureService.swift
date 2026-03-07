import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Service for handling gesture operations (swipe, drag, mouse movement)
@MainActor
public final class GestureService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "GestureService")

    public init() {}

    /// Perform a swipe gesture
    public func swipe(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        let gestureDescription = self.describeGesture(
            name: "Swipe requested",
            details: [
                "from: (\(from.x), \(from.y))",
                "to: (\(to.x), \(to.y))",
                "duration: \(duration)ms",
                "steps: \(steps)",
                "profile: \(profile.logDescription)",
            ])
        self.logger.debug("\(gestureDescription)")

        try self.ensurePositiveSteps(steps, action: "Swipe")

        let path = self.buildGesturePath(
            from: from,
            to: to,
            duration: duration,
            steps: steps,
            profile: profile)
        try await self.performSwipe(path: path, start: from, button: .left)

        self.logger.debug("Swipe completed")
    }

    // swiftlint:disable function_parameter_count
    /// Perform a drag operation with optional modifiers
    public func drag(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        modifiers: String?,
        profile: MouseMovementProfile) async throws
    {
        // Perform a drag operation with optional modifiers
        let gestureDescription = self.describeGesture(
            name: "Drag requested",
            details: [
                "from: (\(from.x), \(from.y))",
                "to: (\(to.x), \(to.y))",
                "duration: \(duration)ms",
                "modifiers: \(modifiers ?? "none")",
                "profile: \(profile.logDescription)",
            ])
        self.logger.debug("\(gestureDescription)")

        try self.ensurePositiveSteps(steps, action: "Drag")

        let path = self.buildGesturePath(
            from: from,
            to: to,
            duration: duration,
            steps: steps,
            profile: profile)
        try await self.performDrag(path: path, start: from)

        self.logger.debug("Drag completed")
    }

    // swiftlint:enable function_parameter_count

    /// Move mouse to a specific point
    public func moveMouse(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        let gestureDescription = self.describeGesture(
            name: "Mouse move requested",
            details: [
                "to: (\(to.x), \(to.y))",
                "duration: \(duration)ms",
                "steps: \(steps)",
                "profile: \(profile.logDescription)",
            ])
        self.logger.debug("\(gestureDescription)")

        try self.ensurePositiveSteps(steps, action: "Mouse move")

        let startPoint = self.getCurrentMouseLocation()
        let distance = hypot(to.x - startPoint.x, to.y - startPoint.y)

        switch profile {
        case .linear:
            let path = self.linearPath(from: startPoint, to: to, steps: steps)
            try await self.playPath(path, duration: duration)
        case let .human(configuration):
            let generator = HumanMousePathGenerator(
                start: startPoint,
                target: to,
                distance: distance,
                duration: duration,
                stepsHint: steps,
                configuration: configuration)
            let path = generator.generate()
            try await self.playPath(path.points, duration: path.duration)
        }

        self.logger.debug("Mouse move completed")
    }

    // MARK: - Private Methods

    private func getCurrentMouseLocation() -> CGPoint {
        // Prefer AXorcist InputDriver move-less lookup; default to .zero when unavailable
        InputDriver.currentLocation() ?? .zero
    }

    private func describeGesture(name: String, details: [String]) -> String {
        ([name] + details).joined(separator: " | ")
    }

    private func ensurePositiveSteps(_ steps: Int, action: String) throws {
        guard steps > 0 else {
            throw PeekabooError.invalidInput("\(action) requires at least one step")
        }
    }

    private func performSwipe(
        path: HumanMousePath,
        start: CGPoint,
        button: CGMouseButton) async throws
    {
        let endPoint = path.points.last ?? start
        let steps = max(path.points.count, 2)
        let interStepDelay = Double(path.duration) / 1000.0 / Double(steps)
        try InputDriver.drag(from: start, to: endPoint, button: .left, steps: steps, interStepDelay: interStepDelay)
    }

    private func performDrag(
        path: HumanMousePath,
        start: CGPoint) async throws
    {
        let endPoint = path.points.last ?? start
        let steps = max(path.points.count, 2)
        let delay = Double(path.duration) / 1000.0 / Double(steps)
        try InputDriver.drag(from: start, to: endPoint, button: .left, steps: steps, interStepDelay: delay)
    }

    private func linearPath(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 1 else { return [end] }
        return (1...steps).map { step in
            let progress = Double(step) / Double(steps)
            let x = start.x + ((end.x - start.x) * progress)
            let y = start.y + ((end.y - start.y) * progress)
            return CGPoint(x: x, y: y)
        }
    }

    private func buildGesturePath(
        from start: CGPoint,
        to end: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) -> HumanMousePath
    {
        let distance = hypot(end.x - start.x, end.y - start.y)
        switch profile {
        case .linear:
            return HumanMousePath(points: self.linearPath(from: start, to: end, steps: steps), duration: duration)
        case let .human(configuration):
            let generator = HumanMousePathGenerator(
                start: start,
                target: end,
                distance: distance,
                duration: duration,
                stepsHint: steps,
                configuration: configuration)
            return generator.generate()
        }
    }

    private func playPath(_ points: [CGPoint], duration: Int) async throws {
        guard !points.isEmpty else { return }
        let plan = GesturePlaybackPlan(sourcePoints: points, duration: duration)

        guard plan.duration > 0 else {
            try InputDriver.move(to: plan.samples.last ?? points.last!)
            return
        }

        let startUptime = DispatchTime.now().uptimeNanoseconds
        for (index, point) in plan.samples.enumerated() {
            let scheduledUptime = startUptime + plan.scheduledOffsetNanoseconds(for: index)
            let currentUptime = DispatchTime.now().uptimeNanoseconds
            if scheduledUptime > currentUptime {
                try await Task.sleep(nanoseconds: scheduledUptime - currentUptime)
            }
            try InputDriver.move(to: point)
        }
    }
}

struct GesturePlaybackPlan {
    let samples: [CGPoint]
    let duration: Int

    private let sampleCount: Int

    init(
        sourcePoints: [CGPoint],
        duration: Int,
        targetFrameIntervalMilliseconds: Int = 8,
        maximumSegmentLength: CGFloat = 1.5,
        maximumSamples: Int = 2_400)
    {
        self.duration = max(duration, 0)
        self.samples = Self.makeSamples(
            from: sourcePoints,
            duration: self.duration,
            targetFrameIntervalMilliseconds: targetFrameIntervalMilliseconds,
            maximumSegmentLength: maximumSegmentLength,
            maximumSamples: maximumSamples)
        self.sampleCount = self.samples.count
    }

    func scheduledOffsetNanoseconds(for sampleIndex: Int) -> UInt64 {
        guard self.duration > 0, self.sampleCount > 0 else { return 0 }
        let clampedIndex = min(max(sampleIndex + 1, 1), self.sampleCount)
        let durationNanoseconds = UInt64(self.duration) * 1_000_000
        return (durationNanoseconds * UInt64(clampedIndex)) / UInt64(self.sampleCount)
    }

    private static func makeSamples(
        from points: [CGPoint],
        duration: Int,
        targetFrameIntervalMilliseconds: Int,
        maximumSegmentLength: CGFloat,
        maximumSamples: Int) -> [CGPoint]
    {
        guard let lastPoint = points.last else { return [] }
        guard points.count > 1, duration > 0 else { return [lastPoint] }

        let sampleCount = self.sampleCount(
            for: points,
            duration: duration,
            targetFrameIntervalMilliseconds: targetFrameIntervalMilliseconds,
            maximumSegmentLength: maximumSegmentLength,
            maximumSamples: maximumSamples)

        return (1...sampleCount).map { sampleIndex in
            let progress = Double(sampleIndex) / Double(sampleCount)
            return self.interpolate(points: points, progress: progress)
        }
    }

    private static func sampleCount(
        for points: [CGPoint],
        duration: Int,
        targetFrameIntervalMilliseconds: Int,
        maximumSegmentLength: CGFloat,
        maximumSamples: Int) -> Int
    {
        let frameInterval = max(targetFrameIntervalMilliseconds, 1)
        let cadenceSamples = max(Int(ceil(Double(duration) / Double(frameInterval))), 1)
        let pathLength = zip(points, points.dropFirst()).reduce(CGFloat.zero) { partial, segment in
            partial + hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
        }
        let spatialSamples = max(Int(ceil(pathLength / max(maximumSegmentLength, 0.25))), 1)
        return min(max(points.count, cadenceSamples, spatialSamples), max(maximumSamples, 1))
    }

    private static func interpolate(points: [CGPoint], progress: Double) -> CGPoint {
        guard points.count > 1 else { return points.last ?? .zero }

        let clampedProgress = min(max(progress, 0), 1)
        let scaledIndex = clampedProgress * Double(points.count - 1)
        let lowerIndex = Int(floor(scaledIndex))
        let upperIndex = min(lowerIndex + 1, points.count - 1)
        guard upperIndex > lowerIndex else { return points[lowerIndex] }

        let segmentProgress = scaledIndex - Double(lowerIndex)
        let start = points[lowerIndex]
        let end = points[upperIndex]
        return CGPoint(
            x: start.x + ((end.x - start.x) * segmentProgress),
            y: start.y + ((end.y - start.y) * segmentProgress))
    }
}

extension MouseMovementProfile {
    fileprivate var logDescription: String {
        switch self {
        case .linear:
            "linear"
        case .human:
            "human"
        }
    }
}

private struct HumanMousePath {
    let points: [CGPoint]
    let duration: Int
}

private struct HumanMousePathGenerator {
    let start: CGPoint
    let target: CGPoint
    let distance: CGFloat
    let duration: Int
    let stepsHint: Int
    let configuration: HumanMouseProfileConfiguration

    func generate() -> HumanMousePath {
        var rng = HumanMouseRandom(seed: self.configuration.randomSeed)
        var current = self.start
        var velocity = CGVector(dx: 0, dy: 0)
        var wind = CGVector(dx: 0, dy: 0)
        var samples: [CGPoint] = []

        let resolvedDuration = self.resolvedDuration()
        let minimumSamples = max(stepsHint, Int(Double(resolvedDuration) / 8.0))
        let settleRadius = max(self.configuration.settleRadius, min(self.distance * 0.08, 24))

        var overshootTarget: CGPoint?
        if Self.shouldOvershoot(
            distance: self.distance,
            probability: self.configuration.overshootProbability,
            rng: &rng)
        {
            overshootTarget = self.makeOvershootTarget(distance: self.distance, rng: &rng)
        }
        var currentTarget = overshootTarget ?? self.target
        var overshootConsumed = overshootTarget == nil

        for _ in 0..<max(minimumSamples, 24) {
            let delta = CGVector(dx: currentTarget.x - current.x, dy: currentTarget.y - current.y)
            let distanceToTarget = max(0.001, hypot(delta.dx, delta.dy))
            let gravityMagnitude = Self.gravity(for: distanceToTarget)
            let gravity = CGVector(
                dx: (delta.dx / distanceToTarget) * gravityMagnitude,
                dy: (delta.dy / distanceToTarget) * gravityMagnitude)
            wind.dx = (wind.dx * 0.8) + (rng.nextSignedUnit() * Self.windMagnitude(for: distanceToTarget))
            wind.dy = (wind.dy * 0.8) + (rng.nextSignedUnit() * Self.windMagnitude(for: distanceToTarget))

            velocity.dx = (velocity.dx + wind.dx + gravity.dx) * 0.88
            velocity.dy = (velocity.dy + wind.dy + gravity.dy) * 0.88

            current.x += velocity.dx
            current.y += velocity.dy
            current = self.applyJitter(point: current, rng: &rng)
            samples.append(current)

            if distanceToTarget <= settleRadius {
                if overshootConsumed {
                    break
                } else {
                    currentTarget = self.target
                    overshootConsumed = true
                }
            }
        }

        samples.append(self.target)
        return HumanMousePath(points: samples, duration: resolvedDuration)
    }

    private func resolvedDuration() -> Int {
        if self.duration > 0 {
            return self.duration
        }

        let distanceFactor = log2(Double(self.distance) + 1) * 90
        let perPixel = Double(self.distance) * 0.45
        let estimate = 220 + distanceFactor + perPixel
        return min(max(Int(estimate), 250), 1600)
    }

    private func applyJitter(point: CGPoint, rng: inout HumanMouseRandom) -> CGPoint {
        let amplitude = Double(self.configuration.jitterAmplitude)
        return CGPoint(
            x: point.x + (rng.nextSignedUnit() * amplitude),
            y: point.y + (rng.nextSignedUnit() * amplitude))
    }

    private func makeOvershootTarget(distance: CGFloat, rng: inout HumanMouseRandom) -> CGPoint {
        let overshootFraction = rng.nextDouble(in: self.configuration.overshootFractionRange)
        let extraDistance = distance * CGFloat(overshootFraction)
        let direction = CGVector(dx: self.target.x - self.start.x, dy: self.target.y - self.start.y)
        let length = max(0.001, hypot(direction.dx, direction.dy))
        let normalized = CGVector(dx: direction.dx / length, dy: direction.dy / length)
        return CGPoint(
            x: self.target.x + (normalized.dx * extraDistance),
            y: self.target.y + (normalized.dy * extraDistance))
    }

    private static func shouldOvershoot(
        distance: CGFloat,
        probability: Double,
        rng: inout HumanMouseRandom) -> Bool
    {
        guard distance > 120 else { return false }
        return rng.nextDouble() < probability
    }

    private static func gravity(for distance: CGFloat) -> Double {
        let clamped = min(max(distance, 1), 800)
        return log(Double(clamped) + 2) * 1.8
    }

    private static func windMagnitude(for distance: CGFloat) -> Double {
        let normalized = min(max(distance / 400, 0.1), 1.0)
        return 0.6 * Double(normalized)
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
