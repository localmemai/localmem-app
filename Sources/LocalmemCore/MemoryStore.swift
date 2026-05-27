import Foundation
import GRDB

public actor MemoryStore {
    private let dbQueue: DatabaseQueue

    /// Opens the store at the default user-level database path
    /// (`~/Library/Application Support/Localmem/memory.sqlite3`).
    /// This is the only init exposed to consumers — production code never
    /// needs to choose a path. Tests reach the explicit-path init below via
    /// `@testable import`.
    public init() throws {
        try self.init(databaseURL: Paths.databaseURL())
    }

    init(databaseURL: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try Migrations.migrator.migrate(dbQueue)
    }

    // MARK: - Write

    public func add(
        content: String,
        type: MemoryType,
        title: String? = nil,
        tags: [String] = [],
        source: MemorySource
    ) async throws -> Memory {
        let memory = Memory(
            type: type,
            title: title,
            content: content,
            tags: tags,
            source: source
        )
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memories (id, type, title, content, source, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    memory.id.uuidString,
                    memory.type.rawValue,
                    memory.title,
                    Data(memory.content.utf8),
                    memory.source.rawValue,
                    DateFormat.iso8601.string(from: memory.createdAt),
                    DateFormat.iso8601.string(from: memory.updatedAt),
                ]
            )
            for tag in memory.tags {
                try db.execute(
                    sql: "INSERT INTO memory_tags (memory_id, tag) VALUES (?, ?)",
                    arguments: [memory.id.uuidString, tag]
                )
            }
        }
        return memory
    }

    // MARK: - Read

    public func get(id: UUID) async throws -> Memory? {
        try await dbQueue.read { db in
            try Self.fetchMemory(id: id.uuidString, in: db)
        }
    }

    public func recent(limit: Int = 20) async throws -> [Memory] {
        try await dbQueue.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM memories ORDER BY created_at DESC, rowid DESC LIMIT ?",
                arguments: [limit]
            )
            return try ids.compactMap { try Self.fetchMemory(id: $0, in: db) }
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> [Memory] {
        let fts = Self.sanitizeFTSQuery(query)
        guard !fts.isEmpty else { return [] }
        return try await dbQueue.read { db in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT memory_id FROM memories_fts
                    WHERE memories_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [fts, limit]
            )
            return try ids.compactMap { try Self.fetchMemory(id: $0, in: db) }
        }
    }

    // MARK: - Helpers

    private static func fetchMemory(id: String, in db: Database) throws -> Memory? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM memories WHERE id = ?",
            arguments: [id]
        ) else {
            return nil
        }
        let tags = try String.fetchAll(
            db,
            sql: "SELECT tag FROM memory_tags WHERE memory_id = ?",
            arguments: [id]
        )
        return try Memory(row: row, tags: tags)
    }

    /// Wraps user input so it cannot break FTS5 syntax.
    /// Quoting the whole query treats it as a phrase or sequence of phrases.
    private static func sanitizeFTSQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Row decoding

extension Memory {
    init(row: Row, tags: [String]) throws {
        guard
            let idString: String = row["id"],
            let id = UUID(uuidString: idString),
            let typeString: String = row["type"],
            let type = MemoryType(rawValue: typeString),
            let sourceString: String = row["source"],
            let source = MemorySource(rawValue: sourceString),
            let contentData: Data = row["content"],
            let content = String(data: contentData, encoding: .utf8),
            let createdAtString: String = row["created_at"],
            let createdAt = DateFormat.iso8601.date(from: createdAtString),
            let updatedAtString: String = row["updated_at"],
            let updatedAt = DateFormat.iso8601.date(from: updatedAtString)
        else {
            throw MemoryStoreError.decodingFailed
        }
        self.init(
            id: id,
            type: type,
            title: row["title"],
            content: content,
            tags: tags,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum MemoryStoreError: Error {
    case decodingFailed
}

// MARK: - Date formatting

enum DateFormat {
    // ISO8601DateFormatter is documented thread-safe; the property is a shared
    // instance we never mutate after construction. `nonisolated(unsafe)` opts
    // out of Swift 6's static-storage Sendable check.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
