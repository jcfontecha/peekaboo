import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
extension BrowserCommand {
    @MainActor
    struct ListSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var connection: BrowserConnectionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "list",
                    abstract: "List CDP page targets"
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
            self.connection = try values.makeBrowserConnectionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()

                let targets = try await self.support.listTargets()
                var pageTargets = targets.filter { $0.type == "page" }

                if let filter = self.connection.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !filter.isEmpty {
                    pageTargets = pageTargets.filter {
                        $0.url.localizedCaseInsensitiveContains(filter) ||
                            $0.title.localizedCaseInsensitiveContains(filter)
                    }
                }

                let outputPayload = BrowserListOutput(
                    success: true,
                    cdpPort: self.connection.cdpPort,
                    targetCount: pageTargets.count,
                    targets: pageTargets.map(\.asListOutput)
                )
                self.output(outputPayload) {
                    guard !pageTargets.isEmpty else {
                        print("No page targets found on port \(self.connection.cdpPort).")
                        return
                    }

                    for (index, target) in pageTargets.enumerated() {
                        let title = target.title.isEmpty ? "(untitled)" : target.title
                        print("[\(index)] \(title)")
                        print("    \(target.url)")
                    }
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct NavigateSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Destination URL")
        var url: String = ""

        @OptionGroup var connection: BrowserConnectionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "navigate",
                    abstract: "Navigate the selected tab to a URL"
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
            self.url = try values.requiredPositional(0, label: "url")
            self.connection = try values.makeBrowserConnectionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()

                let destination = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !destination.isEmpty else {
                    throw ValidationError("url cannot be empty")
                }

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)

                let result = try await handle.session.call(
                    method: "Page.navigate",
                    params: ["url": destination]
                )
                if let errorText = result["errorText"] as? String, !errorText.isEmpty {
                    throw PeekabooError.commandFailed(errorText)
                }

                let outputPayload = BrowserNavigateOutput(
                    success: true,
                    targetUrl: destination,
                    frameId: result["frameId"] as? String,
                    loaderId: result["loaderId"] as? String
                )
                self.output(outputPayload) {
                    print("navigated to \(destination)")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct SnapshotSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var connection: BrowserConnectionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "snapshot",
                    abstract: "Dump the current DOM tree snapshot"
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
            self.connection = try values.makeBrowserConnectionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)

                let snapshot = try await BrowserDOMResolver.snapshot(session: handle.session)
                let outputPayload = BrowserSnapshotOutput(
                    success: true,
                    targetUrl: handle.target.url,
                    snapshot: snapshot
                )

                if self.jsonOutput {
                    outputJSONCodable(outputPayload, logger: self.outputLogger)
                } else if let value = snapshot as? [String: Any],
                          let nodeCount = BrowserDOMResolver.double(value["nodeCount"]) {
                    print("snapshot captured \(Int(nodeCount)) nodes")
                } else {
                    print("snapshot captured")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct EvaluateSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "JavaScript expression to evaluate")
        var expression: String = ""

        @OptionGroup var connection: BrowserConnectionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "evaluate",
                    abstract: "Run JavaScript via CDP Runtime.evaluate"
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
            self.expression = try values.requiredPositional(0, label: "expression")
            self.connection = try values.makeBrowserConnectionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()

