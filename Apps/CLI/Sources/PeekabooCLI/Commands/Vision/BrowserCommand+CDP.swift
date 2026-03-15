import AppKit
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

struct BrowserCDPTarget: Codable, Sendable {
    let id: String
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case url
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }

    var wsURL: URL? {
        guard let webSocketDebuggerURL,
              let value = URL(string: webSocketDebuggerURL) else {
            return nil
        }
        return value
    }

    var asListOutput: BrowserListTargetOutput {
        BrowserListTargetOutput(
            id: self.id,
            type: self.type,
            title: self.title,
            url: self.url,
            wsURL: self.webSocketDebuggerURL
        )
    }
}

struct BrowserSessionHandle {
    let target: BrowserCDPTarget
    let session: BrowserCDPSession
}

struct BrowserEvaluateResult {
    let value: Any?
    let type: String?
    let description: String?
    let objectId: String?
}

struct BrowserWindowMetrics {
    let screenX: Double
    let screenY: Double
    let outerHeight: Double
    let innerHeight: Double
    let visualOffsetLeft: Double
    let visualOffsetTop: Double
}

struct BrowserDOMMatch {
    let matchedBy: String
    let tagName: String
    let text: String?
    let role: String?
    let cssSelector: String?
    let xpath: String?
    let rect: BrowserRect
}

struct BrowserOCRMatch {
    let point: BrowserPoint
    let rect: BrowserRect
    let text: String
    let confidence: Float
}

struct BrowserElementInputState {
    let focused: Bool
    let value: String?
    let tagName: String?
    let type: String?
}

private struct BrowserCDPKeyEvent {
    let key: String
    let code: String
    let windowsVirtualKeyCode: Int
    let nativeVirtualKeyCode: Int?
    let text: String?
    let unmodifiedText: String?
}

enum BrowserCDP {
    static func fetchTargets(port: Int) async throws -> [BrowserCDPTarget] {
        let endpoint = URL(string: "http://127.0.0.1:\(port)/json")!
        let (data, response) = try await URLSession.shared.data(from: endpoint)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw PeekabooError.networkError("CDP endpoint returned a non-success status for \(endpoint.absoluteString)")
        }

        do {
            return try JSONDecoder().decode([BrowserCDPTarget].self, from: data)
        } catch {
            throw PeekabooError.encodingError("Failed to decode CDP targets: \(error.localizedDescription)")
        }
    }

    static func selectTarget(targets: [BrowserCDPTarget], urlFilter: String?) throws -> BrowserCDPTarget {
        let pageTargets = targets.filter { $0.type == "page" && $0.wsURL != nil }
        guard !pageTargets.isEmpty else {
            throw PeekabooError.elementNotFound("No page-type CDP targets found.")
        }

        if let urlFilter = urlFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !urlFilter.isEmpty {
            if let filtered = pageTargets.first(where: {
                $0.url.localizedCaseInsensitiveContains(urlFilter) ||
                    $0.title.localizedCaseInsensitiveContains(urlFilter)
            }) {
                return filtered
            }

            throw PeekabooError.elementNotFound(
                "No page target matched --url '\(urlFilter)'. Run 'peekaboo browser list' to inspect tabs."
            )
        }

        return pageTargets[0]
    }

    static func openSession(port: Int, urlFilter: String?) async throws -> BrowserSessionHandle {
        let targets = try await self.fetchTargets(port: port)
        let target = try self.selectTarget(targets: targets, urlFilter: urlFilter)
        guard let wsURL = target.wsURL else {
            throw PeekabooError.networkError("Target does not expose webSocketDebuggerUrl")
        }

        let session = BrowserCDPSession(url: wsURL)
        return BrowserSessionHandle(target: target, session: session)
    }
}

@MainActor
final class BrowserCDPSession {
    private let task: URLSessionWebSocketTask
    private var nextID = 1
    private var bufferedResponses: [Int: [String: Any]] = [:]

    init(url: URL) {
        self.task = URLSession.shared.webSocketTask(with: url)
        self.task.resume()
    }

    func close() {
        self.task.cancel(with: .goingAway, reason: nil)
    }

