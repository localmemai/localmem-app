import Foundation

public struct Folder: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case `default` = "default"
        case project = "project"
        case source = "source"
        case manual = "manual"
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var projectRoot: String?
    public var isSensitive: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        projectRoot: String? = nil,
        isSensitive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.projectRoot = projectRoot
        self.isSensitive = isSensitive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
