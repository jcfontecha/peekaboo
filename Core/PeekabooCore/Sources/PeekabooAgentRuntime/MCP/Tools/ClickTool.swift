import Foundation
import MCP
import os.log
import PeekabooFoundation
import TachikomaMCP

#if canImport(AppKit)
import AppKit
@preconcurrency import AXorcist
import PeekabooAutomation
#endif

/// MCP tool for clicking UI elements
public struct ClickTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ClickTool")
    private let context: MCPToolContext

    public let name = "click"

    public var description: String {
        """
        Clicks on UI elements or coordinates.
        Supports element queries, specific IDs from see command, or raw coordinates.
        Includes smart waiting for elements to become actionable.
        Peekaboo MCP 3.0.0-beta4 using openai/gpt-5.1, anthropic/claude-sonnet-4.5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "query": SchemaBuilder.string(
                    description: """
                    Optional. Element text or query to click. Will search for matching elements.
                    """),
                "on": SchemaBuilder.string(
                    description: """
                    Optional. Element ID to click (e.g., B1, T2) from see command output.
                    """),
                "coords": SchemaBuilder.string(
                    description: """
                    Optional. Click at specific coordinates in format 'x,y' (e.g., '100,200').
                    """),
                "snapshot": SchemaBuilder.string(
                    description: """
                    Optional. Snapshot ID from see command. Uses latest snapshot if not specified.
                    """),
                "wait_for": SchemaBuilder.number(
                    description: """
                    Optional. Maximum milliseconds to wait for element to become actionable. Default: 5000.
                    """,
                    default: 5000),
                "double": SchemaBuilder.boolean(
                    description: "Optional. Double-click instead of single click.",
                    default: false),
                "right": SchemaBuilder.boolean(
                    description: "Optional. Right-click (secondary click) instead of left-click.",
                    default: false),
                "profile": SchemaBuilder.string(
                    description: """
                    Optional. Cursor movement profile before clicking: 'linear' or 'human'.
                    Supplying this moves the cursor to the target before clicking.
                    """),
                "duration": SchemaBuilder.number(
                    description: """
                    Optional. Cursor movement duration in milliseconds before clicking.
                    Defaults to 500 for linear movement and an adaptive duration for human movement.
                    """),
                "steps": SchemaBuilder.number(
                    description: """
                    Optional. Number of movement steps before clicking.
                    Defaults to 20 for linear movement and a distance-based count for human movement.
                    """),
                "hold_duration": SchemaBuilder.number(
                    description: """
                    Optional. Hold the mouse button down for this many milliseconds before releasing.
                    Double-click does not support hold duration.
                    """,
                    default: 0),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request: ClickRequest
        do {
            request = try ClickRequest(arguments: arguments)
        } catch let error as ClickToolError {
            return ToolResponse.error(error.message)
        }

        let startTime = Date()

        do {
            let resolution = try await self.resolveClickTarget(for: request)
            let execution = try await self.performClick(
                at: resolution.location,
                snapshotId: request.snapshotId,
                intent: request.intent,
                request: request)

            let executionTime = Date().timeIntervalSince(startTime)
            return self.buildResponse(
                intent: request.intent,
                resolution: resolution,
                execution: execution,
                executionTime: executionTime)
        } catch let error as ClickToolError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("Click execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to perform click: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func getSnapshot(id: String?) async -> UISnapshot? {
        await UISnapshotManager.shared.getSnapshot(id: id)
    }

    private func resolveClickTarget(for request: ClickRequest) async throws -> ClickResolution {
        switch request.target {
        case let .coordinates(raw):
            let point = try self.parseCoordinates(raw)
            return ClickResolution(location: point, elementDescription: nil)
        case let .elementId(identifier):
            let snapshot = try await self.requireSnapshot(id: request.snapshotId)
            let element = try await self.requireElement(id: identifier, snapshot: snapshot)
            return ClickResolution(
                location: element.centerPoint,
                elementDescription: element.humanDescription,
                targetApp: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                elementRole: element.humanRole,
                elementLabel: element.displayLabel)
        case let .query(text):
            let snapshot = try await self.requireSnapshot(id: request.snapshotId)
            let element = try await self.findElement(matching: text, snapshot: snapshot)
            return ClickResolution(
                location: element.centerPoint,
                elementDescription: element.humanDescription,
                targetApp: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                elementRole: element.humanRole,
                elementLabel: element.displayLabel)
        }
    }

    @MainActor
    private func performClick(
        at location: CGPoint,
        snapshotId: String?,
        intent: ClickIntent,
        request: ClickRequest) async throws -> ClickExecution
    {
        let currentLocation = self.currentMouseLocation()
        let distance = hypot(location.x - currentLocation.x, location.y - currentLocation.y)
        let movement = self.resolveMovement(for: request, distance: distance)
        let options = ClickOptions(
            movement: movement.map { ClickMovement(duration: $0.duration, steps: $0.steps, profile: $0.profile) },
            holdDuration: request.holdDuration)
        try await self.context.automation.click(
            target: .coordinates(location),
            clickType: intent.automationType,
            snapshotId: snapshotId,
            options: options)
        return ClickExecution(
            movement: movement,
            startPoint: currentLocation,
            distance: distance,
            direction: pointerDirection(from: currentLocation, to: location),
            holdDuration: request.holdDuration)
    }

    private func buildResponse(
        intent: ClickIntent,
        resolution: ClickResolution,
        execution: ClickExecution,
        executionTime: TimeInterval) -> ToolResponse
    {
        var message = "\(AgentDisplayTokens.Status.success) \(intent.displayVerb)"
        if let element = resolution.elementDescription {
            message += " on \(element)"
        }
        message += " at (\(Int(resolution.location.x)), \(Int(resolution.location.y)))"
        if let movement = execution.movement {
            message += " using \(movement.profileName) profile"
            if movement.smooth {
                message += " (\(movement.duration)ms, \(movement.steps) steps)"
            }
        }
        if execution.holdDuration > 0 {
            message += " held for \(String(format: "%.2f", Double(execution.holdDuration) / 1000.0))s"
        }
        message += " in \(String(format: "%.2f", executionTime))s"

        var metaDict: [String: Value] = [
            "click_location": .object([
                "x": .double(Double(resolution.location.x)),
                "y": .double(Double(resolution.location.y)),
            ]),
            "execution_time": .double(executionTime),
            "clicked_element": resolution.elementDescription.map(Value.string) ?? .null,
            "hold_duration": .double(Double(execution.holdDuration)),
        ]

        if let movement = execution.movement {
            metaDict["profile"] = .string(movement.profileName)
            metaDict["pointer_duration"] = .double(Double(movement.duration))
            metaDict["pointer_steps"] = .double(Double(movement.steps))
            metaDict["pointer_distance"] = .double(Double(execution.distance))
            metaDict["start_location"] = .object([
                "x": .double(Double(execution.startPoint.x)),
                "y": .double(Double(execution.startPoint.y)),
            ])
            if let direction = execution.direction {
                metaDict["pointer_direction"] = .string(direction)
            }
        }

        let summary = ToolEventSummary(
            targetApp: resolution.targetApp,
            windowTitle: resolution.windowTitle,
            elementRole: resolution.elementRole,
            elementLabel: resolution.elementLabel,
            actionDescription: intent.displayVerb,
            coordinates: ToolEventSummary.Coordinates(
                x: Double(resolution.location.x),
                y: Double(resolution.location.y)),
            pointerProfile: execution.movement?.profileName,
            pointerDistance: execution.movement == nil ? nil : Double(execution.distance),
            pointerDirection: execution.direction,
            pointerDurationMs: execution.movement == nil ? nil : Double(execution.movement?.duration ?? 0),
            waitDurationMs: execution.holdDuration > 0 ? Double(execution.holdDuration) : nil)

        let metaValue = ToolEventSummary.merge(summary: summary, into: .object(metaDict))

        return ToolResponse(
            content: [.text(message)],
            meta: metaValue)
    }

    private func parseCoordinates(_ raw: String) throws -> CGPoint {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1])
        else {
            throw ClickToolError("Invalid coordinates format. Use 'x,y' (e.g., '100,200').")
        }
        return CGPoint(x: x, y: y)
    }

    private func requireSnapshot(id: String?) async throws -> UISnapshot {
        guard let snapshot = await self.getSnapshot(id: id) else {
            throw ClickToolError("No active snapshot. Run 'see' command first to capture UI state.")
        }
        return snapshot
    }

    private func requireElement(id: String, snapshot: UISnapshot) async throws -> UIElement {
        guard let element = await snapshot.getElement(byId: id) else {
            throw ClickToolError(
                "Element '\(id)' not found in current snapshot. Run 'see' command to update UI state.")
        }
        return element
    }

    private func findElement(matching query: String, snapshot: UISnapshot) async throws -> UIElement {
        let searchText = query.lowercased()
        let elements = await snapshot.uiElements
        let matches = elements.filter { element in
            element.title?.lowercased().contains(searchText) ?? false ||
                element.label?.lowercased().contains(searchText) ?? false ||
                element.value?.lowercased().contains(searchText) ?? false
        }

        guard !matches.isEmpty else {
            throw ClickToolError("No elements found matching query: '\(query)'")
        }

        return matches.first { $0.isActionable } ?? matches[0]
    }

    private func resolveMovement(for request: ClickRequest, distance: CGFloat) -> MovementParameters? {
        guard let profile = request.profile else { return nil }
        return profile.resolveParameters(
            smooth: true,
            durationOverride: request.durationOverride,
            stepsOverride: request.stepsOverride,
            defaultDuration: 500,
            defaultSteps: 20,
            distance: distance)
    }

    @MainActor
    private func currentMouseLocation() -> CGPoint {
        #if canImport(AppKit)
        return InputDriver.currentLocation() ?? .zero
        #else
        return .zero
        #endif
    }
}

// MARK: - Supporting Types

private struct ClickRequest {
    let target: ClickRequestTarget
    let snapshotId: String?
    let intent: ClickIntent
    let profile: MovementProfileOption?
    let durationOverride: Int?
    let stepsOverride: Int?
    let holdDuration: Int

    init(arguments: ToolArguments) throws {
        if let coords = arguments.getString("coords") {
            self.target = .coordinates(coords)
        } else if let elementId = arguments.getString("on") {
            self.target = .elementId(elementId)
        } else if let query = arguments.getString("query") {
            self.target = .query(query)
        } else {
            throw ClickToolError("Must specify either 'query', 'on', or 'coords'.")
        }

        self.snapshotId = arguments.getString("snapshot")
        let isDouble = arguments.getBool("double") ?? false
        let isRight = arguments.getBool("right") ?? false
        let profileInput = arguments.getString("profile")?.lowercased()
        let resolvedProfile: MovementProfileOption?
        if let profileInput {
            guard let profile = MovementProfileOption(rawValue: profileInput) else {
                throw ClickToolError("Invalid profile '\(profileInput)'. Use 'linear' or 'human'.")
            }
            resolvedProfile = profile
        } else {
            resolvedProfile = nil
        }

        let durationProvided = arguments.getValue(for: "duration") != nil
        let stepsProvided = arguments.getValue(for: "steps") != nil
        self.durationOverride = durationProvided ? arguments.getNumber("duration").map(Int.init) : nil
        self.stepsOverride = stepsProvided ? arguments.getNumber("steps").map(Int.init) : nil
        self.holdDuration = Int(arguments.getNumber("hold_duration") ?? 0)
        self.intent = try ClickIntent(
            double: isDouble,
            right: isRight,
            holdDuration: self.holdDuration)
        self.profile = resolvedProfile ?? ((self.durationOverride != nil || self.stepsOverride != nil) ? .linear : nil)

        if let duration = self.durationOverride, duration < 0 {
            throw ClickToolError("Duration must be non-negative.")
        }

        if let steps = self.stepsOverride, steps <= 0 {
            throw ClickToolError("Steps must be greater than zero.")
        }

        if self.holdDuration < 0 {
            throw ClickToolError("Hold duration must be non-negative.")
        }
    }
}

private enum ClickRequestTarget {
    case coordinates(String)
    case elementId(String)
    case query(String)
}

private struct ClickResolution {
    let location: CGPoint
    let elementDescription: String?
    let targetApp: String?
    let windowTitle: String?
    let elementRole: String?
    let elementLabel: String?

    init(
        location: CGPoint,
        elementDescription: String?,
        targetApp: String? = nil,
        windowTitle: String? = nil,
        elementRole: String? = nil,
        elementLabel: String? = nil)
    {
        self.location = location
        self.elementDescription = elementDescription
        self.targetApp = targetApp
        self.windowTitle = windowTitle
        self.elementRole = elementRole
        self.elementLabel = elementLabel
    }
}

private struct ClickIntent {
    let automationType: ClickType
    let displayVerb: String

    init(double: Bool, right: Bool, holdDuration: Int) throws {
        guard !(double && holdDuration > 0) else {
            throw ClickToolError("Double-click does not support hold_duration.")
        }

        if right {
            self.automationType = .right
            self.displayVerb = "Right-clicked"
        } else if double {
            self.automationType = .double
            self.displayVerb = "Double-clicked"
        } else {
            self.automationType = .single
            self.displayVerb = "Clicked"
        }
    }
}

private struct ClickExecution {
    let movement: MovementParameters?
    let startPoint: CGPoint
    let distance: CGFloat
    let direction: String?
    let holdDuration: Int
}

private struct ClickToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension UIElement {
    fileprivate var centerPoint: CGPoint {
        CGPoint(x: self.frame.midX, y: self.frame.midY)
    }

    fileprivate var humanDescription: String {
        "\(self.role): \(self.title ?? self.label ?? "untitled")"
    }

    fileprivate var humanRole: String? {
        self.roleDescription ?? self.role
    }

    fileprivate var displayLabel: String? {
        self.title ?? self.label ?? self.value
    }
}