    func call(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = self.nextID
        self.nextID += 1

        let payloadObject: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]

        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw PeekabooError.encodingError("Failed to encode CDP payload for method \(method)")
        }

        try await self.task.send(.string(payloadText))

        if let cached = self.bufferedResponses.removeValue(forKey: id) {
            return try Self.extractResult(from: cached, method: method)
        }

        while true {
            let message = try await self.task.receive()
            let object = try Self.decodeMessage(message)
            guard let responseID = Self.intValue(from: object["id"]) else {
                continue // notification/event
            }

            if responseID == id {
                return try Self.extractResult(from: object, method: method)
            }

            self.bufferedResponses[responseID] = object
        }
    }

    func evaluate(
        expression: String,
        returnByValue: Bool = true,
        awaitPromise: Bool = true
    ) async throws -> BrowserEvaluateResult {
        let result = try await self.call(
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "returnByValue": returnByValue,
                "awaitPromise": awaitPromise,
                "userGesture": true,
            ]
        )

        if let exceptionDetails = result["exceptionDetails"] as? [String: Any] {
            let text = exceptionDetails["text"] as? String ?? "JavaScript evaluation failed"
            throw PeekabooError.commandFailed(text)
        }

        let remote = result["result"] as? [String: Any] ?? [:]
        let type = remote["type"] as? String
        let description = remote["description"] as? String
        let objectId = remote["objectId"] as? String

        var value = remote["value"]
        if value == nil,
           let unserializable = remote["unserializableValue"] as? String {
            value = unserializable
        }

        return BrowserEvaluateResult(
            value: value,
            type: type,
            description: description,
            objectId: objectId
        )
    }

    func insertText(_ text: String) async throws {
        guard !text.isEmpty else {
            return
        }
        _ = try await self.call(
            method: "Input.insertText",
            params: ["text": text]
        )
    }

    func dispatchSpecialKey(_ key: SpecialKey) async throws {
        guard let keyEvent = Self.keyEvent(for: key) else {
            throw PeekabooError.invalidInput("Special key '\(key.rawValue)' is not supported for CDP typing fallback.")
        }

        var keyDownPayload: [String: Any] = [
            "type": keyEvent.text == nil ? "rawKeyDown" : "keyDown",
            "key": keyEvent.key,
            "code": keyEvent.code,
            "windowsVirtualKeyCode": keyEvent.windowsVirtualKeyCode,
        ]
        if let nativeVirtualKeyCode = keyEvent.nativeVirtualKeyCode {
            keyDownPayload["nativeVirtualKeyCode"] = nativeVirtualKeyCode
        }
        if let text = keyEvent.text {
            keyDownPayload["text"] = text
        }
        if let unmodifiedText = keyEvent.unmodifiedText {
            keyDownPayload["unmodifiedText"] = unmodifiedText
        }

        _ = try await self.call(method: "Input.dispatchKeyEvent", params: keyDownPayload)

        var keyUpPayload: [String: Any] = [
            "type": "keyUp",
            "key": keyEvent.key,
            "code": keyEvent.code,
            "windowsVirtualKeyCode": keyEvent.windowsVirtualKeyCode,
        ]
        if let nativeVirtualKeyCode = keyEvent.nativeVirtualKeyCode {
            keyUpPayload["nativeVirtualKeyCode"] = nativeVirtualKeyCode
        }

        _ = try await self.call(method: "Input.dispatchKeyEvent", params: keyUpPayload)
    }

    private static func keyEvent(for key: SpecialKey) -> BrowserCDPKeyEvent? {
        switch key {
        case .return:
            return BrowserCDPKeyEvent(
                key: "Enter",
                code: "Enter",
                windowsVirtualKeyCode: 13,
                nativeVirtualKeyCode: 36,
                text: "\r",
                unmodifiedText: "\r"
            )
        case .enter:
            return BrowserCDPKeyEvent(
                key: "Enter",
                code: "NumpadEnter",
                windowsVirtualKeyCode: 13,
                nativeVirtualKeyCode: 76,
                text: "\r",
                unmodifiedText: "\r"
            )
        case .tab:
            return BrowserCDPKeyEvent(
                key: "Tab",
                code: "Tab",
                windowsVirtualKeyCode: 9,
                nativeVirtualKeyCode: 48,
                text: "\t",
                unmodifiedText: "\t"
            )
        case .escape:
            return BrowserCDPKeyEvent(
                key: "Escape",
                code: "Escape",
                windowsVirtualKeyCode: 27,
                nativeVirtualKeyCode: 53,
                text: nil,
                unmodifiedText: nil
            )
        case .delete:
            return BrowserCDPKeyEvent(
                key: "Backspace",
                code: "Backspace",
                windowsVirtualKeyCode: 8,
                nativeVirtualKeyCode: 51,
                text: nil,
                unmodifiedText: nil
            )
        case .forwardDelete:
            return BrowserCDPKeyEvent(
                key: "Delete",
                code: "Delete",
                windowsVirtualKeyCode: 46,
                nativeVirtualKeyCode: 117,
                text: nil,
                unmodifiedText: nil
            )
        case .space:
            return BrowserCDPKeyEvent(
                key: " ",
                code: "Space",
                windowsVirtualKeyCode: 32,
                nativeVirtualKeyCode: 49,
                text: " ",
                unmodifiedText: " "
            )
        case .leftArrow:
            return BrowserCDPKeyEvent(
                key: "ArrowLeft",
                code: "ArrowLeft",
                windowsVirtualKeyCode: 37,
                nativeVirtualKeyCode: 123,
                text: nil,
                unmodifiedText: nil
            )
        case .rightArrow:
            return BrowserCDPKeyEvent(
                key: "ArrowRight",
                code: "ArrowRight",
                windowsVirtualKeyCode: 39,
                nativeVirtualKeyCode: 124,
                text: nil,
                unmodifiedText: nil
            )
        case .upArrow:
            return BrowserCDPKeyEvent(
                key: "ArrowUp",
                code: "ArrowUp",
                windowsVirtualKeyCode: 38,
                nativeVirtualKeyCode: 126,
                text: nil,
                unmodifiedText: nil
            )
        case .downArrow:
            return BrowserCDPKeyEvent(
                key: "ArrowDown",
                code: "ArrowDown",
                windowsVirtualKeyCode: 40,
                nativeVirtualKeyCode: 125,
                text: nil,
                unmodifiedText: nil
            )
        case .pageUp:
            return BrowserCDPKeyEvent(
                key: "PageUp",
                code: "PageUp",
                windowsVirtualKeyCode: 33,
                nativeVirtualKeyCode: 116,
                text: nil,
                unmodifiedText: nil
            )
        case .pageDown:
            return BrowserCDPKeyEvent(
                key: "PageDown",
                code: "PageDown",
                windowsVirtualKeyCode: 34,
                nativeVirtualKeyCode: 121,
                text: nil,
                unmodifiedText: nil
            )
        case .home:
            return BrowserCDPKeyEvent(
                key: "Home",
                code: "Home",
                windowsVirtualKeyCode: 36,
                nativeVirtualKeyCode: 115,
                text: nil,
                unmodifiedText: nil
            )
        case .end:
            return BrowserCDPKeyEvent(
                key: "End",
                code: "End",
                windowsVirtualKeyCode: 35,
                nativeVirtualKeyCode: 119,
                text: nil,
                unmodifiedText: nil
            )
        case .f1:
            return BrowserCDPKeyEvent(key: "F1", code: "F1", windowsVirtualKeyCode: 112, nativeVirtualKeyCode: 122, text: nil, unmodifiedText: nil)
        case .f2:
            return BrowserCDPKeyEvent(key: "F2", code: "F2", windowsVirtualKeyCode: 113, nativeVirtualKeyCode: 120, text: nil, unmodifiedText: nil)
        case .f3:
            return BrowserCDPKeyEvent(key: "F3", code: "F3", windowsVirtualKeyCode: 114, nativeVirtualKeyCode: 99, text: nil, unmodifiedText: nil)
        case .f4:
            return BrowserCDPKeyEvent(key: "F4", code: "F4", windowsVirtualKeyCode: 115, nativeVirtualKeyCode: 118, text: nil, unmodifiedText: nil)
        case .f5:
            return BrowserCDPKeyEvent(key: "F5", code: "F5", windowsVirtualKeyCode: 116, nativeVirtualKeyCode: 96, text: nil, unmodifiedText: nil)
        case .f6:
            return BrowserCDPKeyEvent(key: "F6", code: "F6", windowsVirtualKeyCode: 117, nativeVirtualKeyCode: 97, text: nil, unmodifiedText: nil)
        case .f7:
            return BrowserCDPKeyEvent(key: "F7", code: "F7", windowsVirtualKeyCode: 118, nativeVirtualKeyCode: 98, text: nil, unmodifiedText: nil)
        case .f8:
            return BrowserCDPKeyEvent(key: "F8", code: "F8", windowsVirtualKeyCode: 119, nativeVirtualKeyCode: 100, text: nil, unmodifiedText: nil)
        case .f9:
            return BrowserCDPKeyEvent(key: "F9", code: "F9", windowsVirtualKeyCode: 120, nativeVirtualKeyCode: 101, text: nil, unmodifiedText: nil)
        case .f10:
            return BrowserCDPKeyEvent(key: "F10", code: "F10", windowsVirtualKeyCode: 121, nativeVirtualKeyCode: 109, text: nil, unmodifiedText: nil)
        case .f11:
            return BrowserCDPKeyEvent(key: "F11", code: "F11", windowsVirtualKeyCode: 122, nativeVirtualKeyCode: 103, text: nil, unmodifiedText: nil)
        case .f12:
            return BrowserCDPKeyEvent(key: "F12", code: "F12", windowsVirtualKeyCode: 123, nativeVirtualKeyCode: 111, text: nil, unmodifiedText: nil)
        case .capsLock:
            return BrowserCDPKeyEvent(
                key: "CapsLock",
                code: "CapsLock",
                windowsVirtualKeyCode: 20,
                nativeVirtualKeyCode: 57,
                text: nil,
                unmodifiedText: nil
            )
        case .clear:
            return BrowserCDPKeyEvent(
                key: "Clear",
                code: "NumpadClear",
                windowsVirtualKeyCode: 12,
                nativeVirtualKeyCode: 71,
                text: nil,
                unmodifiedText: nil
            )
        case .help:
            return BrowserCDPKeyEvent(
                key: "Help",
                code: "Help",
                windowsVirtualKeyCode: 47,
                nativeVirtualKeyCode: 114,
                text: nil,
                unmodifiedText: nil
            )
        }
    }

    private static func decodeMessage(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(raw):
            data = raw
        @unknown default:
            throw PeekabooError.encodingError("Unknown WebSocket message type")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PeekabooError.encodingError("Invalid CDP JSON payload")
        }
        return object
    }

    private static func extractResult(from response: [String: Any], method: String) throws -> [String: Any] {
        if let error = response["error"] as? [String: Any] {
            let code = Self.intValue(from: error["code"]) ?? -1
            let message = error["message"] as? String ?? "Unknown CDP error"
            throw PeekabooError.commandFailed("CDP \(method) failed (\(code)): \(message)")
        }

        if let result = response["result"] as? [String: Any] {
            return result
        }

        return [:]
    }

    private static func intValue(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }
}

