import Foundation

/// Captures the connected MCP client's name once during `initialize`, then
/// hands it out to every tool call for audit attribution. Env-var fallback
/// covers clients that don't send `clientInfo`; the literal `"unknown-mcp"`
/// is the last resort so audit rows never carry a `nil` actor_id by accident.
actor MCPClientIdentity {
    private var captured: String?
    private let fallback: String

    init(fallback: String = ProcessInfo.processInfo.environment["LOCALMEM_CLIENT_ID"] ?? "unknown-mcp") {
        self.fallback = Self.normalized(fallback)
    }

    var name: String {
        captured ?? fallback
    }

    func set(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        captured = Self.normalized(name)
    }

    static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        switch lowered {
        case "codex", "codex-cli", "codex-mcp-client", "openai-codex":
            return "codex"
        case "claude", "claude-code", "claude_code", "claude code":
            return "claude-code"
        case "claude-desktop", "claude_desktop", "claude desktop":
            return "claude-desktop"
        case "cursor", "cursor-mcp-client", "cursor mcp client":
            return "cursor"
        case "antigravity", "antigravity-client", "antigravity_client":
            return "antigravity-client"
        default:
            return trimmed.isEmpty ? "unknown-mcp" : trimmed
        }
    }
}
