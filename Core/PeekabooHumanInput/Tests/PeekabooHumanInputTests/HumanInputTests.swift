import CoreGraphics
import PeekabooHumanInput
import Testing

struct HumanInputTests {
    @Test
    func `mouse paths are deterministic and land exactly`() {
        let path = HumanMousePathGenerator(
            start: CGPoint(x: 10, y: 20),
            target: CGPoint(x: 410, y: 220),
            duration: 500,
            stepsHint: 8,
            configuration: HumanMouseProfileConfiguration(randomSeed: 42)).generate()

        #expect(path.duration == 500)
        #expect(path.points.count == 8)
        #expect(path.points.last == CGPoint(x: 410, y: 220))
        #expect(path.points[0].x == 14.98743849235966)
        #expect(path.points[0].y == 23.844342155021792)
        #expect(path.points[4].x == 353.35216018976996)
        #expect(path.points[4].y == 193.87808357391822)
    }

    @Test
    func `typing cadence is deterministic with a supplied source`() {
        var context = HumanTypingContext(wordsPerMinute: 120, random: SequenceRandom([0.5, 0.25]))
        let delays = ["H", "i", "!"].map { context.nextDelay(after: Character($0)) }
        #expect(delays == [0.09405880633643425, 0.0799499853859691, 0.12697938855418625])
    }
}

private final class SequenceRandom: TypingCadenceRandomSource, @unchecked Sendable {
    private let values: [Double]
    private var index = 0

    init(_ values: [Double]) {
        self.values = values
    }

    func nextUnitInterval() -> Double {
        defer { self.index += 1 }
        return self.values[self.index % self.values.count]
    }
}