@MainActor
struct BrowserCommandSupport {
    private static let focusCandidates = [
        "com.google.Chrome",
        "Google Chrome",
        "com.google.Chrome.canary",
        "Google Chrome Canary",
        "org.chromium.Chromium",
        "Chromium",
        "com.brave.Browser",
        "Brave Browser",
        "com.microsoft.edgemac",
        "Microsoft Edge",
        "company.thebrowser.Browser",
        "Arc",
    ]

    let runtime: CommandRuntime
    let connection: BrowserConnectionOptions

    var services: any PeekabooServiceProviding { self.runtime.services }
    var logger: Logger { self.runtime.logger }
    var jsonOutput: Bool { self.runtime.configuration.jsonOutput }

    func listTargets() async throws -> [BrowserCDPTarget] {
        try await BrowserCDP.fetchTargets(port: self.connection.cdpPort)
    }

    func openSession() async throws -> BrowserSessionHandle {
        try await BrowserCDP.openSession(port: self.connection.cdpPort, urlFilter: self.connection.url)
    }

    func prepare(session: BrowserCDPSession) async {
        _ = try? await session.call(method: "Runtime.enable")
        _ = try? await session.call(method: "Page.enable")
    }

    func ensureBrowserFocused(autoFocus: Bool) async {
        guard autoFocus else {
            return
        }

        for candidate in Self.focusCandidates {
            do {
                try await self.services.applications.activateApplication(identifier: candidate)
                try? await Task.sleep(nanoseconds: 120_000_000)
                return
            } catch {
                continue
            }
        }

        self.logger.warn(
            "Unable to auto-focus a known browser app. Continue with current foreground app or pass --no-auto-focus.",
            category: "Browser"
        )
    }

    func movementParameters(
        for target: CGPoint,
        interaction: BrowserInteractionOptions,
        defaultDuration: Int = 450,
        defaultSteps: Int = 20
    ) -> CursorMovementParameters {
        let currentLocation = NSEvent.mouseLocation
        let distance = hypot(target.x - currentLocation.x, target.y - currentLocation.y)
        return CursorMovementResolver.resolve(
            selection: interaction.cursorProfileSelection,
            durationOverride: interaction.duration,
            stepsOverride: nil,
            baseSmooth: true,
            distance: distance,
            defaultDuration: defaultDuration,
            defaultSteps: defaultSteps
        )
    }

