import Foundation

public struct Agent: Identifiable, Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case all = "all"
        case nonSensitiveOnly = "non_sensitive_only"
    }

    public let id: String // canonical agent name, e.g. 'claude-code'
    public var status: Status
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        status: Status = .all,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
