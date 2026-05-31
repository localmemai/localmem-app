import Foundation
import GRDB

public actor MemoryStore {
    private let database: LocalmemDatabase

    /// Opens the store at the default user-level database path
    /// (`~/Library/Application Support/Localmem/localmem.sqlite3`).
    /// This is the only init exposed to consumers — production code never
    /// needs to choose a path. Tests reach the explicit-path init below via
    /// `@testable import`.
    public init() throws {
        try self.init(database: LocalmemDatabase())
    }

    init(databaseURL: URL) throws {
        try self.init(database: LocalmemDatabase(url: databaseURL))
    }

    public init(database: LocalmemDatabase) {
        self.database = database
    }

    // MARK: - Write

    public func add(
        content: String,
        type: MemoryType,
        title: String? = nil,
        tags: [String] = [],
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> Memory {
        // `source` mirrors the actor identity by construction so the memories
        // row and its inline audit row always agree on who created the memory.
        let memory = Memory(
            type: type,
            title: title,
            content: content,
            tags: tags,
            source: actorID
        )
        try await database.write { db in
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
                    memory.source,
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
            try ActivityStore.add(Activity(
                actorKind: actorKind,
                actorID: actorID,
                operation: "memory_store",
                memoryID: memory.id
            ), in: db)
        }
        return memory
    }

    /// Deletes the memory with the given id. Returns true if a row was removed,
    /// false if no memory with that id existed (idempotent).
    /// The `memories_after_delete` trigger handles the FTS index;
    /// `ON DELETE CASCADE` on `memory_tags` handles tag rows.
    public func delete(id: UUID, actorKind: ActorKind, actorID: String? = nil) async throws -> Bool {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM memories WHERE id = ?",
                arguments: [id.uuidString]
            )
            let existed = db.changesCount > 0
            try ActivityStore.add(Activity(
                actorKind: actorKind,
                actorID: actorID,
                operation: "memory_delete",
                memoryID: id,
                resultCount: existed ? 1 : 0
            ), in: db)
            return existed
        }
    }

    // MARK: - Read

    public func get(id: UUID) async throws -> Memory? {
        try await database.read { db in
            try Self.fetchMemory(id: id.uuidString, in: db)
        }
    }

    public func count() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
        }
    }

    /// Returns up to two memory ids whose string form starts with `prefix`
    /// (case-insensitive). Two is enough to detect ambiguity without
    /// materializing every candidate.
    public func findIDs(prefix: String) async throws -> [UUID] {
        let pattern = prefix + "%"
        return try await database.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM memories WHERE id LIKE ? LIMIT 2",
                arguments: [pattern]
            )
            return ids.compactMap { UUID(uuidString: $0) }
        }
    }

    public func recent(limit: Int = 20) async throws -> [Memory] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memories ORDER BY created_at DESC, rowid DESC LIMIT ?",
                arguments: [limit]
            )
            return try Self.attachTags(rows: rows, in: db)
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> [Memory] {
        let fts = Self.sanitizeFTSQuery(query)
        guard !fts.isEmpty else { return [] }
        return try await database.read { db in
            let orderedIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT memory_id FROM memories_fts
                    WHERE memories_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [fts, limit]
            )
            guard !orderedIDs.isEmpty else { return [] }
            let placeholders = Self.placeholders(count: orderedIDs.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                arguments: StatementArguments(orderedIDs)
            )
            let memories = try Self.attachTags(rows: rows, in: db)
            let byID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id.uuidString, $0) })
            return orderedIDs.compactMap { byID[$0] }
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

    /// Batched tag fetch for a set of already-loaded memory rows. Two queries
    /// total (the row select that produced `rows`, plus one tag select for all
    /// ids), regardless of how many memories were returned.
    private static func attachTags(rows: [Row], in db: Database) throws -> [Memory] {
        guard !rows.isEmpty else { return [] }
        let ids: [String] = rows.compactMap { $0["id"] }
        let placeholders = placeholders(count: ids.count)
        let tagRows = try Row.fetchAll(
            db,
            sql: """
                SELECT memory_id, tag FROM memory_tags
                WHERE memory_id IN (\(placeholders))
                ORDER BY memory_id, tag
                """,
            arguments: StatementArguments(ids)
        )
        var tagsByID: [String: [String]] = [:]
        for row in tagRows {
            guard let memID: String = row["memory_id"], let tag: String = row["tag"] else { continue }
            tagsByID[memID, default: []].append(tag)
        }
        return try rows.compactMap { row in
            guard let id: String = row["id"] else { return nil }
            return try Memory(row: row, tags: tagsByID[id] ?? [])
        }
    }

    private static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// Wraps user input so it cannot break FTS5 syntax.
    /// Quoting the whole query treats the input as a single phrase — wildcard,
    /// AND/OR/NEAR operators in user input become literal characters by design.
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
            source: row["source"],
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