    func clickOptions(
        for target: CGPoint,
        interaction: BrowserInteractionOptions,
        holdDuration: Int = 0
    ) -> ClickOptions {
        let movement = self.movementParameters(for: target, interaction: interaction)
        let clickMovement = ClickMovement(
            duration: movement.duration,
            steps: movement.steps,
            profile: movement.profile
        )
        return ClickOptions(movement: clickMovement, holdDuration: holdDuration)
    }

    func focusElementInDOM(
        resolved: BrowserResolvedElement,
        session: BrowserCDPSession
    ) async throws -> Bool {
        try await BrowserDOMResolver.focusElement(
            cssSelector: resolved.cssSelector,
            xpath: resolved.xpath,
            session: session
        )
    }

    func clearElementInDOM(
        resolved: BrowserResolvedElement,
        session: BrowserCDPSession
    ) async throws -> Bool {
        try await BrowserDOMResolver.clearElement(
            cssSelector: resolved.cssSelector,
            xpath: resolved.xpath,
            session: session
        )
    }

    func readElementInputState(
        resolved: BrowserResolvedElement,
        session: BrowserCDPSession
    ) async throws -> BrowserElementInputState? {
        try await BrowserDOMResolver.elementInputState(
            cssSelector: resolved.cssSelector,
            xpath: resolved.xpath,
            session: session
        )
    }

    func typeWithCDP(actions: [TypeAction], session: BrowserCDPSession) async throws {
        for action in actions {
            switch action {
            case let .text(text):
                try await session.insertText(text)
            case let .key(key):
                try await session.dispatchSpecialKey(key)
            case .clear:
                continue
            }
        }
    }

    func submitElementInDOM(
        resolved: BrowserResolvedElement,
        session: BrowserCDPSession
    ) async throws -> Bool {
        try await BrowserDOMResolver.submitElement(
            cssSelector: resolved.cssSelector,
            xpath: resolved.xpath,
            session: session
        )
    }

    func resolveElement(
        query: String,
        strategy: BrowserQueryStrategy = .auto,
        allowOCR: Bool,
        session: BrowserCDPSession
    ) async throws -> BrowserResolvedElement {
        if let domMatch = try await BrowserDOMResolver.resolveElement(
            query: query,
            strategy: strategy,
            session: session
        ) {
            let metrics = try await BrowserDOMResolver.windowMetrics(session: session)
            let screenPoint = BrowserDOMResolver.screenPoint(
                forDOMPoint: domMatch.rect.center,
                metrics: metrics
            )

            return BrowserResolvedElement(
                query: query,
                matchedBy: domMatch.matchedBy,
                tagName: domMatch.tagName,
                text: domMatch.text,
                role: domMatch.role,
                cssSelector: domMatch.cssSelector,
                xpath: domMatch.xpath,
                domRect: domMatch.rect,
                domCenter: domMatch.rect.center,
                screenPoint: screenPoint,
                source: "dom"
            )
        }

        if allowOCR,
           let ocrMatch = try await BrowserOCRResolver.resolve(query: query, services: self.services)
        {
            return BrowserResolvedElement(
                query: query,
                matchedBy: "ocr-text",
                tagName: "ocr_text",
                text: ocrMatch.text,
                role: "staticText",
                cssSelector: nil,
                xpath: nil,
                domRect: ocrMatch.rect,
                domCenter: ocrMatch.point,
                screenPoint: ocrMatch.point,
                source: "ocr"
            )
        }

        throw PeekabooError.elementNotFound(
            """
            No element matched query '\(query)'.
            Try a more specific selector, a shorter text fragment, or run `peekaboo browser snapshot --json` \
            to inspect visible nodes. If the element is in a lazy-loaded region, use `peekaboo browser wait "<query>"`.
            """
        )
    }
}

enum BrowserDOMResolver {
    static func resolveElement(
        query: String,
        strategy: BrowserQueryStrategy,
        session: BrowserCDPSession
    ) async throws -> BrowserDOMMatch? {
        let script = try BrowserDOMScripts.resolveElement(query: query, strategy: strategy)
        let evaluation = try await session.evaluate(expression: script)

        guard let dictionary = evaluation.value as? [String: Any] else {
            return nil
        }

        guard let rect = Self.parseRect(dictionary["rect"]) else {
            return nil
        }

        return BrowserDOMMatch(
            matchedBy: dictionary["matchedBy"] as? String ?? "unknown",
            tagName: dictionary["tagName"] as? String ?? "unknown",
            text: dictionary["text"] as? String,
            role: dictionary["role"] as? String,
            cssSelector: dictionary["cssSelector"] as? String,
            xpath: dictionary["xpath"] as? String,
            rect: rect
        )
    }

    static func windowMetrics(session: BrowserCDPSession) async throws -> BrowserWindowMetrics {
        let evaluation = try await session.evaluate(expression: BrowserDOMScripts.windowMetrics)
        guard let dictionary = evaluation.value as? [String: Any] else {
            throw PeekabooError.commandFailed("Failed to read browser window metrics")
        }

        return BrowserWindowMetrics(
            screenX: Self.double(dictionary["screenX"]) ?? 0,
            screenY: Self.double(dictionary["screenY"]) ?? 0,
            outerHeight: Self.double(dictionary["outerHeight"]) ?? 0,
            innerHeight: Self.double(dictionary["innerHeight"]) ?? 0,
            visualOffsetLeft: Self.double(dictionary["visualOffsetLeft"]) ?? 0,
            visualOffsetTop: Self.double(dictionary["visualOffsetTop"]) ?? 0
        )
    }

    static func snapshot(session: BrowserCDPSession) async throws -> Any {
        let evaluation = try await session.evaluate(expression: BrowserDOMScripts.snapshot)
        return evaluation.value ?? [:]
    }

    static func text(selector: String?, session: BrowserCDPSession) async throws -> String {
        let script = try BrowserDOMScripts.text(selector: selector)
        let evaluation = try await session.evaluate(expression: script)

        if let text = evaluation.value as? String {
            return text
        }

        if evaluation.value is NSNull || evaluation.value == nil {
            return ""
        }

        return String(describing: evaluation.value ?? "")
    }

