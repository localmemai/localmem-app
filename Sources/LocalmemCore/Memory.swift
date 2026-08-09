import Foundation

public struct Memory: Codable, Identifiable, Sendable, Equatable {
    /// Mirrors `MemoryStore.inboxFolderID`; declared here so `Memory` stays
    /// free of any store dependency.
    public static let inboxFolderID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

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
        folderID: UUID = Memory.inboxFolderID,
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

// MARK: - Codable

extension Memory {
    private enum CodingKeys: String, CodingKey {
        case id, type, title, headline, content, tags, folderID, sessionID
        case source, supersededBy, supersedes, createdAt, updatedAt
    }

    /// Decoded by hand so archives written before folders existed still load.
    /// The synthesized initializer would fail the whole file on a missing
    /// `folderID`, which is every export from a pre-folders release — and the
    /// archive's own schema version could not catch it, because the field was
    /// added without bumping it. Fields absent from older archives fall back to
    /// the same defaults `init` uses.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            type: try c.decode(MemoryType.self, forKey: .type),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            headline: try c.decodeIfPresent(String.self, forKey: .headline),
            content: try c.decode(String.self, forKey: .content),
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            folderID: try c.decodeIfPresent(UUID.self, forKey: .folderID) ?? Memory.inboxFolderID,
            sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID),
            source: try c.decodeIfPresent(String.self, forKey: .source),
            supersededBy: try c.decodeIfPresent([UUID].self, forKey: .supersededBy),
            supersedes: try c.decodeIfPresent([UUID].self, forKey: .supersedes),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            updatedAt: try c.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case fact, preference, decision, project, note
}
