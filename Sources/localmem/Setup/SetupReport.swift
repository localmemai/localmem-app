import Foundation

struct SetupReport {
    struct Row { let name: String; let outcome: Result<RegistrationOutcome, Error> }
    let rows: [Row]

    static let headerLines: [String] = [
        "Localmem — installing MCP integration",
        String(repeating: "=", count: 56),
    ]

    /// Format a single completion line exactly as it appears in the final report.
    /// Lets SetupCommand stream the same line live as each registrar completes.
    static func formatRow(_ row: Row) -> String {
        let (symbol, detail) = symbolAndDetail(row.outcome)
        let paddedName = row.name.padding(toLength: 18, withPad: " ", startingAt: 0)
        return "\(symbol)  \(paddedName) \(detail)"
    }

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
        lines.append(Self.renderSummary(rows))
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

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
}

private extension RegistrationOutcome.Strategy {
    var label: String {
        switch self {
        case .cli: return "CLI"
        case .configFile: return "config file"
        }
    }
}