    static func focusElement(
        cssSelector: String?,
        xpath: String?,
        session: BrowserCDPSession
    ) async throws -> Bool {
        let script = try BrowserDOMScripts.focusElement(cssSelector: cssSelector, xpath: xpath)
        let evaluation = try await session.evaluate(expression: script)
        guard let dictionary = evaluation.value as? [String: Any] else {
            return false
        }
        return (dictionary["focused"] as? Bool) ?? false
    }

    static func clearElement(
        cssSelector: String?,
        xpath: String?,
        session: BrowserCDPSession
    ) async throws -> Bool {
        let script = try BrowserDOMScripts.clearElement(cssSelector: cssSelector, xpath: xpath)
        let evaluation = try await session.evaluate(expression: script)
        guard let dictionary = evaluation.value as? [String: Any] else {
            return false
        }
        return (dictionary["cleared"] as? Bool) ?? false
    }

    static func elementInputState(
        cssSelector: String?,
        xpath: String?,
        session: BrowserCDPSession
    ) async throws -> BrowserElementInputState? {
        let script = try BrowserDOMScripts.inputState(cssSelector: cssSelector, xpath: xpath)
        let evaluation = try await session.evaluate(expression: script)
        guard let dictionary = evaluation.value as? [String: Any] else {
            return nil
        }
        guard (dictionary["exists"] as? Bool) == true else {
            return nil
        }

        return BrowserElementInputState(
            focused: (dictionary["focused"] as? Bool) ?? false,
            value: dictionary["value"] as? String,
            tagName: dictionary["tagName"] as? String,
            type: dictionary["type"] as? String
        )
    }

    static func submitElement(
        cssSelector: String?,
        xpath: String?,
        session: BrowserCDPSession
    ) async throws -> Bool {
        let script = try BrowserDOMScripts.submitElement(cssSelector: cssSelector, xpath: xpath)
        let evaluation = try await session.evaluate(expression: script)
        guard let dictionary = evaluation.value as? [String: Any] else {
            return false
        }
        return (dictionary["submitted"] as? Bool) ?? false
    }

    static func screenPoint(forDOMPoint point: BrowserPoint, metrics: BrowserWindowMetrics) -> BrowserPoint {
        let chromeInset = max(0.0, metrics.outerHeight - metrics.innerHeight)
        return BrowserPoint(
            x: metrics.screenX + metrics.visualOffsetLeft + point.x,
            y: metrics.screenY + chromeInset + metrics.visualOffsetTop + point.y
        )
    }

    private static func parseRect(_ value: Any?) -> BrowserRect? {
        guard let dictionary = value as? [String: Any],
              let x = self.double(dictionary["x"]),
              let y = self.double(dictionary["y"]),
              let width = self.double(dictionary["width"]),
              let height = self.double(dictionary["height"]) else {
            return nil
        }

        return BrowserRect(x: x, y: y, width: width, height: height)
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let text = value as? String {
            return Double(text)
        }
        return nil
    }
}

enum BrowserDOMScripts {
    static let windowMetrics = """
    (() => {
      const viewport = window.visualViewport;
      return {
        screenX: Number(window.screenX || 0),
        screenY: Number(window.screenY || 0),
        outerHeight: Number(window.outerHeight || 0),
        innerHeight: Number(window.innerHeight || 0),
        visualOffsetLeft: Number(viewport ? viewport.offsetLeft : 0),
        visualOffsetTop: Number(viewport ? viewport.offsetTop : 0)
      };
    })()
    """

    static let snapshot = """
    (() => {
      const MAX_NODES = 1200;
      const nodes = [];
      let truncated = false;

      function textFor(el) {
        const raw = (el.innerText || el.textContent || '').trim();
        return raw.length > 240 ? raw.slice(0, 240) : raw;
      }

      function roleFor(el) {
        return el.getAttribute('role') || null;
      }

      function isVisible(el) {
        const style = window.getComputedStyle(el);
        const rect = el.getBoundingClientRect();
        if (!rect || rect.width <= 0 || rect.height <= 0) return false;
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        if (Number(style.opacity || '1') <= 0.01) return false;
        return true;
      }

      function cssSelector(el) {
        if (!(el instanceof Element)) return null;
        if (el.id) return `#${el.id}`;
        const parts = [];
        let current = el;
        while (current && current.nodeType === Node.ELEMENT_NODE && parts.length < 8) {
          let part = current.tagName.toLowerCase();
          if (current.classList && current.classList.length > 0) {
            part += '.' + Array.from(current.classList).slice(0, 2).join('.');
          }
          const parent = current.parentElement;
          if (parent) {
            const siblings = Array.from(parent.children).filter(s => s.tagName === current.tagName);
            if (siblings.length > 1) {
              const index = siblings.indexOf(current) + 1;
              part += `:nth-of-type(${index})`;
            }
          }
          parts.unshift(part);
          current = current.parentElement;
        }
        return parts.join(' > ');
      }

      function xpathFor(el) {
        if (!(el instanceof Element)) return null;
        const segments = [];
        let current = el;
        while (current && current.nodeType === Node.ELEMENT_NODE) {
          const tag = current.tagName.toLowerCase();
          let index = 1;
          let sibling = current.previousElementSibling;
          while (sibling) {
            if (sibling.tagName === current.tagName) index += 1;
            sibling = sibling.previousElementSibling;
          }
          segments.unshift(`${tag}[${index}]`);
          current = current.parentElement;
        }
        return '/' + segments.join('/');
      }

      function pushNode(el, parentId, depth, offsetX, offsetY, scope) {
        if (nodes.length >= MAX_NODES) {
          truncated = true;
          return null;
        }

        const rect = el.getBoundingClientRect();
        const nodeId = nodes.length + 1;
        nodes.push({
          id: nodeId,
          parentId,
          depth,
          scope,
          tag: el.tagName.toLowerCase(),
          role: roleFor(el),
          text: textFor(el),
          selector: cssSelector(el),
          xpath: xpathFor(el),
          visible: isVisible(el),
          bounds: {
            x: rect.left + offsetX,
            y: rect.top + offsetY,
            width: rect.width,
            height: rect.height
          }
        });
        return nodeId;
      }

      function walkElement(el, parentId, depth, offsetX, offsetY, scope) {
        const nodeId = pushNode(el, parentId, depth, offsetX, offsetY, scope);
        if (nodeId == null) return;

        if (el.shadowRoot) {
          for (const child of Array.from(el.shadowRoot.children)) {
            walkElement(child, nodeId, depth + 1, offsetX, offsetY, 'shadow');
            if (truncated) return;
          }
        }

        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          try {
            const frameDoc = el.contentDocument;
            if (frameDoc && frameDoc.documentElement) {
              const frameRect = el.getBoundingClientRect();
              walkElement(
                frameDoc.documentElement,
                nodeId,
                depth + 1,
                offsetX + frameRect.left,
                offsetY + frameRect.top,
                'iframe'
              );
              if (truncated) return;
            }
          } catch (_) {
            // Cross-origin frame, skip.
          }
        }

        for (const child of Array.from(el.children)) {
          walkElement(child, nodeId, depth + 1, offsetX, offsetY, scope);
          if (truncated) return;
        }
      }

      if (document.documentElement) {
        walkElement(document.documentElement, null, 0, 0, 0, 'document');
      }

      return {
        url: window.location.href,
        title: document.title,
        nodeCount: nodes.length,
        truncated,
        nodes
      };
    })()
    """

