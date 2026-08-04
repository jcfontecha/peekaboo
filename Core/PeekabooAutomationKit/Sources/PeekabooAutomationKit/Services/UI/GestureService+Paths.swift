import CoreGraphics
import Foundation
import PeekabooFoundation
import PeekabooHumanInput

extension GestureService {
    func linearPath(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 1 else { return [end] }
        return (1...steps).map { step in
            let progress = Double(step) / Double(steps)
            let x = start.x + ((end.x - start.x) * progress)
            let y = start.y + ((end.y - start.y) * progress)
            return CGPoint(x: x, y: y)
        }
    }

    func buildGesturePath(
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
}

extension MouseMovementProfile {
    var logDescription: String {
        switch self {
        case .linear:
            "linear"
        case .human:
            "human"
        }
    }
}
