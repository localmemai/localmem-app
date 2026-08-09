import Foundation

public struct Activity: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let occurredAt: Date
    public let actorKind: ActorKind
    public let actorID: String?
    public let operation: String
    public let memoryID: UUID?
    public let query: String?
    public let resultCount: Int?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        actorKind: ActorKind,
        actorID: String? = nil,
        operation: String,
        memoryID: UUID? = nil,
        query: String? = nil,
        resultCount: Int? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.actorKind = actorKind
        self.actorID = actorID
        self.operation = operation
        self.memoryID = memoryID
        self.query = query
        self.resultCount = resultCount
    }

    /// Operations recording that an agent was refused something.
    ///
    /// `access_filtered` — the call succeeded but sensitive results were held
    /// back; `resultCount` is how many. `access_blocked` — the call was refused
    /// outright.
    ///
    /// Named here rather than as literals at each call site because they are
    /// compared across three targets: written by the MCP server, counted by the
    /// app's Blocked card, and styled by the audit log.
    public static let blockedOperations: Set<String> = ["access_filtered", "access_blocked"]
}

public enum ActorKind: String, Codable, Sendable {
    case mcp, cli
}