    static func resolveElement(query: String, strategy: BrowserQueryStrategy) throws -> String {
        let input = try Self.jsonLiteral([
            "query": query,
            "strategy": strategy.rawValue,
        ])

        return """
        (() => {
          const input = \(input);
          const query = String(input.query || '').trim();
          const requested = String(input.strategy || 'auto');

          if (!query) return null;

          function normalize(value) {
            return String(value || '')
              .replace(/\\s+/g, ' ')
              .trim()
              .toLowerCase();
          }

          function inferStrategy(q) {
            if (q.startsWith('//') || q.startsWith('/') || q.startsWith('(')) return 'xpath';
            if (q.startsWith('#') || q.startsWith('.') || q.startsWith('[') || q.includes(':') || q.includes('>') || q.includes('=')) {
              return 'css';
            }
            return 'text';
          }

          function strategyOrder() {
            if (requested !== 'auto') return [requested];
            const primary = inferStrategy(query);
            return Array.from(new Set([primary, 'css', 'xpath', 'text']));
          }

          function isVisible(el) {
            if (!el || !(el instanceof Element)) return false;
            const style = window.getComputedStyle(el);
            const rect = el.getBoundingClientRect();
            if (!rect || rect.width <= 0 || rect.height <= 0) return false;
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (Number(style.opacity || '1') <= 0.01) return false;
            if (style.pointerEvents === 'none') return false;
            return true;
          }

          function isEnabled(el) {
            if (!('disabled' in el)) return true;
            return !el.disabled;
          }

          function textFor(el) {
            const raw = (el.innerText || el.textContent || '').trim();
            return raw.length > 240 ? raw.slice(0, 240) : raw;
          }

          function semanticText(el) {
            const pieces = [
              textFor(el),
              el.getAttribute('aria-label'),
              el.getAttribute('placeholder'),
              el.getAttribute('title'),
              el.getAttribute('alt'),
              el.getAttribute('name'),
              el.getAttribute('value'),
              el.id
            ].filter(Boolean);
            return pieces.join(' ');
          }

          function cssSelector(el) {
            if (!(el instanceof Element)) return null;
            if (el.id) return `#${el.id}`;
            const parts = [];
            let current = el;
            while (current && current.nodeType === Node.ELEMENT_NODE && parts.length < 8) {
              let part = current.tagName.toLowerCase();
              if (current.classList && current.classList.length > 0) {
                part += '.' + Array.from(current.classList).slice(0, 2).join('.');
              }
              const parent = current.parentElement;
              if (parent) {
                const siblings = Array.from(parent.children).filter(s => s.tagName === current.tagName);
                if (siblings.length > 1) {
                  const index = siblings.indexOf(current) + 1;
                  part += `:nth-of-type(${index})`;
                }
              }
              parts.unshift(part);
              current = current.parentElement;
            }
            return parts.join(' > ');
          }

          function xpathFor(el) {
            if (!(el instanceof Element)) return null;
            const segments = [];
            let current = el;
            while (current && current.nodeType === Node.ELEMENT_NODE) {
              const tag = current.tagName.toLowerCase();
              let index = 1;
              let sibling = current.previousElementSibling;
              while (sibling) {
                if (sibling.tagName === current.tagName) index += 1;
                sibling = sibling.previousElementSibling;
              }
              segments.unshift(`${tag}[${index}]`);
              current = current.parentElement;
            }
            return '/' + segments.join('/');
          }

          function scoreElement(el, strategy, needleNorm) {
            if (!isVisible(el)) return Number.NEGATIVE_INFINITY;
            const rect = el.getBoundingClientRect();
            const textNorm = normalize(semanticText(el));
            let score = 0;

            if (isEnabled(el)) score += 35;
            const tag = (el.tagName || '').toLowerCase();
            if (tag === 'input' || tag === 'textarea' || el.isContentEditable) score += 30;
            if (strategy === 'css') score += 10;
            if (strategy === 'xpath') score += 5;

            if (needleNorm) {
              if (textNorm === needleNorm) score += 320;
              else if (textNorm.startsWith(needleNorm)) score += 230;
              else if (textNorm.includes(needleNorm)) score += 140;

              const idNorm = normalize(el.id);
              if (idNorm && idNorm === needleNorm) score += 260;
              else if (idNorm && idNorm.includes(needleNorm)) score += 110;
            }

            const inViewport = rect.top >= 0 && rect.left >= 0 &&
              rect.bottom <= window.innerHeight && rect.right <= window.innerWidth;
            if (inViewport) score += 45;

            const area = Math.max(1, rect.width * rect.height);
            score += Math.min(55, area / 2_500);

            const viewportCenterX = window.innerWidth / 2;
            const viewportCenterY = window.innerHeight / 2;
            const centerX = rect.left + (rect.width / 2);
            const centerY = rect.top + (rect.height / 2);
            const distance = Math.hypot(centerX - viewportCenterX, centerY - viewportCenterY);
            score -= Math.min(90, distance / 25);

            if (document.activeElement === el) score += 80;

            return score;
          }

          function bestCandidate(candidates, strategy, needleNorm) {
            let best = null;
            let bestScore = Number.NEGATIVE_INFINITY;
            for (const candidate of candidates) {
              if (!(candidate instanceof Element)) continue;
              const score = scoreElement(candidate, strategy, needleNorm);
              if (score > bestScore) {
                bestScore = score;
                best = candidate;
              }
            }
            return best;
          }

          function buildMatch(el, matchedBy, offsetX, offsetY) {
            if (!el || !isVisible(el)) return null;
            const rect = el.getBoundingClientRect();
            return {
              matchedBy,
              tagName: el.tagName.toLowerCase(),
              text: textFor(el),
              role: el.getAttribute('role') || null,
              cssSelector: cssSelector(el),
              xpath: xpathFor(el),
              rect: {
                x: rect.left + offsetX,
                y: rect.top + offsetY,
                width: rect.width,
                height: rect.height
              }
            };
          }

          function cssCandidates(root, q) {
            const results = [];
            const seen = new Set();

            try {
              for (const el of Array.from(root.querySelectorAll(q))) {
                if (!seen.has(el)) {
                  seen.add(el);
                  results.push(el);
                }
              }
            } catch (_) {
              return [];
            }

            const all = root.querySelectorAll('*');
            for (const el of all) {
              if (!el.shadowRoot) continue;
              for (const nested of cssCandidates(el.shadowRoot, q)) {
                if (!seen.has(nested)) {
                  seen.add(nested);
                  results.push(nested);
                }
              }
            }
            return results;
          }

          function xpathCandidates(doc, q) {
            const results = [];
            try {
              const result = doc.evaluate(
                q,
                doc,
                null,
                XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
                null
              );
              for (let i = 0; i < result.snapshotLength; i += 1) {
                const node = result.snapshotItem(i);
                if (node instanceof Element) {
                  results.push(node);
                }
              }
            } catch (_) {
              return [];
            }
            return results;
          }

          function textMatches(el, needleNorm) {
            const candidateText = normalize(semanticText(el));
            if (!candidateText || !needleNorm) return false;
            return candidateText === needleNorm || candidateText.includes(needleNorm);
          }

          function textCandidates(root, needleNorm) {
            const queue = [];
            const results = [];
            if (root.documentElement) {
              queue.push(root.documentElement);
            } else if (root instanceof ShadowRoot || root instanceof Element) {
              queue.push(root);
            }

            while (queue.length > 0) {
              const current = queue.shift();
              if (!(current instanceof Element || current instanceof ShadowRoot)) {
                continue;
              }

              const children = Array.from(current.children || []);
              for (const child of children) {
                if (!(child instanceof Element)) {
                  continue;
                }

                if (textMatches(child, needleNorm)) {
                  results.push(child);
                }

                queue.push(child);
                if (child.shadowRoot) {
                  queue.push(child.shadowRoot);
                }
              }
            }

            return results;
          }

          function findInDocument(doc, offsetX, offsetY, needleNorm) {
            for (const strategy of strategyOrder()) {
              let matched = null;
              if (strategy === 'css') {
                matched = bestCandidate(cssCandidates(doc, query), strategy, needleNorm);
              } else if (strategy === 'xpath') {
                matched = bestCandidate(xpathCandidates(doc, query), strategy, needleNorm);
              } else if (strategy === 'text') {
                matched = bestCandidate(textCandidates(doc, needleNorm), strategy, needleNorm);
              }

              const candidate = buildMatch(matched, strategy, offsetX, offsetY);
              if (candidate) return candidate;
            }

            const frames = doc.querySelectorAll('iframe, frame');
            for (const frame of frames) {
              try {
                const childDoc = frame.contentDocument;
                if (!childDoc) continue;
                const frameRect = frame.getBoundingClientRect();
                const nested = findInDocument(
                  childDoc,
                  offsetX + frameRect.left,
                  offsetY + frameRect.top,
                  needleNorm
                );
                if (nested) return nested;
              } catch (_) {
                // Cross-origin frame, ignore.
              }
            }

            return null;
          }

          return findInDocument(document, 0, 0, normalize(query));
        })()
        """
    }

