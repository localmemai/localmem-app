import Foundation

struct SetupReport {
    struct Row { let name: String; let outcome: Result<RegistrationOutcome, Error> }
    let rows: [Row]

    func render() -> String {
        var lines: [String] = []
        lines.append("LocalMem — installing MCP integration")
        lines.append(String(repeating: "=", count: 56))

        var registered = 0
        var skipped = 0
        var failed = 0

        for row in rows {
            let symbol: String
            let detail: String
            switch row.outcome {
            case .success(let outcome):
                switch outcome {
                case .registered(let via):
                    symbol = "✓"; detail = "registered (via \(via.label))"
                case .alreadyRegistered(let via):
                    symbol = "↺"; detail = "already registered (via \(via.label))"
                case .updated(let via):
                    symbol = "✓"; detail = "updated (via \(via.label))"
                case .skipped(let why):
                    symbol = "–"; detail = "not installed — skipped (\(why))"
                }
            case .failure(let err):
                symbol = "✗"; detail = "FAILED — \(err)"
            }

            switch row.outcome {
            case .success(.registered), .success(.updated), .success(.alreadyRegistered):
                registered += 1
            case .success(.skipped):
                skipped += 1
            case .failure:
                failed += 1
            }

            let paddedName = row.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            lines.append("\(symbol)  \(paddedName) \(detail)")
        }

        lines.append(String(repeating: "-", count: 56))
        lines.append("\(registered) registered · \(skipped) skipped · \(failed) failed")
        lines.append("")
        lines.append("Restart any open Claude / Codex / Antigravity / Cursor")
        lines.append("sessions to pick up the new MCP server.")
        return lines.joined(separator: "\n")
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
