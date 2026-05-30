import Foundation

/// Captures the connected MCP client's name once during `initialize`, then
/// hands it out to every tool call for audit attribution. Env-var fallback
/// covers clients that don't send `clientInfo`; the literal `"unknown-mcp"`
/// is the last resort so audit rows never carry a `nil` actor_id by accident.
actor MCPClientIdentity {
    private var captured: String?
    private let fallback: String

    init(fallback: String = ProcessInfo.processInfo.environment["LOCALMEM_CLIENT_ID"] ?? "unknown-mcp") {
        self.fallback = fallback
    }

    var name: String {
        captured ?? fallback
    }

    func set(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        captured = name
    }
}
