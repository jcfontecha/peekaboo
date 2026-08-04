import Foundation
import PeekabooFoundation
import PeekabooHumanInput

extension TypeService {
    func sleepAfterKeystroke(
        typedCharacter: Character?,
        cadence: TypingCadence,
        fixedDelaySeconds: TimeInterval,
        humanContext: inout HumanTypingContext?) async throws
    {
        let delaySeconds: TimeInterval
        switch cadence {
        case .fixed:
            delaySeconds = fixedDelaySeconds
        case let .human(wordsPerMinute):
            if humanContext == nil {
                humanContext = HumanTypingContext(wordsPerMinute: wordsPerMinute, random: self.cadenceRandom)
            }
            delaySeconds = humanContext?.nextDelay(after: typedCharacter) ?? 0
        }

        guard delaySeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
    }

    func fixedDelaySeconds(for cadence: TypingCadence) -> TimeInterval {
        if case let .fixed(milliseconds) = cadence {
            return Double(max(0, milliseconds)) / 1000.0
        }
        return 0
    }
}

extension TypingCadence {
    var logDescription: String {
        switch self {
        case let .fixed(milliseconds):
            "fixed(\(milliseconds)ms)"
        case let .human(wordsPerMinute):
            "human(\(wordsPerMinute) WPM)"
        }
    }
}
