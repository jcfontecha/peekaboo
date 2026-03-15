import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Browser automation via Chrome DevTools Protocol (CDP) for DOM reads and OS-level input for interaction.
@available(macOS 14.0, *)
@MainActor
struct BrowserCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "browser",
        abstract: "Control Chromium tabs with CDP + native Peekaboo input",
        discussion: """
        Use CDP for DOM inspection/navigation and Peekaboo's native input APIs for interaction.

        Examples:
          peekaboo browser list
          peekaboo browser click "#submit"
          peekaboo browser type "//input[@name='q']" "hello"
          peekaboo browser navigate "https://example.com"
          peekaboo browser snapshot
        """,
        subcommands: [
            ListSubcommand.self,
            CoordsSubcommand.self,
            ClickSubcommand.self,
            HoldSubcommand.self,
            HoverSubcommand.self,
            TypeSubcommand.self,
            ScrollSubcommand.self,
            NavigateSubcommand.self,
            SnapshotSubcommand.self,
            EvaluateSubcommand.self,
            SelectSubcommand.self,
            WaitSubcommand.self,
            TextSubcommand.self,
        ],
        showHelpOnEmptyInvocation: true
    )
}

struct BrowserConnectionOptions: CommanderParsable, Sendable {
    @Option(name: .customLong("cdp-port"), help: "CDP port (default: 18800)")
    var cdpPort: Int = 18800

    @Option(name: .long, help: "Filter page targets by URL substring")
    var url: String?

    init() {}

    mutating func validate() throws {
        guard (1...65_535).contains(self.cdpPort) else {
            throw ValidationError("--cdp-port must be between 1 and 65535")
        }
    }
}

struct BrowserInteractionOptions: CommanderParsable, Sendable {
    @Option(help: "Cursor movement profile: human or linear")
    var profile: String = "human"

    @Option(help: "Cursor movement duration in milliseconds")
    var duration: Int?

    @Flag(name: .customLong("no-auto-focus"), help: "Disable auto-focus before OS-level input")
    var noAutoFocus = false

    @Flag(name: .customLong("ocr"), help: "Fallback to OCR when DOM query resolution fails")
    var ocr = false

    init() {}

    mutating func validate() throws {
        let normalizedProfile = self.profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard CursorMovementProfileSelection(rawValue: normalizedProfile) != nil else {
            throw ValidationError("--profile must be either 'human' or 'linear'")
        }
        self.profile = normalizedProfile

        if let duration = self.duration, duration < 0 {
            throw ValidationError("--duration must be non-negative")
        }
    }

    var cursorProfileSelection: CursorMovementProfileSelection {
        CursorMovementProfileSelection(rawValue: self.profile) ?? .human
    }

    var shouldAutoFocus: Bool {
        !self.noAutoFocus
    }
}

struct BrowserPoint: Codable, Sendable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: self.x, y: self.y)
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
}

struct BrowserRect: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var center: BrowserPoint {
        BrowserPoint(x: self.x + (self.width / 2.0), y: self.y + (self.height / 2.0))
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct BrowserResolvedElement: Codable, Sendable {
    let query: String
    let matchedBy: String
    let tagName: String
    let text: String?
    let role: String?
    let cssSelector: String?
    let xpath: String?
    let domRect: BrowserRect
    let domCenter: BrowserPoint
    let screenPoint: BrowserPoint
    let source: String
}

struct BrowserResolvedElementOutput: Codable {
    let success: Bool
    let targetUrl: String
    let element: BrowserResolvedElement
}

struct BrowserClickOutput: Codable {
    let success: Bool
    let action: String
    let targetUrl: String
    let point: BrowserPoint
    let matchedBy: String
}

struct BrowserTypeOutput: Codable {
    let success: Bool
    let targetUrl: String
    let point: BrowserPoint
    let textLength: Int
    let clearedFirst: Bool
    let inputMode: String
    let submitted: Bool
}

struct BrowserScrollOutput: Codable {
    let success: Bool
    let targetUrl: String
    let direction: String
    let amount: Int
    let onElement: BrowserResolvedElement?
}

struct BrowserNavigateOutput: Codable {
    let success: Bool
    let targetUrl: String
    let frameId: String?
    let loaderId: String?
}

struct BrowserWaitOutput: Codable {
    let success: Bool
    let found: Bool
    let targetUrl: String
    let elapsedMs: Int
    let element: BrowserResolvedElement?
}

struct BrowserTextOutput: Codable {
    let success: Bool
    let targetUrl: String
    let selector: String?
    let text: String
}

struct BrowserSelectOutput: Codable {
    let success: Bool
    let targetUrl: String
    let query: String
    let value: String
    let mode: String
}

struct BrowserListTargetOutput: Codable, Sendable {
    let id: String
    let type: String
    let title: String
    let url: String
    let wsURL: String?
}

struct BrowserListOutput: Codable {
    let success: Bool
    let cdpPort: Int
    let targetCount: Int
    let targets: [BrowserListTargetOutput]
}

struct BrowserEvaluateOutput: Encodable {
    let success: Bool
    let targetUrl: String
    let valueType: String?
    let value: Any?

    enum CodingKeys: String, CodingKey {
        case success
        case targetUrl
        case valueType
        case value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.success, forKey: .success)
        try container.encode(self.targetUrl, forKey: .targetUrl)
        try container.encodeIfPresent(self.valueType, forKey: .valueType)

        if let value = self.value {
            try container.encode(JSONValue(value), forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
    }
}

struct BrowserSnapshotOutput: Encodable {
    let success: Bool
    let targetUrl: String
    let snapshot: Any

    enum CodingKeys: String, CodingKey {
        case success
        case targetUrl
        case snapshot
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.success, forKey: .success)
        try container.encode(self.targetUrl, forKey: .targetUrl)
        try container.encode(JSONValue(self.snapshot), forKey: .snapshot)
    }
}

enum BrowserQueryStrategy: String {
    case auto
    case css
    case xpath
    case text

    static func infer(from query: String) -> BrowserQueryStrategy {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/") || trimmed.hasPrefix("(") {
            return .xpath
        }

        if trimmed.hasPrefix("#") ||
            trimmed.hasPrefix(".") ||
            trimmed.hasPrefix("[") ||
            trimmed.contains(":") ||
            trimmed.contains(">") ||
            trimmed.contains("[")
        {
            return .css
        }

        return .auto
    }
}
