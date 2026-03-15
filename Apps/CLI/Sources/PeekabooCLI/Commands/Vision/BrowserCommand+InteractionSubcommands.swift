import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
extension BrowserCommand {
    @MainActor
    struct CoordsSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text)")
        var query: String = ""

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "coords",
                    abstract: "Resolve an element and print screen coordinates"
                )
            }
        }

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before use")
            }
            return runtime
        }

        private var support: BrowserCommandSupport {
            BrowserCommandSupport(runtime: self.resolvedRuntime, connection: self.connection)
        }

        var outputLogger: Logger { self.resolvedRuntime.logger }
        var jsonOutput: Bool { self.resolvedRuntime.configuration.jsonOutput }

        mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
            self.query = try values.requiredPositional(0, label: "query")
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)

                let strategy = BrowserQueryStrategy.infer(from: self.query)
                let resolved = try await self.support.resolveElement(
                    query: self.query,
                    strategy: strategy,
                    allowOCR: self.interaction.ocr,
                    session: handle.session
                )

                let outputPayload = BrowserResolvedElementOutput(
                    success: true,
                    targetUrl: handle.target.url,
                    element: resolved
                )
                self.output(outputPayload) {
                    print("x=\(Int(resolved.screenPoint.x)) y=\(Int(resolved.screenPoint.y))")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct ClickSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text)")
        var query: String = ""

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "click",
                    abstract: "Click a browser element resolved through CDP"
                )
            }
        }

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before use")
            }
            return runtime
        }

        private var support: BrowserCommandSupport {
            BrowserCommandSupport(runtime: self.resolvedRuntime, connection: self.connection)
        }

        private var services: any PeekabooServiceProviding { self.resolvedRuntime.services }
        var outputLogger: Logger { self.resolvedRuntime.logger }
        var jsonOutput: Bool { self.resolvedRuntime.configuration.jsonOutput }

        mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
            self.query = try values.requiredPositional(0, label: "query")
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)
                await self.support.ensureBrowserFocused(autoFocus: self.interaction.shouldAutoFocus)

                let strategy = BrowserQueryStrategy.infer(from: self.query)
                let resolved = try await self.support.resolveElement(
                    query: self.query,
                    strategy: strategy,
                    allowOCR: self.interaction.ocr,
                    session: handle.session
                )

                let point = resolved.screenPoint.cgPoint
                let clickOptions = self.support.clickOptions(for: point, interaction: self.interaction)
                try await AutomationServiceBridge.click(
                    automation: self.services.automation,
                    target: .coordinates(point),
                    clickType: .single,
                    snapshotId: nil,
                    options: clickOptions
                )

                let outputPayload = BrowserClickOutput(
                    success: true,
                    action: "click",
                    targetUrl: handle.target.url,
                    point: resolved.screenPoint,
                    matchedBy: resolved.matchedBy
                )
                self.output(outputPayload) {
                    print("clicked (\(Int(resolved.screenPoint.x)), \(Int(resolved.screenPoint.y)))")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct HoldSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text)")
        var query: String = ""

        @Argument(help: "Hold duration in milliseconds")
        var durationMs: Int = 0

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "hold",
                    abstract: "Click and hold an element"
                )
            }
        }

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before use")
            }
            return runtime
        }

        private var support: BrowserCommandSupport {
            BrowserCommandSupport(runtime: self.resolvedRuntime, connection: self.connection)
        }

        private var services: any PeekabooServiceProviding { self.resolvedRuntime.services }
        var outputLogger: Logger { self.resolvedRuntime.logger }
        var jsonOutput: Bool { self.resolvedRuntime.configuration.jsonOutput }

        mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
            self.query = try values.requiredPositional(0, label: "query")
            self.durationMs = try values.decodePositional(1, label: "duration-ms", as: Int.self)
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                guard self.durationMs >= 0 else {
                    throw ValidationError("duration-ms must be non-negative")
                }

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)
                await self.support.ensureBrowserFocused(autoFocus: self.interaction.shouldAutoFocus)

                let strategy = BrowserQueryStrategy.infer(from: self.query)
                let resolved = try await self.support.resolveElement(
                    query: self.query,
                    strategy: strategy,
                    allowOCR: self.interaction.ocr,
                    session: handle.session
                )

                let point = resolved.screenPoint.cgPoint
                let clickOptions = self.support.clickOptions(
                    for: point,
                    interaction: self.interaction,
                    holdDuration: self.durationMs
                )
                try await AutomationServiceBridge.click(
                    automation: self.services.automation,
                    target: .coordinates(point),
                    clickType: .single,
                    snapshotId: nil,
                    options: clickOptions
                )

                let outputPayload = BrowserClickOutput(
                    success: true,
                    action: "hold",
                    targetUrl: handle.target.url,
                    point: resolved.screenPoint,
                    matchedBy: resolved.matchedBy
                )
                self.output(outputPayload) {
                    print("held (\(Int(resolved.screenPoint.x)), \(Int(resolved.screenPoint.y))) for \(self.durationMs)ms")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct HoverSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text)")
        var query: String = ""

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "hover",
                    abstract: "Move the cursor to an element without clicking"
                )
            }
        }

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before use")
            }
            return runtime
        }

        private var support: BrowserCommandSupport {
            BrowserCommandSupport(runtime: self.resolvedRuntime, connection: self.connection)
        }

        private var services: any PeekabooServiceProviding { self.resolvedRuntime.services }
        var outputLogger: Logger { self.resolvedRuntime.logger }
        var jsonOutput: Bool { self.resolvedRuntime.configuration.jsonOutput }

        mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
            self.query = try values.requiredPositional(0, label: "query")
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)
                await self.support.ensureBrowserFocused(autoFocus: self.interaction.shouldAutoFocus)

                let strategy = BrowserQueryStrategy.infer(from: self.query)
                let resolved = try await self.support.resolveElement(
                    query: self.query,
                    strategy: strategy,
                    allowOCR: self.interaction.ocr,
                    session: handle.session
                )

                let point = resolved.screenPoint.cgPoint
                let movement = self.support.movementParameters(for: point, interaction: self.interaction)
                try await AutomationServiceBridge.moveMouse(
                    automation: self.services.automation,
                    to: point,
                    duration: movement.duration,
                    steps: movement.steps,
                    profile: movement.profile
                )

                let outputPayload = BrowserClickOutput(
                    success: true,
                    action: "hover",
                    targetUrl: handle.target.url,
                    point: resolved.screenPoint,
                    matchedBy: resolved.matchedBy
                )
                self.output(outputPayload) {
                    print("hovered (\(Int(resolved.screenPoint.x)), \(Int(resolved.screenPoint.y)))")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct TypeSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text)")
        var query: String = ""

        @Argument(help: "Text to type")
        var text: String = ""

        @Flag(help: "Clear field first (Cmd+A, Delete)")
        var clear = false

        @Flag(name: .customLong("submit"), help: "Submit after typing (press Enter on the resolved element)")
        var submit = false

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "type",
                    abstract: "Click an element and type text with native input"
                )
            }
        }

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before use")
            }
            return runtime
        }

        private var support: BrowserCommandSupport {
            BrowserCommandSupport(runtime: self.resolvedRuntime, connection: self.connection)
        }

        private var services: any PeekabooServiceProviding { self.resolvedRuntime.services }
        var outputLogger: Logger { self.resolvedRuntime.logger }
        var jsonOutput: Bool { self.resolvedRuntime.configuration.jsonOutput }

        mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
            self.query = try values.requiredPositional(0, label: "query")
            self.text = try values.requiredPositional(1, label: "text")
            self.clear = values.flag("clear")
            self.submit = values.flag("submit")
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)
                await self.support.ensureBrowserFocused(autoFocus: self.interaction.shouldAutoFocus)

                let strategy = BrowserQueryStrategy.infer(from: self.query)
                let resolved = try await self.support.resolveElement(
                    query: self.query,
                    strategy: strategy,
                    allowOCR: self.interaction.ocr,
                    session: handle.session
                )

                _ = try await self.support.focusElementInDOM(resolved: resolved, session: handle.session)
                if self.clear {
                    _ = try await self.support.clearElementInDOM(resolved: resolved, session: handle.session)
                }

                let actions = TypeCommand.processTextWithEscapes(self.text)
                let expectedPlainText = self.expectedPlainText(from: actions)

                let shouldAttemptNativeTyping = self.interaction.shouldAutoFocus
                var inputMode = "cdp"

                if shouldAttemptNativeTyping {
                    try await self.performNativeTyping(actions: actions, targetPoint: resolved.screenPoint.cgPoint)
                    let nativeState = try await self.support.readElementInputState(resolved: resolved, session: handle.session)
                    if self.nativeTypingSucceeded(state: nativeState, expectedText: expectedPlainText) {
                        inputMode = "native"
                    } else {
                        self.outputLogger.warn(
                            "Native typing did not update the resolved element; falling back to CDP text input.",
                            category: "Browser"
                        )
                        try await self.performCDPTyping(actions: actions, resolved: resolved, session: handle.session)
                        inputMode = "cdp-fallback"
                    }
                } else {
                    try await self.performCDPTyping(actions: actions, resolved: resolved, session: handle.session)
                }

                var submitted = false
                if self.submit {
                    submitted = try await self.support.submitElementInDOM(resolved: resolved, session: handle.session)
                    if submitted {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                }

                let outputPayload = BrowserTypeOutput(
                    success: true,
                    targetUrl: handle.target.url,
                    point: resolved.screenPoint,
                    textLength: self.text.count,
                    clearedFirst: self.clear,
                    inputMode: inputMode,
                    submitted: submitted
                )
                self.output(outputPayload) {
                    let submitSuffix = submitted ? ", submitted" : ""
                    print("typed \(self.text.count) chars [\(inputMode)\(submitSuffix)]")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }

        private func performNativeTyping(actions: [TypeAction], targetPoint: CGPoint) async throws {
            let clickOptions = self.support.clickOptions(for: targetPoint, interaction: self.interaction)
            try await AutomationServiceBridge.click(
                automation: self.services.automation,
                target: .coordinates(targetPoint),
                clickType: .single,
                snapshotId: nil,
                options: clickOptions
            )

            try await Task.sleep(nanoseconds: 60_000_000)

            guard !actions.isEmpty else {
                return
            }

            _ = try await AutomationServiceBridge.typeActions(
                automation: self.services.automation,
                request: TypeActionsRequest(
                    actions: actions,
                    cadence: .fixed(milliseconds: 2),
                    snapshotId: nil
                )
            )
        }

        private func performCDPTyping(
            actions: [TypeAction],
            resolved: BrowserResolvedElement,
            session: BrowserCDPSession
        ) async throws {
            _ = try await self.support.focusElementInDOM(resolved: resolved, session: session)
            try await self.support.typeWithCDP(actions: actions, session: session)
        }

        private func expectedPlainText(from actions: [TypeAction]) -> String? {
            var chunks: [String] = []
            for action in actions {
                switch action {
                case let .text(chunk):
                    chunks.append(chunk)
                case .clear, .key:
                    return nil
                }
            }
            return chunks.joined()
        }

        private func nativeTypingSucceeded(
            state: BrowserElementInputState?,
            expectedText: String?
        ) -> Bool {
            guard let state else {
                return false
            }

            guard state.focused else {
                return false
            }

            guard let expectedText else {
                return true
            }

            return state.value?.contains(expectedText) == true
        }
    }

    @MainActor
    struct SelectSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query for the dropdown")
        var query: String = ""

        @Argument(help: "Option value or visible text")
        var value: String = ""

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "select",
                    abstract: "Select a dropdown option using native input"
                )
            }
        }

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before use")
            }
            return runtime
        }

        private var support: BrowserCommandSupport {
            BrowserCommandSupport(runtime: self.resolvedRuntime, connection: self.connection)
        }

        private var services: any PeekabooServiceProviding { self.resolvedRuntime.services }
        var outputLogger: Logger { self.resolvedRuntime.logger }
        var jsonOutput: Bool { self.resolvedRuntime.configuration.jsonOutput }

        mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
            self.query = try values.requiredPositional(0, label: "query")
            self.value = try values.requiredPositional(1, label: "value")
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                let trimmedValue = self.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedValue.isEmpty else {
                    throw ValidationError("value cannot be empty")
                }

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)
                await self.support.ensureBrowserFocused(autoFocus: self.interaction.shouldAutoFocus)

                let strategy = BrowserQueryStrategy.infer(from: self.query)
                let selectElement = try await self.support.resolveElement(
                    query: self.query,
                    strategy: strategy,
                    allowOCR: self.interaction.ocr,
                    session: handle.session
                )

                let selectPoint = selectElement.screenPoint.cgPoint
                let clickOptions = self.support.clickOptions(for: selectPoint, interaction: self.interaction)
                try await AutomationServiceBridge.click(
                    automation: self.services.automation,
                    target: .coordinates(selectPoint),
                    clickType: .single,
                    snapshotId: nil,
                    options: clickOptions
                )

                try await Task.sleep(nanoseconds: 120_000_000)

                var mode = "type-return"
                if let optionElement = try? await self.support.resolveElement(
                    query: trimmedValue,
                    strategy: .text,
                    allowOCR: self.interaction.ocr,
                    session: handle.session
                ) {
                    let optionPoint = optionElement.screenPoint.cgPoint
                    let optionClickOptions = self.support.clickOptions(for: optionPoint, interaction: self.interaction)
                    try await AutomationServiceBridge.click(
                        automation: self.services.automation,
                        target: .coordinates(optionPoint),
                        clickType: .single,
                        snapshotId: nil,
                        options: optionClickOptions
                    )
                    mode = "option-click"
                } else {
                    let actions: [TypeAction] = [.text(trimmedValue), .key(.return)]
                    _ = try await AutomationServiceBridge.typeActions(
                        automation: self.services.automation,
                        request: TypeActionsRequest(
                            actions: actions,
                            cadence: .fixed(milliseconds: 2),
                            snapshotId: nil
                        )
                    )
                }

                let outputPayload = BrowserSelectOutput(
                    success: true,
                    targetUrl: handle.target.url,
                    query: self.query,
                    value: trimmedValue,
                    mode: mode
                )
                self.output(outputPayload) {
                    print("selected '\(trimmedValue)' using \(mode)")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }
}

@available(macOS 14.0, *)
extension CommanderBindableValues {
    func makeBrowserConnectionOptions() throws -> BrowserConnectionOptions {
        var options = BrowserConnectionOptions()
        if let cdpPort: Int = try self.decodeOption("cdpPort", as: Int.self) {
            options.cdpPort = cdpPort
        }
        options.url = self.singleOption("url")
        return options
    }

    func makeBrowserInteractionOptions() throws -> BrowserInteractionOptions {
        var options = BrowserInteractionOptions()
        if let profile = self.singleOption("profile") {
            options.profile = profile
        }
        if let duration: Int = try self.decodeOption("duration", as: Int.self) {
            options.duration = duration
        }
        options.noAutoFocus = self.flag("noAutoFocus")
        options.ocr = self.flag("ocr")
        return options
    }
}
