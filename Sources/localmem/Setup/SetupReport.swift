import Foundation
import LocalmemCore

struct SetupReport {
    struct Row {
        let name: String
        let outcome: Result<RegistrationOutcome, Error>
        /// nil = pre-auth was not attempted (e.g. registration was skipped, or
        /// the user passed `--no-preauthorize`).
        let preauthorization: Result<PreauthorizationOutcome, Error>?

        init(
            name: String,
            outcome: Result<RegistrationOutcome, Error>,
            preauthorization: Result<PreauthorizationOutcome, Error>? = nil
        ) {
            self.name = name
            self.outcome = outcome
            self.preauthorization = preauthorization
        }
    }
    struct InstructionRow { let name: String; let outcome: Result<InstallationOutcome, Error> }
    let rows: [Row]
    var instructionRows: [InstructionRow] = []

    static let headerLines: [String] = [
        "Localmem — installing MCP integration",
        String(repeating: "=", count: 56),
    ]

    /// Format a single completion line exactly as it appears in the final report.
    /// Lets SetupCommand stream the same line live as each registrar completes.
    static func formatRow(_ row: Row) -> String {
        let (symbol, detail) = symbolAndDetail(row.outcome)
        let paddedName = row.name.padding(toLength: 18, withPad: " ", startingAt: 0)
        // Pad the detail to align the pre-auth column across rows — but never
        // truncate (some labels are longer than 32 chars). Skip padding entirely
        // when there's no pre-auth column to align with.
        guard let preauthResult = row.preauthorization else {
            return "\(symbol)  \(paddedName) \(detail)"
        }
        let padded = detail.count >= 32 ? detail : detail.padding(toLength: 32, withPad: " ", startingAt: 0)
        return "\(symbol)  \(paddedName) \(padded) · \(preauthDetail(preauthResult))"
    }

    /// Same formatting as `formatRow(Row)`, for the instructions-injection pass.
    static func formatInstructionRow(_ row: InstructionRow) -> String {
        let (symbol, detail) = instructionSymbolAndDetail(row.outcome)
        let paddedName = row.name.padding(toLength: 18, withPad: " ", startingAt: 0)
        return "\(symbol)  \(paddedName) \(detail)"
    }

    /// Section header for the instructions pass.
    static let instructionsHeaderLines: [String] = [
        "",
        "Installing agent instructions",
        String(repeating: "-", count: 56),
    ]

    /// Bottom of the report: separator, counts, and the restart hint.
    static func renderSummary(_ rows: [Row]) -> String {
        var registered = 0, skipped = 0, failed = 0
        for row in rows {
            switch row.outcome {
            case .success(.registered), .success(.updated), .success(.alreadyRegistered):
                registered += 1
            case .success(.skipped): skipped += 1
            case .failure: failed += 1
            }
        }
        return [
            String(repeating: "-", count: 56),
            "\(registered) registered · \(skipped) skipped · \(failed) failed",
            "",
            "Restart any open Claude / Codex / Antigravity / Cursor",
            "sessions to pick up the new MCP server.",
        ].joined(separator: "\n")
    }

    /// Fallback: render the whole report as one string (used in non-TTY mode).
    func render() -> String {
        var lines = Self.headerLines
        for row in rows { lines.append(Self.formatRow(row)) }
        if !instructionRows.isEmpty {
            lines.append(contentsOf: Self.instructionsHeaderLines)
            for row in instructionRows { lines.append(Self.formatInstructionRow(row)) }
        }
        lines.append(Self.renderSummary(rows))
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private static func preauthDetail(_ outcome: Result<PreauthorizationOutcome, Error>) -> String {
        switch outcome {
        case .success(let o):
            switch o {
            case .authorized(let scope):        return "auto-approved (\(scope.label))"
            case .alreadyAuthorized(let scope): return "auto-approved (\(scope.label))"
            case .updated(let scope):           return "auto-approved (\(scope.label))"
            case .unsupported:                  return "prompts each call"
            case .skipped(let why):             return "auto-approve skipped (\(why))"
            }
        case .failure(let err):
            return "auto-approve FAILED — \(err)"
        }
    }

    private static func symbolAndDetail(_ outcome: Result<RegistrationOutcome, Error>) -> (String, String) {
        switch outcome {
        case .success(let o):
            switch o {
            case .registered(let via):        return ("✓", "registered (via \(via.label))")
            case .alreadyRegistered(let via): return ("↺", "already registered (via \(via.label))")
            case .updated(let via):           return ("✓", "updated (via \(via.label))")
            case .skipped(let why):           return ("–", "not installed — skipped (\(why))")
            }
        case .failure(let err):
            return ("✗", "FAILED — \(err)")
        }
    }

    private static func instructionSymbolAndDetail(_ outcome: Result<InstallationOutcome, Error>) -> (String, String) {
        switch outcome {
        case .success(let o):
            switch o {
            case .created:                return ("✓", "instructions file created")
            case .imported:               return ("✓", "import line added")
            case .alreadyImported:        return ("↺", "import line already present")
            case .skipped(let why):       return ("–", "skipped (\(why))")
            }
        case .failure(let err):
            return ("✗", "FAILED — \(err)")
        }
    }
}

private extension RegistrationOutcome.Strategy {
    var label: String {
        switch self {
        case .cli: return "CLI"
        case .configFile: return "config file"
        }
    }
}

private extension PreauthorizationOutcome.Scope {
    var label: String {
        switch self {
        case .tools(let count): return "\(count) tool\(count == 1 ? "" : "s")"
        case .server:           return "server-wide"
        }
    }
}