    static func text(selector: String?) throws -> String {
        let literal = try self.jsonLiteral(selector as Any)
        return """
        (() => {
          const selector = \(literal);
          if (selector) {
            const el = document.querySelector(selector);
            if (!el) return '';
            return String(el.innerText || el.textContent || '');
          }
          return String((document.body && document.body.innerText) || document.documentElement.innerText || '');
        })()
        """
    }

    static func focusElement(cssSelector: String?, xpath: String?) throws -> String {
        try self.elementAction(mode: "focus", cssSelector: cssSelector, xpath: xpath)
    }

    static func clearElement(cssSelector: String?, xpath: String?) throws -> String {
        try self.elementAction(mode: "clear", cssSelector: cssSelector, xpath: xpath)
    }

    static func inputState(cssSelector: String?, xpath: String?) throws -> String {
        try self.elementAction(mode: "state", cssSelector: cssSelector, xpath: xpath)
    }

    static func submitElement(cssSelector: String?, xpath: String?) throws -> String {
        try self.elementAction(mode: "submit", cssSelector: cssSelector, xpath: xpath)
    }

    private static func elementAction(mode: String, cssSelector: String?, xpath: String?) throws -> String {
        let payload: [String: Any] = [
            "mode": mode,
            "cssSelector": cssSelector ?? NSNull(),
            "xpath": xpath ?? NSNull(),
        ]
        let literal = try self.jsonLiteral(payload)

        return """
        (() => {
          const input = \(literal);

          function locateElement() {
            if (input.cssSelector) {
              try {
                const byCSS = document.querySelector(input.cssSelector);
                if (byCSS) return byCSS;
              } catch (_) {}
            }

            if (input.xpath) {
              try {
                const result = document.evaluate(
                  input.xpath,
                  document,
                  null,
                  XPathResult.FIRST_ORDERED_NODE_TYPE,
                  null
                );
                if (result && result.singleNodeValue instanceof Element) {
                  return result.singleNodeValue;
                }
              } catch (_) {}
            }

            return null;
          }

          function valueFor(el) {
            if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
              return String(el.value || '');
            }
            if (el.isContentEditable) {
              return String(el.textContent || '');
            }
            return null;
          }

          function focusElement(el) {
            if (!el || !(el instanceof Element)) return false;
            if (typeof el.focus === 'function') {
              try {
                el.focus({ preventScroll: true });
              } catch (_) {
                el.focus();
              }
            }
            return document.activeElement === el;
          }

          function dispatchInputEvents(el) {
            try {
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            } catch (_) {}
          }

          function normalizeTag(el) {
            return String(el.tagName || '').toLowerCase();
          }

          const el = locateElement();
          if (!(el instanceof Element)) {
            return { exists: false, focused: false, cleared: false, submitted: false };
          }

          if (input.mode === 'focus') {
            return {
              exists: true,
              focused: focusElement(el),
              tagName: normalizeTag(el),
              type: el.getAttribute('type') || null
            };
          }

          if (input.mode === 'clear') {
            focusElement(el);
            let cleared = false;
            if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
              el.value = '';
              dispatchInputEvents(el);
              cleared = true;
            } else if (el.isContentEditable) {
              el.textContent = '';
              dispatchInputEvents(el);
              cleared = true;
            }
            return {
              exists: true,
              focused: document.activeElement === el,
              cleared,
              value: valueFor(el),
              tagName: normalizeTag(el),
              type: el.getAttribute('type') || null
            };
          }

          if (input.mode === 'state') {
            return {
              exists: true,
              focused: document.activeElement === el,
              value: valueFor(el),
              tagName: normalizeTag(el),
              type: el.getAttribute('type') || null
            };
          }

          if (input.mode === 'submit') {
            focusElement(el);
            let submitted = false;

            if (el.form) {
              if (typeof el.form.requestSubmit === 'function') {
                el.form.requestSubmit();
                submitted = true;
              } else {
                try {
                  submitted = el.form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })) !== false;
                } catch (_) {}
              }
            }

            if (!submitted) {
              try {
                const down = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
                const press = new KeyboardEvent('keypress', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
                const up = new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
                el.dispatchEvent(down);
                el.dispatchEvent(press);
                el.dispatchEvent(up);
                submitted = true;
              } catch (_) {}
            }

            return {
              exists: true,
              focused: document.activeElement === el,
              submitted,
              value: valueFor(el),
              tagName: normalizeTag(el),
              type: el.getAttribute('type') || null
            };
          }

          return { exists: true, focused: document.activeElement === el };
        })()
        """
    }

