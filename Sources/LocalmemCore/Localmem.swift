import Foundation

/// Module-level constants and identity for Localmem. Lives in LocalmemCore so
/// the MCP server and the CLI registrars share one source of truth.
public enum Localmem {
    /// MCP tool names this build exposes that are safe to pre-authorize in
    /// every supported client (Claude Code, Claude Desktop, Cursor, Codex).
    /// Pre-authorization is opt-in by tool — new tools, especially destructive
    /// ones, must be added here explicitly.
    public static let preauthorizedToolNames: [String] = [
        "memory_recent",
        "memory_search",
        "memory_store",
    ]
}
