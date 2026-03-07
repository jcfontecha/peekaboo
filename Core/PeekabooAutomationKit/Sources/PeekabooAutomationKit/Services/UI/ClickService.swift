import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/**
 * Specialized click service providing precise mouse interaction capabilities.
 *
 * Handles all types of click operations with intelligent targeting, snapshot integration,
 * and multiple targeting modes. Supports element-based clicking via snapshot cache,
 * coordinate-based clicking, and query-based element discovery.
 *
 * ## Click Types
 * - Single, double, right-click, and middle-click
 * - Coordinate-based and element-based targeting
 * - Query-based element discovery and interaction
 *
 * ## Usage Example
 * ```swift
 * let clickService = ClickService(snapshotManager: snapshotManager)
 *
 * // Click by element ID
 * try await clickService.click(
 *     target: .elementId("B1"),
 *     clickType: .single,
 *     snapshotId: "snapshot_123"
 * )
 *
 * // Click by coordinates
 * try await clickService.click(
 *     target: .coordinates(CGPoint(x: 100, y: 200)),
 *     clickType: .right,
 *     snapshotId: nil
 * )
 * ```
 *
 * - Note: Part of UIAutomationService's specialized service architecture
 * - Since: PeekabooCore 1.0.0
 */
@MainActor
public final class ClickService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ClickService")
    private let snapshotManager: any SnapshotManagerProtocol
    private let gestureService: GestureService

    public init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        gestureService: GestureService = GestureService())
    {
        self.snapshotManager = snapshotManager ?? SnapshotManager()
        self.gestureService = gestureService
    }

    /// Perform a click operation
    @MainActor
    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        options: ClickOptions) async throws
    {
        self.logger.debug("Click requested - target: \(String(describing: target)), type: \(clickType)")
        try self.validate(options: options, clickType: clickType)

        do {
            switch target {
            case let .elementId(id):
                try await self.clickElementById(
                    id: id,
                    clickType: clickType,
                    snapshotId: snapshotId,
                    options: options)

            case let .coordinates(point):
                try await self.performClick(at: point, clickType: clickType, options: options)

            case let .query(query):
                try await self.clickElementByQuery(
                    query: query,
                    clickType: clickType,
                    snapshotId: snapshotId,
                    options: options)
            }
        } catch {
            self.logger.error("Click failed: \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    public func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        try await self.click(target: target, clickType: clickType, snapshotId: snapshotId, options: ClickOptions())
    }

    // MARK: - Private Methods

    private func clickElementById(
        id: String,
        clickType: ClickType,
        snapshotId: String?,
        options: ClickOptions) async throws
    {
        // Get element from snapshot
        if let snapshotId,
           let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId),
           let element = detectionResult.elements.findById(id)
        {
            // Click at element center
            let center = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
            let adjusted = try await self.resolveAdjustedPoint(center, snapshotId: snapshotId)
            try await self.performClick(at: adjusted, clickType: clickType, options: options)
            try await self.nudgeTextInputFocusIfNeeded(
                afterClickAt: adjusted,
                clickType: clickType,
                expectedIdentifier: element.attributes["identifier"],
                options: options)
            self.logger.debug("Clicked element \(id) at (\(adjusted.x), \(adjusted.y))")
        } else {
            throw NotFoundError.element(id)
        }
    }

    @MainActor
    private func clickElementByQuery(
        query: String,
        clickType: ClickType,
        snapshotId: String?,
        options: ClickOptions) async throws
    {
        // First try to find in snapshot data if available (much faster)
        var found = false
        var clickFrame: CGRect?
        var resolvedElement: DetectedElement?

        if let snapshotId,
           let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId)
        {
            if let match = Self.resolveTargetElement(query: query, in: detectionResult) {
                found = true
                clickFrame = match.bounds
                resolvedElement = match
                self.logger.debug("Found element in snapshot matching query: \(query)")
            }
        }

        // Fall back to searching through all applications if not found in snapshot
        if !found {
            let elementInfo = self.findElementByQuery(query)
            if let element = elementInfo {
                found = true
                clickFrame = element.frame()
                self.logger.debug("Found element via AX search matching query: \(query)")
            }
        }

        // Perform click if element found
        if found, let frame = clickFrame {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let adjusted = try await self.resolveAdjustedPoint(
                center,
                snapshotId: resolvedElement != nil ? snapshotId : nil)
            try await self.performClick(at: adjusted, clickType: clickType, options: options)
            try await self.nudgeTextInputFocusIfNeeded(
                afterClickAt: adjusted,
                clickType: clickType,
                expectedIdentifier: resolvedElement?.attributes["identifier"],
                options: options)
            self.logger.debug("Clicked element matching '\(query)' at (\(adjusted.x), \(adjusted.y))")
        } else {
            throw NotFoundError.element(query)
        }
    }

    private func resolveAdjustedPoint(_ point: CGPoint, snapshotId: String?) async throws -> CGPoint {
        guard let snapshotId,
              let snapshot = try? await self.snapshotManager.getUIAutomationSnapshot(snapshotId: snapshotId)
        else {
            return point
        }

        switch WindowMovementTracking.adjustPoint(point, snapshot: snapshot) {
        case let .unchanged(original):
            return original
        case let .adjusted(adjusted, _):
            return adjusted
        case let .stale(message):
            throw PeekabooError.snapshotStale(message)
        }
    }

    private func nudgeTextInputFocusIfNeeded(
        afterClickAt point: CGPoint,
        clickType: ClickType,
        expectedIdentifier: String?,
        options: ClickOptions) async throws
    {
        guard clickType == .single, options.holdDuration == 0 else { return }

        let normalizedExpectedIdentifier = expectedIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // If we're already focused on a text input, don't introduce extra clicks.
        if self.isFocusedTextInput(expectedIdentifier: normalizedExpectedIdentifier) {
            return
        }

        // SwiftUI can report text input frames with a stable vertical offset (commonly ~28-32px).
        // Retry a handful of small Y nudges to land inside the actual editable region.
        let nudges: [CGFloat] = [-29, -24, -34, -20]

        for dy in nudges {
            let candidate = CGPoint(x: point.x, y: point.y + dy)
            try await self.performClick(at: candidate, clickType: .single, options: ClickOptions())
            try await Task.sleep(nanoseconds: 60_000_000) // 60ms

            if self.isFocusedTextInput(expectedIdentifier: normalizedExpectedIdentifier) {
                return
            }
        }
    }

    private func isFocusedTextInput(expectedIdentifier: String?) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXApp(frontApp).element
        guard let focused = appElement.focusedUIElement() else { return false }

        let role = focused.role()?.lowercased() ?? ""
        let isTextInput = role.contains("textfield") || role.contains("searchfield") || role.contains("textarea")
        guard isTextInput else { return false }

        guard let expectedIdentifier, !expectedIdentifier.isEmpty else { return true }
        return focused.identifier()?.lowercased() == expectedIdentifier
    }

    @MainActor
    static func resolveTargetElement(query: String, in detectionResult: ElementDetectionResult) -> DetectedElement? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = trimmed.lowercased()
        guard !queryLower.isEmpty else { return nil }

        var bestMatch: DetectedElement?
        var bestScore = Int.min

        for element in detectionResult.elements.all where element.isEnabled {
            let label = element.label?.lowercased()
            let value = element.value?.lowercased()
            let identifier = element.attributes["identifier"]?.lowercased()
            let title = element.attributes["title"]?.lowercased()
            let description = element.attributes["description"]?.lowercased()
            let role = element.attributes["role"]?.lowercased()

            let candidates = [label, value, identifier, title, description, role].compactMap(\.self)
            guard candidates.contains(where: { $0.contains(queryLower) }) else { continue }

            var score = 0
            if identifier == queryLower { score += 400 }
            if label == queryLower { score += 350 }
            if title == queryLower { score += 300 }
            if value == queryLower { score += 200 }

            if identifier?.contains(queryLower) == true { score += 200 }
            if label?.contains(queryLower) == true { score += 160 }
            if title?.contains(queryLower) == true { score += 120 }
            if value?.contains(queryLower) == true { score += 80 }
            if description?.contains(queryLower) == true { score += 50 }

            if element.type.rawValue.lowercased() == queryLower { score += 40 }
            if element.type == .button { score += 20 }

            if score > bestScore {
                bestScore = score
                bestMatch = element
            } else if score == bestScore, let currentBest = bestMatch {
                // Deterministic tie-break: prefer lower (smaller y) matches.
                // This helps when SwiftUI reports multiple nodes with the same identifier.
                if element.bounds.origin.y < currentBest.bounds.origin.y {
                    bestMatch = element
                }
            }
        }

        return bestMatch
    }

    /// Find element by query string
    @MainActor
    private func findElementByQuery(_ query: String) -> Element? {
        let queryLower = query.lowercased()

        // Find the application at the mouse position
        guard let app = MouseLocationUtilities.findApplicationAtMouseLocation() else {
            return nil
        }

        let axApp = AXApp(app)
        let appElement = axApp.element

        // Search recursively
        return self.searchElement(in: appElement, matching: queryLower)
    }

    @MainActor
    private func searchElement(in element: Element, matching query: String) -> Element? {
        // Check current element
        let title = element.title()?.lowercased() ?? ""
        let label = element.label()?.lowercased() ?? ""
        let value = element.stringValue()?.lowercased() ?? ""
        let roleDescription = element.roleDescription()?.lowercased() ?? ""

        if title.contains(query) || label.contains(query) ||
            value.contains(query) || roleDescription.contains(query)
        {
            return element
        }

        // Search children
        if let children = element.children() {
            for child in children {
                if let found = searchElement(in: child, matching: query) {
                    return found
                }
            }
        }

        return nil
    }

    /// Perform actual click at coordinates using AXorcist InputDriver.
    private func performClick(at point: CGPoint, clickType: ClickType, options: ClickOptions) async throws {
        self.logger.debug("Performing \(clickType) click at (\(point.x), \(point.y))")
        try await self.moveCursorIfNeeded(to: point, options: options)

        switch clickType {
        case .single:
            if options.holdDuration > 0 {
                try InputDriver.pressHold(
                    at: point,
                    button: .left,
                    duration: TimeInterval(options.holdDuration) / 1000.0)
            } else {
                try InputDriver.click(at: point, button: .left, count: 1)
            }
        case .right:
            if options.holdDuration > 0 {
                try InputDriver.pressHold(
                    at: point,
                    button: .right,
                    duration: TimeInterval(options.holdDuration) / 1000.0)
            } else {
                try InputDriver.click(at: point, button: .right, count: 1)
            }
        case .double:
            try InputDriver.click(at: point, button: .left, count: 2)
        }
    }

    private func validate(options: ClickOptions, clickType: ClickType) throws {
        guard options.holdDuration >= 0 else {
            throw PeekabooError.invalidInput(field: "holdDuration", reason: "Hold duration must be non-negative")
        }

        if let movement = options.movement {
            guard movement.duration >= 0 else {
                throw PeekabooError.invalidInput(field: "duration", reason: "Movement duration must be non-negative")
            }
            guard movement.steps > 0 else {
                throw PeekabooError.invalidInput(field: "steps", reason: "Movement steps must be greater than zero")
            }
        }

        guard clickType != .double || options.holdDuration == 0 else {
            throw PeekabooError.invalidInput(
                field: "holdDuration",
                reason: "Double-click does not support hold duration")
        }
    }

    private func moveCursorIfNeeded(to point: CGPoint, options: ClickOptions) async throws {
        guard let movement = options.movement else { return }
        try await self.gestureService.moveMouse(
            to: point,
            duration: movement.duration,
            steps: movement.steps,
            profile: movement.profile)
    }

    private func performForceClick(at point: CGPoint) async throws {
        try InputDriver.move(to: point)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        try InputDriver.pressHold(at: point, button: .left, duration: 0.5)
    }
}

// MARK: - Extensions for ClickType

// CustomStringConvertible conformance is now in PeekabooFoundation
