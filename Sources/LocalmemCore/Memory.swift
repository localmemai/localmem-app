import Foundation

public struct Memory: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var type: MemoryType
    public var title: String?
    public var content: String
    public var tags: [String]
    public var excludedAgents: [String]
    /// Free-form identifier for whoever wrote the row. Mirrors `activity.actor_id`
    /// for the inline audit row created at the same time — nil for CLI writes
    /// that don't set `LOCALMEM_CLIENT_ID`, the MCP client name otherwise.
    public var source: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        type: MemoryType,
        title: String? = nil,
        content: String,
        tags: [String] = [],
        excludedAgents: [String] = [],
        source: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.tags = tags
        self.excludedAgents = excludedAgents
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case fact, preference, decision, project, note
}