                let script = self.expression.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !script.isEmpty else {
                    throw ValidationError("expression cannot be empty")
                }

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)

                let evaluation = try await handle.session.evaluate(expression: script)
                let outputPayload = BrowserEvaluateOutput(
                    success: true,
                    targetUrl: handle.target.url,
                    valueType: evaluation.type,
                    value: evaluation.value ?? evaluation.description
                )

                if self.jsonOutput {
                    outputJSONCodable(outputPayload, logger: self.outputLogger)
                } else if let value = outputPayload.value {
                    print(String(describing: value))
                } else {
                    print("undefined")
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct WaitSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text)")
        var query: String = ""

        @Option(name: .customLong("timeout-ms"), help: "Maximum wait time in milliseconds")
        var timeoutMs: Int = 5_000

        @Option(name: .customLong("interval-ms"), help: "Polling interval in milliseconds")
        var intervalMs: Int = 120

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "wait",
                    abstract: "Wait for an element to appear"
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
            if let timeoutMs: Int = try values.decodeOption("timeoutMs", as: Int.self) {
                self.timeoutMs = timeoutMs
            }
            if let intervalMs: Int = try values.decodeOption("intervalMs", as: Int.self) {
                self.intervalMs = intervalMs
            }
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                guard self.timeoutMs >= 0 else {
                    throw ValidationError("--timeout-ms must be non-negative")
                }
                guard self.intervalMs > 0 else {
                    throw ValidationError("--interval-ms must be positive")
                }

                let handle = try await self.support.openSession()
                defer { handle.session.close() }
                await self.support.prepare(session: handle.session)

                let strategy = BrowserQueryStrategy.infer(from: self.query)
                let start = Date()
                var foundElement: BrowserResolvedElement?

                while true {
                    do {
                        let resolved = try await self.support.resolveElement(
                            query: self.query,
                            strategy: strategy,
                            allowOCR: self.interaction.ocr,
                            session: handle.session
                        )
                        foundElement = resolved
                        break
                    } catch let error as PeekabooError {
                        guard case .elementNotFound = error else {
                            throw error
                        }
                    }

                    let elapsedMs = Int(Date().timeIntervalSince(start) * 1_000.0)
                    if elapsedMs >= self.timeoutMs {
                        break
                    }

                    let remainingMs = self.timeoutMs - elapsedMs
                    let sleepMs = max(1, min(self.intervalMs, remainingMs))
                    try await Task.sleep(nanoseconds: UInt64(sleepMs) * 1_000_000)
                }

                let elapsedMs = Int(Date().timeIntervalSince(start) * 1_000.0)
                let outputPayload = BrowserWaitOutput(
                    success: true,
                    found: foundElement != nil,
                    targetUrl: handle.target.url,
                    elapsedMs: elapsedMs,
                    element: foundElement
                )
                self.output(outputPayload) {
                    if foundElement != nil {
                        print("found '\(self.query)' after \(elapsedMs)ms")
                    } else {
                        print("timed out after \(elapsedMs)ms waiting for '\(self.query)'")
                    }
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct TextSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text). Omit to extract page text")
        var query: String = ""

        @Flag(name: .customLong("trim"), help: "Trim leading and trailing whitespace")
        var trim = false

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "text",
                    abstract: "Extract text from page or element"
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
            self.query = values.positionalValue(at: 0) ?? ""
            self.trim = values.flag("trim")
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

                let trimmedQuery = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
                var textValue = ""

                if trimmedQuery.isEmpty {
                    textValue = try await BrowserDOMResolver.text(selector: nil, session: handle.session)
                } else {
                    let strategy = BrowserQueryStrategy.infer(from: trimmedQuery)
                    let resolved = try await self.support.resolveElement(
                        query: trimmedQuery,
                        strategy: strategy,
                        allowOCR: self.interaction.ocr,
                        session: handle.session
                    )

                    if resolved.source == "ocr" {
                        textValue = resolved.text ?? ""
                    } else if let selector = resolved.cssSelector, !selector.isEmpty {
                        textValue = try await BrowserDOMResolver.text(selector: selector, session: handle.session)
                        if textValue.isEmpty {
                            textValue = resolved.text ?? ""
                        }
                    } else {
                        textValue = resolved.text ?? ""
                    }
                }

                if self.trim {
                    textValue = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let selectorValue = trimmedQuery.isEmpty ? nil : trimmedQuery
                let outputPayload = BrowserTextOutput(
                    success: true,
                    targetUrl: handle.target.url,
                    selector: selectorValue,
                    text: textValue
                )
                self.output(outputPayload) {
                    print(textValue)
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }

    @MainActor
    struct ScrollSubcommand: AsyncRuntimeCommand, CommanderBindableCommand, ErrorHandlingCommand, OutputFormattable {
        @Argument(help: "Element query (CSS, XPath, or text)")
        var query: String = ""

        @Option(help: "Scroll direction: up, down, left, or right")
        var direction: String = "down"

        @Option(help: "Number of scroll ticks")
        var amount: Int = 3

        @Option(help: "Delay between scroll ticks in milliseconds")
        var delay: Int = 2

        @Flag(help: "Use smooth scrolling with smaller increments")
        var smooth = false

        @OptionGroup var connection: BrowserConnectionOptions
        @OptionGroup var interaction: BrowserInteractionOptions

        @RuntimeStorage private var runtime: CommandRuntime?

        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "scroll",
                    abstract: "Scroll at an element resolved through CDP"
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
            if let direction = values.singleOption("direction") {
                self.direction = direction
            }
            if let amount: Int = try values.decodeOption("amount", as: Int.self) {
                self.amount = amount
            }
            if let delay: Int = try values.decodeOption("delay", as: Int.self) {
                self.delay = delay
            }
            self.smooth = values.flag("smooth")
            self.connection = try values.makeBrowserConnectionOptions()
            self.interaction = try values.makeBrowserInteractionOptions()
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.outputLogger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.connection.validate()
                try self.interaction.validate()

                guard self.amount >= 0 else {
                    throw ValidationError("--amount must be non-negative")
                }
                guard self.delay >= 0 else {
                    throw ValidationError("--delay must be non-negative")
                }

                let normalizedDirection = self.direction
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard let scrollDirection = ScrollDirection(rawValue: normalizedDirection) else {
                    throw ValidationError("--direction must be one of: up, down, left, right")
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
                let movement = self.support.movementParameters(
                    for: point,
                    interaction: self.interaction,
                    defaultDuration: 350,
                    defaultSteps: 16
                )

                try await AutomationServiceBridge.moveMouse(
                    automation: self.services.automation,
                    to: point,
                    duration: movement.duration,
                    steps: movement.steps,
                    profile: movement.profile
                )

                try await AutomationServiceBridge.scroll(
                    automation: self.services.automation,
                    request: ScrollRequest(
                        direction: scrollDirection,
                        amount: self.amount,
                        target: nil,
                        smooth: self.smooth,
                        delay: self.delay,
                        snapshotId: nil
                    )
                )

                let outputPayload = BrowserScrollOutput(
                    success: true,
                    targetUrl: handle.target.url,
                    direction: scrollDirection.rawValue,
                    amount: self.amount,
                    onElement: resolved
                )
                self.output(outputPayload) {
                    print(
                        "scrolled \(scrollDirection.rawValue) by \(self.amount) at "
                            + "(\(Int(resolved.screenPoint.x)), \(Int(resolved.screenPoint.y)))"
                    )
                }
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }
    }
}
