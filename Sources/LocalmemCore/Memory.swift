import Foundation

public struct Memory: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var type: MemoryType
    public var title: String?
    public var headline: String?
    public var content: String
    public var tags: [String]
    public var folderID: UUID
    public var sessionID: String?
    /// Free-form identifier for whoever wrote the row. Mirrors `activity.actor_id`
    /// for the inline audit row created at the same time — nil for CLI writes
    /// that don't set `LOCALMEM_CLIENT_ID`, the MCP client name otherwise.
    public var source: String?
    public var supersededBy: [UUID]?
    public var supersedes: [UUID]?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        type: MemoryType,
        title: String? = nil,
        headline: String? = nil,
        content: String,
        tags: [String] = [],
        folderID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        sessionID: String? = nil,
        source: String? = nil,
        supersededBy: [UUID]? = nil,
        supersedes: [UUID]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.headline = headline
        self.content = content
        self.tags = tags
        self.folderID = folderID
        self.sessionID = sessionID
        self.source = source
        self.supersededBy = supersededBy
        self.supersedes = supersedes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case fact, preference, decision, project, note
}
