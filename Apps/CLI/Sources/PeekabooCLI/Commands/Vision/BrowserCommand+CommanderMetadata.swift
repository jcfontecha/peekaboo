import Commander

extension BrowserConnectionOptions {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "cdpPort",
                    help: "CDP port (default: 18800)",
                    long: "cdp-port"
                ),
                .commandOption(
                    "url",
                    help: "Filter page targets by URL substring",
                    long: "url"
                ),
            ]
        )
    }
}

extension BrowserInteractionOptions {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "profile",
                    help: "Cursor movement profile: human or linear",
                    long: "profile"
                ),
                .commandOption(
                    "duration",
                    help: "Cursor movement duration in milliseconds",
                    long: "duration"
                ),
            ],
            flags: [
                .commandFlag(
                    "noAutoFocus",
                    help: "Disable auto-focus before OS-level input",
                    long: "no-auto-focus"
                ),
                .commandFlag(
                    "ocr",
                    help: "Fallback to OCR when DOM query resolution fails",
                    long: "ocr"
                ),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.CoordsSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text)",
                    isOptional: false
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.ClickSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text)",
                    isOptional: false
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.HoldSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text)",
                    isOptional: false
                ),
                .make(
                    label: "durationMs",
                    help: "Hold duration in milliseconds",
                    isOptional: false
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.HoverSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text)",
                    isOptional: false
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.TypeSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text)",
                    isOptional: false
                ),
                .make(
                    label: "text",
                    help: "Text to type",
                    isOptional: false
                ),
            ],
            flags: [
                .commandFlag(
                    "clear",
                    help: "Clear field first (Cmd+A, Delete)",
                    long: "clear"
                ),
                .commandFlag(
                    "submit",
                    help: "Submit after typing (press Enter on the resolved element)",
                    long: "submit"
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.SelectSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query for the dropdown",
                    isOptional: false
                ),
                .make(
                    label: "value",
                    help: "Option value or visible text",
                    isOptional: false
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.ListSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.NavigateSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "url",
                    help: "Destination URL",
                    isOptional: false
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.SnapshotSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.EvaluateSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "expression",
                    help: "JavaScript expression to evaluate",
                    isOptional: false
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.WaitSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text)",
                    isOptional: false
                ),
            ],
            options: [
                .commandOption(
                    "timeoutMs",
                    help: "Maximum wait time in milliseconds",
                    long: "timeout-ms"
                ),
                .commandOption(
                    "intervalMs",
                    help: "Polling interval in milliseconds",
                    long: "interval-ms"
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.TextSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text). Omit to extract page text",
                    isOptional: true
                ),
            ],
            flags: [
                .commandFlag(
                    "trim",
                    help: "Trim leading and trailing whitespace",
                    long: "trim"
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}

@available(macOS 14.0, *)
extension BrowserCommand.ScrollSubcommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element query (CSS, XPath, or text)",
                    isOptional: false
                ),
            ],
            options: [
                .commandOption(
                    "direction",
                    help: "Scroll direction: up, down, left, or right",
                    long: "direction"
                ),
                .commandOption(
                    "amount",
                    help: "Number of scroll ticks",
                    long: "amount"
                ),
                .commandOption(
                    "delay",
                    help: "Delay between scroll ticks in milliseconds",
                    long: "delay"
                ),
            ],
            flags: [
                .commandFlag(
                    "smooth",
                    help: "Use smooth scrolling with smaller increments",
                    long: "smooth"
                ),
            ],
            optionGroups: [
                BrowserConnectionOptions.commanderSignature(),
                BrowserInteractionOptions.commanderSignature(),
            ]
        )
    }
}
