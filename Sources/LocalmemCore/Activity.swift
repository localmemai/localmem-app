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
}

public enum ActorKind: String, Codable, Sendable {
    case mcp, cli
}
