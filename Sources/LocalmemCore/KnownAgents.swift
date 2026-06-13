import Foundation

public struct KnownAgent: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let symbol: String
}

public enum KnownAgents {
    public static let all: [KnownAgent] = [
        .init(id: "claude-code", displayName: "Claude Code", symbol: "ant.fill"),
        .init(id: "claude-desktop", displayName: "Claude Desktop", symbol: "ant"),
        .init(id: "cursor", displayName: "Cursor", symbol: "cursorarrow.rays"),
        .init(id: "codex", displayName: "Codex", symbol: "command.square.fill"),
        .init(id: "antigravity-client", displayName: "Antigravity", symbol: "sparkles"),
    ]
}
