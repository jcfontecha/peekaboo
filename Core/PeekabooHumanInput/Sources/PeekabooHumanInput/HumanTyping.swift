import Foundation

public protocol TypingCadenceRandomSource: Sendable {
    func nextUnitInterval() -> Double
}

public struct SystemTypingCadenceRandomSource: TypingCadenceRandomSource {
    public init() {}

    public func nextUnitInterval() -> Double {
        Double.random(in: Double.leastNonzeroMagnitude..<1.0)
    }
}

public struct HumanTypingContext: Sendable {
    private enum Constants {
        static let logNormalSigma: Double = 0.35
        static let punctuationMultiplier: Double = 1.35
        static let digraphMultiplier: Double = 0.85
        static let thinkingWordInterval = 12
        static let thinkingPauseRange: ClosedRange<Double> = 0.3...0.5
    }

    public let baseDelay: TimeInterval
    private let random: any TypingCadenceRandomSource
    private var previousCharacter: Character?
    private var charactersInCurrentWord = 0
    private var wordsSincePause = 0

    public init(wordsPerMinute: Int, random: any TypingCadenceRandomSource = SystemTypingCadenceRandomSource()) {
        let normalizedWPM = max(wordsPerMinute, 40)
        self.baseDelay = 60.0 / (Double(normalizedWPM) * 5.0)
        self.random = random
    }

    public mutating func nextDelay(after character: Character?) -> TimeInterval {
        var delay = self.sampleLogNormal()

        if let character {
            if character.isWhitespaceLike || character.isPunctuationLike {
                delay *= Constants.punctuationMultiplier
            }
            if let previous = self.previousCharacter,
               previous.isWordCharacter,
               character.isWordCharacter
            {
                delay *= Constants.digraphMultiplier
            }
        }

        delay = self.clamp(delay)
        if let pause = self.consumeWordBoundary(after: character) { delay += pause }
        self.previousCharacter = character
        return delay
    }

    private mutating func consumeWordBoundary(after character: Character?) -> TimeInterval? {
        guard let character else { return nil }
        if character.isWordCharacter {
            self.charactersInCurrentWord += 1
            return nil
        }
        guard self.charactersInCurrentWord > 0 else { return nil }
        self.charactersInCurrentWord = 0
        self.wordsSincePause += 1
        guard self.wordsSincePause >= Constants.thinkingWordInterval else { return nil }
        self.wordsSincePause = 0
        return self.randomThinkingPause()
    }

    private mutating func sampleLogNormal() -> TimeInterval {
        let sigma = Constants.logNormalSigma
        let mu = log(self.baseDelay) - 0.5 * sigma * sigma
        let gaussian = Self.generateGaussian(using: self.random)
        return max(exp(mu + sigma * gaussian), self.baseDelay * 0.2)
    }

    private func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, self.baseDelay * 0.25), self.baseDelay * 3.5)
    }

    private func randomThinkingPause() -> TimeInterval {
        let range = Constants.thinkingPauseRange
        return range.lowerBound + (range.upperBound - range.lowerBound) * self.random.nextUnitInterval()
    }

    private static func generateGaussian(using random: any TypingCadenceRandomSource) -> Double {
        let u1 = max(random.nextUnitInterval(), Double.leastNonzeroMagnitude)
        let u2 = random.nextUnitInterval()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

extension Character {
    fileprivate var isPunctuationLike: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    fileprivate var isWordCharacter: Bool {
        self.isLetter || self.isNumber
    }

    fileprivate var isWhitespaceLike: Bool {
        self.isWhitespace || self == "\n" || self == "\t"
    }
}
