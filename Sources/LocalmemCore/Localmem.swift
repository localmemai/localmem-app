import Foundation

/// Module-level constants and identity for Localmem. Lives in LocalmemCore so
/// the MCP server and the CLI registrars share one source of truth.
public enum Localmem {
    /// MCP tool names this build exposes that are safe to pre-authorize in
    /// every supported client (Claude Code, Claude Desktop, Cursor, Codex).
    /// Pre-authorization is opt-in by tool — new tools, especially destructive
    /// ones, must be added here explicitly.
    ///
    /// **Deliberately excluded:** `memory_update`. Every update overwrites a
    /// row that prior sessions may have relied on, so each call must surface
    /// in the client's standard tool-approval prompt. Adding it here would
    /// silently auto-approve overwrites — never do that. Same logic will apply
    /// to `memory_delete` if/when it ships.
    public static let preauthorizedToolNames: [String] = [
        "memory_recent",
        "memory_search",
        "memory_store",
    ]
}