    private static func jsonLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["value": value], options: [])
        guard let wrapper = String(data: data, encoding: .utf8) else {
            throw PeekabooError.encodingError("Failed to encode JavaScript payload")
        }

        // Strip leading {"value": and trailing } to get a JSON literal.
        let prefix = "{\"value\":"
        guard wrapper.hasPrefix(prefix), wrapper.hasSuffix("}") else {
            throw PeekabooError.encodingError("Unexpected JSON payload shape")
        }

        let start = wrapper.index(wrapper.startIndex, offsetBy: prefix.count)
        let end = wrapper.index(before: wrapper.endIndex)
        return String(wrapper[start..<end])
    }
}

enum BrowserOCRResolver {
    static func resolve(query: String, services: any PeekabooServiceProviding) async throws -> BrowserOCRMatch? {
        let capture = try await services.screenCapture.captureFrontmost()
        guard let windowBounds = capture.metadata.windowInfo?.bounds else {
            return nil
        }

        let ocr = try OCRService.recognizeText(in: capture.imageData)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return nil
        }

        let candidates = ocr.observations.filter {
            $0.text.lowercased().contains(needle)
        }

        guard let best = candidates.max(by: { lhs, rhs in
            let lhsScore = Self.score(observation: lhs, needle: needle)
            let rhsScore = Self.score(observation: rhs, needle: needle)
            return lhsScore < rhsScore
        }) else {
            return nil
        }

        let rect = self.screenRect(
            from: best.boundingBox,
            imageSize: ocr.imageSize,
            windowBounds: windowBounds
        )

        return BrowserOCRMatch(
            point: BrowserPoint(x: rect.midX, y: rect.midY),
            rect: BrowserRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
            text: best.text,
            confidence: best.confidence
        )
    }

    private static func score(observation: OCRTextObservation, needle: String) -> Double {
        let text = observation.text.lowercased()
        let exactBoost = text == needle ? 2.0 : (text.hasPrefix(needle) ? 1.2 : 1.0)
        return Double(observation.confidence) * exactBoost
    }

    private static func screenRect(
        from normalizedBox: CGRect,
        imageSize: CGSize,
        windowBounds: CGRect
    ) -> CGRect {
        let width = normalizedBox.width * imageSize.width
        let height = normalizedBox.height * imageSize.height
        let x = normalizedBox.origin.x * imageSize.width
        let y = (1.0 - normalizedBox.origin.y - normalizedBox.height) * imageSize.height
        return CGRect(
            x: windowBounds.origin.x + x,
            y: windowBounds.origin.y + y,
            width: width,
            height: height
        )
    }
}
