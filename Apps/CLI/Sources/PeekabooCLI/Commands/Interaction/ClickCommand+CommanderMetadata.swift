import Commander

extension ClickCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element text or query to click",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID (uses latest if not specified)",
                    long: "snapshot"
                ),
                .commandOption(
                    "on",
                    help: "Element ID to click (e.g., B1, T2)",
                    long: "on"
                ),
                .commandOption(
                    "id",
                    help: "Element ID to click (alias for --on)",
                    long: "id"
                ),
                .commandOption(
                    "coords",
                    help: "Click at coordinates (x,y)",
                    long: "coords"
                ),
                .commandOption(
                    "waitFor",
                    help: "Maximum milliseconds to wait for element",
                    long: "wait-for"
                ),
                .commandOption(
                    "profile",
                    help: "Cursor movement profile before clicking: linear or human",
                    long: "profile"
                ),
                .commandOption(
                    "duration",
                    help: "Cursor movement duration in milliseconds before clicking",
                    long: "duration"
                ),
                .commandOption(
                    "steps",
                    help: "Number of movement steps before clicking",
                    long: "steps"
                ),
                .commandOption(
                    "holdDuration",
                    help: "How long to hold the mouse button in milliseconds",
                    long: "hold-duration"
                ),
            ],
            flags: [
                .commandFlag(
                    "double",
                    help: "Double-click instead of single click",
                    long: "double"
                ),
                .commandFlag(
                    "right",
                    help: "Right-click (secondary click)",
                    long: "right"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
