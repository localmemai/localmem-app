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
        excludedAgents: [String] = [],
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> Memory {
        let normalizedExclusions = Self.normalizedAgents(excludedAgents)
        // `source` mirrors the actor identity by construction so the memories
        // row and its inline audit row always agree on who created the memory.
        let memory = Memory(
            type: type,
            title: title,
            content: content,
            tags: tags,
            excludedAgents: normalizedExclusions,
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
            try Self.replaceExclusions(memoryID: memory.id.uuidString, agents: normalizedExclusions, in: db)
            try ActivityStore.add(Activity(
                actorKind: actorKind,
                actorID: actorID,
                operation: "memory_store",
                memoryID: memory.id
            ), in: db)
        }
        return memory
    }

    /// Replaces an existing memory's mutable fields. Source and createdAt are
    /// preserved — those track provenance, not the latest edit. Tags are
    /// fully replaced (not diffed) inside the same transaction. The
    /// `memories_after_update` trigger keeps the FTS index in sync.
    @discardableResult
    public func update(
        id: UUID,
        content: String,
        type: MemoryType,
        title: String? = nil,
        tags: [String] = [],
        excludedAgents: [String]? = nil,
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> Memory {
        try await database.write { db in
            let now = Date()
            try db.execute(
                sql: """
                    UPDATE memories
                    SET type = ?, title = ?, content = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    type.rawValue,
                    title,
                    Data(content.utf8),
                    DateFormat.iso8601.string(from: now),
                    id.uuidString,
                ]
            )
            guard db.changesCount > 0 else {
                throw MemoryStoreError.notFound
            }

            try db.execute(
                sql: "DELETE FROM memory_tags WHERE memory_id = ?",
                arguments: [id.uuidString]
            )
            for tag in tags {
                try db.execute(
                    sql: "INSERT INTO memory_tags (memory_id, tag) VALUES (?, ?)",
                    arguments: [id.uuidString, tag]
                )
            }
            if let excludedAgents {
                try Self.replaceExclusions(
                    memoryID: id.uuidString,
                    agents: Self.normalizedAgents(excludedAgents),
                    in: db
                )
            }

            try ActivityStore.add(Activity(
                actorKind: actorKind,
                actorID: actorID,
                operation: "memory_update",
                memoryID: id
            ), in: db)

            guard let updated = try Self.fetchMemory(id: id.uuidString, in: db) else {
                throw MemoryStoreError.decodingFailed
            }
            return updated
        }
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
        try await get(id: id, requestingAgent: nil)
    }

    public func get(id: UUID, requestingAgent: String?) async throws -> Memory? {
        try await database.read { db in
            try Self.fetchMemory(id: id.uuidString, requestingAgent: requestingAgent, in: db)
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
        try await findIDs(prefix: prefix, requestingAgent: nil)
    }

    public func findIDs(prefix: String, requestingAgent: String?) async throws -> [UUID] {
        let pattern = prefix + "%"
        return try await database.read { db in
            let ids: [String]
            if let requestingAgent {
                ids = try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM memories
                        WHERE id LIKE ?
                          AND NOT EXISTS (
                              SELECT 1 FROM memory_agent_exclusions
                              WHERE memory_id = memories.id AND agent_id = ?
                          )
                        LIMIT 2
                        """,
                    arguments: [pattern, requestingAgent]
                )
            } else {
                ids = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM memories WHERE id LIKE ? LIMIT 2",
                    arguments: [pattern]
                )
            }
            return ids.compactMap { UUID(uuidString: $0) }
        }
    }

    public func recent(limit: Int = 20) async throws -> [Memory] {
        try await recent(limit: limit, requestingAgent: nil)
    }

    public func recent(limit: Int = 20, requestingAgent: String?) async throws -> [Memory] {
        try await database.read { db in
            let rows: [Row]
            if let requestingAgent {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM memories
                        WHERE NOT EXISTS (
                            SELECT 1 FROM memory_agent_exclusions
                            WHERE memory_id = memories.id AND agent_id = ?
                        )
                        ORDER BY created_at DESC, rowid DESC
                        LIMIT ?
                        """,
                    arguments: [requestingAgent, limit]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM memories ORDER BY created_at DESC, rowid DESC LIMIT ?",
                    arguments: [limit]
                )
            }
            return try Self.attachMetadata(rows: rows, in: db)
        }
    }

    public func blockedRecentCount(limit: Int = 20, requestingAgent: String) async throws -> Int {
        let trimmed = requestingAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return try await database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT id FROM memories
                        ORDER BY created_at DESC, rowid DESC
                        LIMIT ?
                    ) candidates
                    JOIN memory_agent_exclusions e ON e.memory_id = candidates.id
                    WHERE e.agent_id = ?
                    """,
                arguments: [limit, trimmed]
            ) ?? 0
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> [Memory] {
        try await search(query: query, limit: limit, requestingAgent: nil)
    }

    public func search(query: String, limit: Int = 20, requestingAgent: String?) async throws -> [Memory] {
        let fts = Self.sanitizeFTSQuery(query)
        guard !fts.isEmpty else { return [] }
        return try await database.read { db in
            let orderedIDs: [String]
            if let requestingAgent {
                orderedIDs = try String.fetchAll(
                    db,
                    sql: """
                        SELECT memory_id FROM memories_fts
                        WHERE memories_fts MATCH ?
                          AND NOT EXISTS (
                              SELECT 1 FROM memory_agent_exclusions
                              WHERE memory_id = memories_fts.memory_id AND agent_id = ?
                          )
                        ORDER BY rank
                        LIMIT ?
                        """,
                    arguments: [fts, requestingAgent, limit]
                )
            } else {
                orderedIDs = try String.fetchAll(
                    db,
                    sql: """
                        SELECT memory_id FROM memories_fts
                        WHERE memories_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                        """,
                    arguments: [fts, limit]
                )
            }
            guard !orderedIDs.isEmpty else { return [] }
            let placeholders = Self.placeholders(count: orderedIDs.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                arguments: StatementArguments(orderedIDs)
            )
            let memories = try Self.attachMetadata(rows: rows, in: db)
            let byID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id.uuidString, $0) })
            return orderedIDs.compactMap { byID[$0] }
        }
    }

    public func blockedSearchCount(query: String, limit: Int = 20, requestingAgent: String) async throws -> Int {
        let trimmed = requestingAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fts = Self.sanitizeFTSQuery(query)
        guard !trimmed.isEmpty, !fts.isEmpty else { return 0 }
        return try await database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT memory_id FROM memories_fts
                        WHERE memories_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                    ) candidates
                    JOIN memory_agent_exclusions e ON e.memory_id = candidates.memory_id
                    WHERE e.agent_id = ?
                    """,
                arguments: [fts, limit, trimmed]
            ) ?? 0
        }
    }

    // MARK: - Access management (agent-centric)

    /// Memories that currently exclude `agent`, newest first. Admin view — not
    /// subject to the read filter (callers are the CLI/app, never an MCP agent).
    public func memoriesExcluding(agent: String) async throws -> [Memory] {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT memories.* FROM memories
                    JOIN memory_agent_exclusions e ON e.memory_id = memories.id
                    WHERE e.agent_id = ?
                    ORDER BY memories.created_at DESC, memories.rowid DESC
                    """,
                arguments: [trimmed]
            )
            return try Self.attachMetadata(rows: rows, in: db)
        }
    }

    /// Adds or removes a single memory's exclusion for `agent`. Returns true if
    /// a row actually changed (idempotent otherwise).
    @discardableResult
    public func setExclusion(
        memoryID: UUID,
        agent: String,
        excluded: Bool,
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> Bool {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return try await database.write { db in
            if excluded {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO memory_agent_exclusions (memory_id, agent_id) VALUES (?, ?)",
                    arguments: [memoryID.uuidString, trimmed]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM memory_agent_exclusions WHERE memory_id = ? AND agent_id = ?",
                    arguments: [memoryID.uuidString, trimmed]
                )
            }
            let changed = db.changesCount > 0
            if changed {
                try ActivityStore.add(Activity(
                    actorKind: actorKind,
                    actorID: actorID,
                    operation: excluded ? "access_revoke" : "access_grant",
                    memoryID: memoryID
                ), in: db)
            }
            return changed
        }
    }

    /// Removes `agent` from every memory's denylist (full access). Returns the
    /// number of exclusions cleared.
    @discardableResult
    public func grantAllAccess(toAgent agent: String, actorKind: ActorKind, actorID: String? = nil) async throws -> Int {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return try await database.write { db in
            try db.execute(
                sql: "DELETE FROM memory_agent_exclusions WHERE agent_id = ?",
                arguments: [trimmed]
            )
            let n = db.changesCount
            if n > 0 {
                try ActivityStore.add(Activity(
                    actorKind: actorKind, actorID: actorID, operation: "access_grant_all"
                ), in: db)
            }
            return n
        }
    }

    /// Excludes `agent` from every memory (hide everything). Returns the number
    /// of new exclusions added.
    @discardableResult
    public func revokeAllAccess(fromAgent agent: String, actorKind: ActorKind, actorID: String? = nil) async throws -> Int {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return try await database.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO memory_agent_exclusions (memory_id, agent_id)
                    SELECT id, ? FROM memories
                    """,
                arguments: [trimmed]
            )
            let n = db.changesCount
            if n > 0 {
                try ActivityStore.add(Activity(
                    actorKind: actorKind, actorID: actorID, operation: "access_revoke_all"
                ), in: db)
            }
            return n
        }
    }

    // MARK: - Helpers

    private static func fetchMemory(id: String, requestingAgent: String? = nil, in db: Database) throws -> Memory? {
        let row: Row?
        if let requestingAgent {
            row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM memories
                    WHERE id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM memory_agent_exclusions
                          WHERE memory_id = memories.id AND agent_id = ?
                      )
                    """,
                arguments: [id, requestingAgent]
            )
        } else {
            row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM memories WHERE id = ?",
                arguments: [id]
            )
        }
        guard let row else {
            return nil
        }
        let tags = try String.fetchAll(
            db,
            sql: "SELECT tag FROM memory_tags WHERE memory_id = ?",
            arguments: [id]
        )
        let exclusions = try String.fetchAll(
            db,
            sql: "SELECT agent_id FROM memory_agent_exclusions WHERE memory_id = ? ORDER BY agent_id",
            arguments: [id]
        )
        return try Memory(row: row, tags: tags, excludedAgents: exclusions)
    }

    /// Batched metadata fetch for a set of already-loaded memory rows.
    private static func attachMetadata(rows: [Row], in db: Database) throws -> [Memory] {
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
        let exclusionRows = try Row.fetchAll(
            db,
            sql: """
                SELECT memory_id, agent_id FROM memory_agent_exclusions
                WHERE memory_id IN (\(placeholders))
                ORDER BY memory_id, agent_id
                """,
            arguments: StatementArguments(ids)
        )
        var exclusionsByID: [String: [String]] = [:]
        for row in exclusionRows {
            guard let memID: String = row["memory_id"], let agentID: String = row["agent_id"] else { continue }
            exclusionsByID[memID, default: []].append(agentID)
        }
        return try rows.compactMap { row in
            guard let id: String = row["id"] else { return nil }
            return try Memory(
                row: row,
                tags: tagsByID[id] ?? [],
                excludedAgents: exclusionsByID[id] ?? []
            )
        }
    }

    private static func replaceExclusions(memoryID: String, agents: [String], in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM memory_agent_exclusions WHERE memory_id = ?",
            arguments: [memoryID]
        )
        for agent in agents {
            try db.execute(
                sql: "INSERT INTO memory_agent_exclusions (memory_id, agent_id) VALUES (?, ?)",
                arguments: [memoryID, agent]
            )
        }
    }

    private static func normalizedAgents(_ agents: [String]) -> [String] {
        Array(Set(agents.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// Turns user input into a safe, live-search-friendly FTS5 expression.
    ///
    /// 1. Strip characters that would change the FTS5 grammar (`"`, `(`, `)`,
    ///    `*`, `:`, `+`, `-`, `^`). Wildcard/AND/OR/NEAR operators from user
    ///    input become no-ops by construction.
    /// 2. Split on whitespace into tokens.
    /// 3. Wrap each token as a phrase-prefix: `"tok"*`. This matches tokens
    ///    that *start with* `tok`, so typing "cof" hits "coffee" the moment
    ///    the third character lands — the UX users actually expect.
    /// 4. Join with space (implicit AND across tokens).
    private static func sanitizeFTSQuery(_ raw: String) -> String {
        let forbidden: Set<Character> = ["\"", "(", ")", "*", ":", "+", "-", "^"]
        let cleaned = String(raw.filter { !forbidden.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

// MARK: - Row decoding

extension Memory {
    init(row: Row, tags: [String], excludedAgents: [String]) throws {
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
            excludedAgents: excludedAgents,
            source: row["source"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum MemoryStoreError: Error {
    case decodingFailed
    case notFound
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
