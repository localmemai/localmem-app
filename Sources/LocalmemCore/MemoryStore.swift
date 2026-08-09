import Foundation
import GRDB

public actor MemoryStore {
    private let database: LocalmemDatabase

    /// The default folder's id is a fixed sentinel, not a generated UUID, so it
    /// can serve as a SQL `DEFAULT` on `memories.folder_id` — a binary that
    /// predates folders still writes valid rows instead of violating NOT NULL.
    public static let inboxFolderIDString = "00000000-0000-0000-0000-000000000000"
    public static let inboxFolderID = UUID(uuidString: inboxFolderIDString)!

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
        headline: String? = nil,
        tags: [String] = [],
        folderID: UUID? = nil,
        sessionID: String? = nil,
        supersedes: [UUID] = [],
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> Memory {
        let resolvedFolderID = folderID ?? Self.inboxFolderID
        let resolvedHeadline = headline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? headline
            : Self.generateHeadline(from: content)
        let memory = Memory(
            type: type,
            title: title,
            headline: resolvedHeadline,
            content: content,
            tags: tags,
            folderID: resolvedFolderID,
            sessionID: sessionID,
            source: actorID,
            supersedes: supersedes.isEmpty ? nil : supersedes
        )
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memories (id, type, title, headline, content, folder_id, session_id, source, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    memory.id.uuidString,
                    memory.type.rawValue,
                    memory.title,
                    memory.headline,
                    Data(memory.content.utf8),
                    memory.folderID.uuidString,
                    memory.sessionID,
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
            for supersededID in supersedes where supersededID != memory.id {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO memory_supersessions (superseded_id, superseding_id, created_at) VALUES (?, ?, ?)",
                    arguments: [supersededID.uuidString, memory.id.uuidString, DateFormat.iso8601.string(from: memory.createdAt)]
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

    /// Bulk-inserts memories from an exported archive, preserving each row's
    /// original id, timestamps, tags, exclusions, and source for full-fidelity
    /// transfer between machines. Existing ids are skipped (never overwritten),
    /// so re-importing the same archive is idempotent. A single `memory_import`
    /// activity records the batch, tagged with the number actually added.
    @discardableResult
    public func importMemories(
        _ memories: [Memory],
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> ImportSummary {
        guard !memories.isEmpty else { return ImportSummary(imported: 0, skipped: 0) }
        return try await database.write { db in
            var imported = 0
            for memory in memories {
                guard try Self.insertPreservingIdentity(memory, in: db) else { continue }
                imported += 1
            }
            try ActivityStore.add(Activity(
                actorKind: actorKind,
                actorID: actorID,
                operation: "memory_import",
                resultCount: imported
            ), in: db)
            return ImportSummary(imported: imported, skipped: memories.count - imported)
        }
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
        headline: String? = nil,
        tags: [String] = [],
        folderID: UUID? = nil,
        supersedes: [UUID]? = nil,
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> Memory {
        try await database.write { db in
            let now = Date()
            let resolvedHeadline = headline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? headline
                : Self.generateHeadline(from: content)
            
            if let folderID {
                try db.execute(
                    sql: """
                        UPDATE memories
                        SET type = ?, title = ?, headline = ?, content = ?, folder_id = ?, updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        type.rawValue,
                        title,
                        resolvedHeadline,
                        Data(content.utf8),
                        folderID.uuidString,
                        DateFormat.iso8601.string(from: now),
                        id.uuidString,
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE memories
                        SET type = ?, title = ?, headline = ?, content = ?, updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        type.rawValue,
                        title,
                        resolvedHeadline,
                        Data(content.utf8),
                        DateFormat.iso8601.string(from: now),
                        id.uuidString,
                    ]
                )
            }
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

            if let supersedes {
                try Self.replaceSupersessions(
                    supersedingID: id.uuidString,
                    supersededIDs: supersedes,
                    at: now,
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
                        SELECT memories.id FROM memories
                        JOIN folders ON memories.folder_id = folders.id
                        WHERE memories.id LIKE ?
                          AND (folders.sensitive = 0 OR ? = 'all')
                        LIMIT 2
                        """,
                    arguments: [pattern, try Self.agentStatusValue(requestingAgent, in: db)]
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

    public func recent(limit: Int = 20) async throws -> (memories: [Memory], withheld: Int) {
        try await recent(limit: limit, requestingAgent: nil, includeSuperseded: false)
    }

    public func recent(limit: Int = 20, requestingAgent: String?) async throws -> (memories: [Memory], withheld: Int) {
        try await recent(limit: limit, requestingAgent: requestingAgent, includeSuperseded: false)
    }

    public func recent(limit: Int = 20, requestingAgent: String? = nil, includeSuperseded: Bool = false) async throws -> (memories: [Memory], withheld: Int) {
        let clampedLimit = limit > 0 ? limit : 20
        return try await database.read { db in
            let statusVal: String
            if let requestingAgent {
                statusVal = try String.fetchOne(db, sql: "SELECT status FROM agents WHERE id = ?", arguments: [requestingAgent]) ?? "all"
            } else {
                statusVal = "all"
            }
            
            let supersessionFilter = includeSuperseded
                ? ""
                : "AND NOT EXISTS (SELECT 1 FROM memory_supersessions WHERE superseded_id = memories.id)"
            
            // How many of the rows this caller *would* have seen were held
            // back. Scoped to the same top-`limit` window the query returns —
            // counting every sensitive row in the vault reports withholding
            // that never happened (`recent(limit: 3)` claiming 30 withheld) and
            // scans the whole table on every call.
            var totalWithheld = 0
            if statusVal == "non_sensitive_only" {
                totalWithheld = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM (
                            SELECT folders.sensitive AS sensitive FROM memories
                            JOIN folders ON memories.folder_id = folders.id
                            WHERE 1=1
                            \(supersessionFilter)
                            ORDER BY memories.created_at DESC, memories.rowid DESC
                            LIMIT ?
                        ) candidates
                        WHERE candidates.sensitive = 1
                        """,
                    arguments: [clampedLimit]
                ) ?? 0
            }
            
            // Now execute the actual limited query with status filter
            let sql = """
                SELECT memories.id, memories.type, memories.title, memories.headline, memories.folder_id, memories.session_id, memories.source, memories.created_at, memories.updated_at, EXISTS (
                    SELECT 1 FROM memory_supersessions WHERE superseded_id = memories.id
                ) AS is_superseded
                FROM memories
                JOIN folders ON memories.folder_id = folders.id
                WHERE (folders.sensitive = 0 OR ? = 'all')
                \(supersessionFilter)
                ORDER BY is_superseded ASC, memories.created_at DESC, memories.rowid DESC
                LIMIT ?
                """
            
            let rows = try Row.fetchAll(db, sql: sql, arguments: [statusVal, clampedLimit])
            let memories = try Self.attachMetadata(rows: rows, in: db, compact: true)
            return (memories: memories, withheld: totalWithheld)
        }
    }

    /// Exposes a batch retrieval method to get the full bodies for a set of memory IDs.
    public func get(ids: [UUID], requestingAgent: String? = nil) async throws -> [Memory] {
        guard !ids.isEmpty else { return [] }
        let idStrings = ids.map { $0.uuidString }
        return try await database.read { db in
            let placeholders = Self.placeholders(count: idStrings.count)
            let rows: [Row]
            if let requestingAgent {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT memories.* FROM memories
                        JOIN folders ON memories.folder_id = folders.id
                        WHERE memories.id IN (\(placeholders))
                          AND (folders.sensitive = 0 OR ? = 'all')
                        """,
                    arguments: StatementArguments(idStrings)
                        + [try Self.agentStatusValue(requestingAgent, in: db)]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM memories WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(idStrings)
                )
            }
            // `IN (…)` returns rows in arbitrary order; re-project onto the
            // caller's id order so results line up with the request. Ids that
            // were missing or access-blocked simply don't appear (the MCP layer
            // reports the shortfall to the caller).
            let memories = try Self.attachMetadata(rows: rows, in: db, compact: false)
            let byID = Dictionary(memories.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
            return idStrings.compactMap { byID[$0] }
        }
    }

    /// Directly links a superseded memory to its superseding successor (append-only history).
    public func supersede(supersededID: UUID, supersedingID: UUID, actorKind: ActorKind, actorID: String? = nil) async throws {
        guard supersededID != supersedingID else {
            throw MemoryStoreError.invalidSupersession
        }
        try await database.write { db in
            let now = Date()
            try db.execute(
                sql: "INSERT OR REPLACE INTO memory_supersessions (superseded_id, superseding_id, created_at) VALUES (?, ?, ?)",
                arguments: [supersededID.uuidString, supersedingID.uuidString, DateFormat.iso8601.string(from: now)]
            )
            try ActivityStore.add(Activity(
                actorKind: actorKind,
                actorID: actorID,
                operation: "memory_supersede",
                memoryID: supersedingID
            ), in: db)
        }
    }

    /// Every memory, newest first — the admin/export view (no agent read
    /// filter). Used by the app's Export feature to serialize the whole vault.
    public func all() async throws -> [Memory] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memories ORDER BY created_at DESC, rowid DESC"
            )
            return try Self.attachMetadata(rows: rows, in: db)
        }
    }

    /// One folder's memories, newest first, as a compact index (no bodies).
    /// The app's folder tree loads children per folder on expand, so it must
    /// not depend on whatever window `recent(limit:)` happened to return.
    /// Admin view — no agent read filter, since the caller is the app.
    public func memories(inFolder folderID: UUID, limit: Int = 500) async throws -> [Memory] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT memories.id, memories.type, memories.title, memories.headline,
                           memories.folder_id, memories.session_id, memories.source,
                           memories.created_at, memories.updated_at, EXISTS (
                        SELECT 1 FROM memory_supersessions WHERE superseded_id = memories.id
                    ) AS is_superseded
                    FROM memories
                    WHERE memories.folder_id = ?
                    ORDER BY is_superseded ASC, memories.created_at DESC, memories.rowid DESC
                    LIMIT ?
                    """,
                arguments: [folderID.uuidString, limit]
            )
            return try Self.attachMetadata(rows: rows, in: db, compact: true)
        }
    }

    public func blockedRecentCount(limit: Int = 20, requestingAgent: String) async throws -> Int {
        let trimmed = requestingAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return try await database.read { db in
            let statusVal = try String.fetchOne(db, sql: "SELECT status FROM agents WHERE id = ?", arguments: [trimmed]) ?? "all"
            guard statusVal == "non_sensitive_only" else { return 0 }
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT id, folder_id FROM memories
                        ORDER BY created_at DESC, rowid DESC
                        LIMIT ?
                    ) candidates
                    JOIN folders f ON f.id = candidates.folder_id
                    WHERE f.sensitive = 1
                    """,
                arguments: [limit]
            ) ?? 0
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> (memories: [Memory], withheld: Int) {
        try await search(query: query, limit: limit, requestingAgent: nil, includeSuperseded: false)
    }

    public func search(query: String, limit: Int = 20, requestingAgent: String?) async throws -> (memories: [Memory], withheld: Int) {
        try await search(query: query, limit: limit, requestingAgent: requestingAgent, includeSuperseded: false)
    }

    public func search(
        query: String,
        limit: Int = 20,
        requestingAgent: String? = nil,
        includeSuperseded: Bool = false
    ) async throws -> (memories: [Memory], withheld: Int) {
        let fts = Self.sanitizeFTSQuery(query)
        guard !fts.isEmpty else { return (memories: [], withheld: 0) }
        let clampedLimit = limit > 0 ? limit : 20
        
        return try await database.read { db in
            let statusVal: String
            if let requestingAgent {
                statusVal = try String.fetchOne(db, sql: "SELECT status FROM agents WHERE id = ?", arguments: [requestingAgent]) ?? "all"
            } else {
                statusVal = "all"
            }
            
            let supersessionFilter = includeSuperseded
                ? ""
                : "AND NOT EXISTS (SELECT 1 FROM memory_supersessions WHERE superseded_id = memories_fts.memory_id)"
            
            // Scoped to the same top-`limit` window as the query below, and
            // skipped entirely for unrestricted callers — see `recent`.
            var totalWithheld = 0
            if statusVal == "non_sensitive_only" {
                totalWithheld = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM (
                            SELECT folders.sensitive AS sensitive FROM memories_fts
                            JOIN memories ON memories_fts.memory_id = memories.id
                            JOIN folders ON memories.folder_id = folders.id
                            WHERE memories_fts MATCH ?
                            \(supersessionFilter)
                            ORDER BY rank
                            LIMIT ?
                        ) candidates
                        WHERE candidates.sensitive = 1
                        """,
                    arguments: [fts, clampedLimit]
                ) ?? 0
            }
            
            // Now run actual FTS search with ranking and limit
            let sql = """
                SELECT memories_fts.memory_id, EXISTS (
                    SELECT 1 FROM memory_supersessions WHERE superseded_id = memories_fts.memory_id
                ) AS is_superseded
                FROM memories_fts
                JOIN memories ON memories_fts.memory_id = memories.id
                JOIN folders ON memories.folder_id = folders.id
                WHERE memories_fts MATCH ?
                  AND (folders.sensitive = 0 OR ? = 'all')
                \(supersessionFilter)
                ORDER BY is_superseded ASC, rank
                LIMIT ?
                """
            
            let orderedIDs = try String.fetchAll(db, sql: sql, arguments: [fts, statusVal, clampedLimit])
            guard !orderedIDs.isEmpty else { return (memories: [], withheld: 0) }
            let placeholders = Self.placeholders(count: orderedIDs.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, type, title, headline, folder_id, session_id, source, created_at, updated_at FROM memories WHERE id IN (\(placeholders))",
                arguments: StatementArguments(orderedIDs)
            )
            let memories = try Self.attachMetadata(rows: rows, in: db, compact: true)
            let byID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id.uuidString, $0) })
            let sorted = orderedIDs.compactMap { byID[$0] }
            return (memories: sorted, withheld: totalWithheld)
        }
    }

    public func blockedSearchCount(query: String, limit: Int = 20, requestingAgent: String) async throws -> Int {
        let trimmed = requestingAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fts = Self.sanitizeFTSQuery(query)
        guard !trimmed.isEmpty, !fts.isEmpty else { return 0 }
        return try await database.read { db in
            let statusVal = try String.fetchOne(db, sql: "SELECT status FROM agents WHERE id = ?", arguments: [trimmed]) ?? "all"
            guard statusVal == "non_sensitive_only" else { return 0 }
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (
                        SELECT memory_id FROM memories_fts
                        WHERE memories_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                    ) candidates
                    JOIN memories m ON m.id = candidates.memory_id
                    JOIN folders f ON f.id = m.folder_id
                    WHERE f.sensitive = 1
                    """,
                arguments: [fts, limit]
            ) ?? 0
        }
    }

    // MARK: - Access management (agent-centric)

    /// An agent's stored status, or `"all"` when it has never been seen — an
    /// unknown agent is never restricted, so installing a tool cannot silently
    /// hide anything. A `nil` requester (CLI/app) is likewise unrestricted.
    static func agentStatusValue(_ agent: String?, in db: Database) throws -> String {
        guard let agent, !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "all"
        }
        return try String.fetchOne(
            db,
            sql: "SELECT status FROM agents WHERE id = ?",
            arguments: [agent]
        ) ?? "all"
    }

    // MARK: - Helpers

    /// Inserts a memory preserving its id, timestamps, tags, and
    /// source (INSERT OR IGNORE — a pre-existing id is a no-op and returns
    /// false, so callers never touch an existing memory's child rows). Static
    /// so callers composing larger transactions (`importMemories`,
    /// `SourceStore.replaceMemories`) share one insert path.
    static func insertPreservingIdentity(_ memory: Memory, in db: Database) throws -> Bool {
        let headline = memory.headline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? memory.headline
            : Self.generateHeadline(from: memory.content)

        // Archives carry memories but not folders, so a `folder_id` from
        // another vault names a row that does not exist here. `folder_id` is a
        // foreign key, so writing it verbatim aborts the whole import. File
        // those in Inbox — the memory matters, its folder on some other machine
        // does not, and Inbox is never sensitive so nothing is hidden by the
        // fallback.
        let folderExists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM folders WHERE id = ?)",
            arguments: [memory.folderID.uuidString]
        ) ?? false
        let folderID = folderExists ? memory.folderID.uuidString : Self.inboxFolderIDString
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO memories (id, type, title, headline, content, folder_id, session_id, source, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                memory.id.uuidString,
                memory.type.rawValue,
                memory.title,
                headline,
                Data(memory.content.utf8),
                folderID,
                memory.sessionID,
                memory.source,
                DateFormat.iso8601.string(from: memory.createdAt),
                DateFormat.iso8601.string(from: memory.updatedAt),
            ]
        )
        guard db.changesCount > 0 else { return false }
        for tag in memory.tags {
            try db.execute(
                sql: "INSERT INTO memory_tags (memory_id, tag) VALUES (?, ?)",
                arguments: [memory.id.uuidString, tag]
            )
        }
        return true
    }

    private static func fetchMemory(id: String, requestingAgent: String? = nil, in db: Database) throws -> Memory? {
        let row: Row?
        if let requestingAgent {
            let statusVal = try String.fetchOne(db, sql: "SELECT status FROM agents WHERE id = ?", arguments: [requestingAgent]) ?? "all"
            row = try Row.fetchOne(
                db,
                sql: """
                    SELECT m.* FROM memories m
                    JOIN folders f ON m.folder_id = f.id
                    WHERE m.id = ?
                      AND (f.sensitive = 0 OR ? = 'all')
                    """,
                arguments: [id, statusVal]
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
        let supersededBy = try String.fetchAll(
            db,
            sql: "SELECT superseding_id FROM memory_supersessions WHERE superseded_id = ?",
            arguments: [id]
        ).compactMap { UUID(uuidString: $0) }
        let supersedes = try String.fetchAll(
            db,
            sql: "SELECT superseded_id FROM memory_supersessions WHERE superseding_id = ?",
            arguments: [id]
        ).compactMap { UUID(uuidString: $0) }
        return try Memory(row: row, tags: tags, supersededBy: supersededBy, supersedes: supersedes)
    }

    /// Batched metadata fetch for a set of already-loaded memory rows.
    private static func attachMetadata(rows: [Row], in db: Database, compact: Bool = false) throws -> [Memory] {
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
        let supersededRows = try Row.fetchAll(
            db,
            sql: """
                SELECT superseded_id, superseding_id FROM memory_supersessions
                WHERE superseded_id IN (\(placeholders))
                """,
            arguments: StatementArguments(ids)
        )
        var supersededByID: [String: [UUID]] = [:]
        for row in supersededRows {
            guard let supersededStr: String = row["superseded_id"],
                  let supersedingStr: String = row["superseding_id"],
                  let supersedingUUID = UUID(uuidString: supersedingStr) else { continue }
            supersededByID[supersededStr, default: []].append(supersedingUUID)
        }
        let supersedesRows = try Row.fetchAll(
            db,
            sql: """
                SELECT superseded_id, superseding_id FROM memory_supersessions
                WHERE superseding_id IN (\(placeholders))
                """,
            arguments: StatementArguments(ids)
        )
        var supersedesByID: [String: [UUID]] = [:]
        for row in supersedesRows {
            guard let supersededStr: String = row["superseded_id"],
                  let supersedingStr: String = row["superseding_id"],
                  let supersededUUID = UUID(uuidString: supersededStr) else { continue }
            supersedesByID[supersedingStr, default: []].append(supersededUUID)
        }
        return try rows.compactMap { (row: Row) -> Memory? in
            guard let id: String = row["id"] else { return nil }
            if compact {
                return try Memory(
                    compactRow: row,
                    tags: tagsByID[id] ?? [],
                    supersededBy: supersededByID[id],
                    supersedes: supersedesByID[id]
                )
            }
            return try Memory(
                row: row,
                tags: tagsByID[id] ?? [],
                supersededBy: supersededByID[id],
                supersedes: supersedesByID[id]
            )
        }
    }

    /// Replaces the set of memories that `supersedingID` supersedes: clears the
    /// existing edges for this superseding memory, then re-inserts the provided
    /// set. Self-links are skipped. Used by `update` so a correction can
    /// re-point its history trail.
    private static func replaceSupersessions(supersedingID: String, supersededIDs: [UUID], at date: Date, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM memory_supersessions WHERE superseding_id = ?",
            arguments: [supersedingID]
        )
        let timestamp = DateFormat.iso8601.string(from: date)
        for supersededID in supersededIDs where supersededID.uuidString != supersedingID {
            try db.execute(
                sql: "INSERT OR REPLACE INTO memory_supersessions (superseded_id, superseding_id, created_at) VALUES (?, ?, ?)",
                arguments: [supersededID.uuidString, supersedingID, timestamp]
            )
        }
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

    private static func generateHeadline(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let periodIndex = trimmed.firstIndex(of: ".") {
            let sentence = String(trimmed[..<periodIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty && sentence.count <= 120 {
                return sentence + "."
            }
        }
        return String(trimmed.prefix(120))
    }
}

// MARK: - Row decoding

extension Memory {
    init(row: Row, tags: [String], supersededBy: [UUID]? = nil, supersedes: [UUID]? = nil) throws {
        guard
            let idString: String = row["id"],
            let id = UUID(uuidString: idString),
            let typeString: String = row["type"],
            let type = MemoryType(rawValue: typeString),
            let contentData: Data = row["content"],
            let content = String(data: contentData, encoding: .utf8),
            let folderIDString: String = row["folder_id"],
            let folderID = UUID(uuidString: folderIDString),
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
            headline: row["headline"],
            content: content,
            tags: tags,
            folderID: folderID,
            sessionID: row["session_id"],
            source: row["source"],
            supersededBy: supersededBy,
            supersedes: supersedes,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Decodes a compact-index row — a projection that deliberately omits the
    /// `content` BLOB (search/recent). Content is left empty; callers load
    /// bodies on demand via `MemoryStore.get(ids:)`.
    init(compactRow row: Row, tags: [String], supersededBy: [UUID]? = nil, supersedes: [UUID]? = nil) throws {
        guard
            let idString: String = row["id"],
            let id = UUID(uuidString: idString),
            let typeString: String = row["type"],
            let type = MemoryType(rawValue: typeString),
            let folderIDString: String = row["folder_id"],
            let folderID = UUID(uuidString: folderIDString),
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
            headline: row["headline"],
            content: "",
            tags: tags,
            folderID: folderID,
            sessionID: row["session_id"],
            source: row["source"],
            supersededBy: supersededBy,
            supersedes: supersedes,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum MemoryStoreError: Error {
    case decodingFailed
    case notFound
    /// A supersession edge pointed a memory at itself.
    case invalidSupersession
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

// MARK: - Folders & Agents Extensions

public enum FolderError: Error {
    case inboxImmutable
    case invalidName
}

extension Folder {
    init(row: Row) throws {
        guard
            let idString: String = row["id"],
            let id = UUID(uuidString: idString),
            let name: String = row["name"],
            let kindStr: String = row["kind"],
            let kind = Folder.Kind(rawValue: kindStr),
            let sensitiveInt: Int = row["sensitive"],
            let createdAtString: String = row["created_at"],
            let createdAt = DateFormat.iso8601.date(from: createdAtString),
            let updatedAtString: String = row["updated_at"],
            let updatedAt = DateFormat.iso8601.date(from: updatedAtString)
        else {
            throw MemoryStoreError.decodingFailed
        }
        self.init(
            id: id,
            name: name,
            kind: kind,
            projectRoot: row["project_root"],
            isSensitive: sensitiveInt == 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension MemoryStore {
    // MARK: - Folders
    
    public func createFolder(name: String, kind: Folder.Kind, projectRoot: String?, isSensitive: Bool) async throws -> Folder {
        try await database.write { db in
            let folder = Folder(name: name, kind: kind, projectRoot: projectRoot, isSensitive: isSensitive)
            let nowStr = DateFormat.iso8601.string(from: folder.createdAt)
            try db.execute(
                sql: """
                    INSERT INTO folders (id, name, kind, project_root, sensitive, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [folder.id.uuidString, folder.name, folder.kind.rawValue, folder.projectRoot, folder.isSensitive ? 1 : 0, nowStr, nowStr]
            )
            return folder
        }
    }
    
    public func updateFolder(id: UUID, name: String, isSensitive: Bool) async throws -> Folder {
        guard id.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw FolderError.inboxImmutable
        }
        return try await database.write { db in
            let now = Date()
            let nowStr = DateFormat.iso8601.string(from: now)
            // A change to who can read a folder is exactly the kind of event the
            // audit log exists for — the per-memory methods this replaced logged
            // access_grant/access_revoke, and dropping that would leave
            // permission changes invisible.
            let wasSensitive = try Bool.fetchOne(
                db, sql: "SELECT sensitive FROM folders WHERE id = ?", arguments: [id.uuidString]
            ) ?? false
            try db.execute(
                sql: "UPDATE folders SET name = ?, sensitive = ?, updated_at = ? WHERE id = ?",
                arguments: [name, isSensitive ? 1 : 0, nowStr, id.uuidString]
            )
            if wasSensitive != isSensitive {
                try ActivityStore.add(Activity(
                    actorKind: .cli,
                    actorID: "user",
                    operation: isSensitive ? "folder_restrict" : "folder_open",
                    query: name
                ), in: db)
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM folders WHERE id = ?", arguments: [id.uuidString]) else {
                throw MemoryStoreError.notFound
            }
            return try Folder(row: row)
        }
    }
    
    public func deleteFolder(id: UUID) async throws {
        guard id.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw FolderError.inboxImmutable
        }
        try await database.write { db in
            let name = try String.fetchOne(
                db, sql: "SELECT name FROM folders WHERE id = ?", arguments: [id.uuidString]
            ) ?? ""
            try db.execute(
                sql: "UPDATE memories SET folder_id = ? WHERE folder_id = ?",
                arguments: [Self.inboxFolderIDString, id.uuidString]
            )
            let moved = db.changesCount
            try db.execute(
                sql: "DELETE FROM folders WHERE id = ?",
                arguments: [id.uuidString]
            )
            try ActivityStore.add(Activity(
                actorKind: .cli,
                actorID: "user",
                operation: "folder_delete",
                query: name,
                resultCount: moved
            ), in: db)
        }
    }
    
    public func listFolders() async throws -> [Folder] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY name ASC")
            return try rows.compactMap { try Folder(row: $0) }
        }
    }
    
    /// Merge `ids` into a folder named `intoName`, creating it if absent.
    ///
    /// The destination is excluded from the set being deleted. Naming the
    /// destination after one of the sources — the obvious thing to do — would
    /// otherwise delete the folder the memories were just moved into, dumping
    /// them in Inbox and dropping the destination's sensitivity with it.
    ///
    /// **The destination's sensitivity wins.** Visibility is a property of the
    /// folder, so memories arriving in it take its rule — exactly as when a
    /// single memory is moved. Merging never rewrites the destination's own
    /// setting, which would silently change visibility for memories already
    /// filed there that the user never touched. Callers are responsible for
    /// stating the outcome before committing.
    ///
    /// The one exception is a destination that does not exist yet: it has no
    /// rule to respect, so it inherits sensitivity from the sources rather than
    /// defaulting open and widening access unannounced.
    public func mergeFolders(ids: [UUID], intoName: String) async throws -> Folder {
        let name = intoName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.invalidName }

        let requested = ids.map { $0.uuidString }.filter { $0 != Self.inboxFolderIDString }
        guard !requested.isEmpty else { throw FolderError.inboxImmutable }

        return try await database.write { db in
            let nowStr = DateFormat.iso8601.string(from: Date())

            // Only used when the destination has to be created — an existing
            // folder keeps its own rule.
            let placeholdersAll = requested.map { _ in "?" }.joined(separator: ",")
            let anySensitive = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM folders WHERE sensitive = 1 AND id IN (\(placeholdersAll))",
                arguments: StatementArguments(requested)
            ) ?? 0) > 0

            let dest: Folder
            if let row = try Row.fetchOne(
                db, sql: "SELECT * FROM folders WHERE name = ? LIMIT 1", arguments: [name]
            ) {
                // Destination rule: keep its sensitivity untouched.
                dest = try Folder(row: row)
            } else {
                let created = Folder(name: name, kind: .manual, isSensitive: anySensitive)
                try db.execute(
                    sql: """
                        INSERT INTO folders (id, name, kind, project_root, sensitive, created_at, updated_at)
                        VALUES (?, ?, ?, NULL, ?, ?, ?)
                        """,
                    arguments: [created.id.uuidString, created.name, created.kind.rawValue,
                                created.isSensitive ? 1 : 0, nowStr, nowStr]
                )
                dest = created
            }

            // Never delete the destination, even when it was named as a source.
            let sources = requested.filter { $0 != dest.id.uuidString }
            guard !sources.isEmpty else { return dest }

            let placeholders = sources.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "UPDATE memories SET folder_id = ? WHERE folder_id IN (\(placeholders))",
                arguments: StatementArguments([dest.id.uuidString] + sources)
            )
            try db.execute(
                sql: "DELETE FROM folders WHERE id IN (\(placeholders))",
                arguments: StatementArguments(sources)
            )

            try ActivityStore.add(Activity(
                actorKind: .cli,
                actorID: "user",
                operation: "folder_merge",
                query: dest.name,
                resultCount: sources.count
            ), in: db)

            return dest
        }
    }

    /// Moves memories into `folderID`, returning how many actually moved.
    ///
    /// Moving is how a memory is reclassified — visibility lives on the folder —
    /// so this records an activity row when the move crosses a sensitivity
    /// boundary. An organising gesture that quietly changes who can read a
    /// memory should still be visible in the audit log.
    @discardableResult
    public func moveMemories(ids: [UUID], toFolder folderID: UUID) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try await database.write { db in
            guard let destSensitive = try Bool.fetchOne(
                db, sql: "SELECT sensitive FROM folders WHERE id = ?", arguments: [folderID.uuidString]
            ) else { throw MemoryStoreError.notFound }

            let idStrings = ids.map { $0.uuidString }
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")

            let crossing = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM memories m
                    JOIN folders f ON f.id = m.folder_id
                    WHERE m.id IN (\(placeholders)) AND f.sensitive != ?
                    """,
                arguments: StatementArguments(idStrings) + [destSensitive ? 1 : 0]
            ) ?? 0

            try db.execute(
                sql: "UPDATE memories SET folder_id = ?, updated_at = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([folderID.uuidString, DateFormat.iso8601.string(from: Date())])
                    + StatementArguments(idStrings)
            )
            let moved = db.changesCount

            if crossing > 0 {
                try ActivityStore.add(Activity(
                    actorKind: .cli,
                    actorID: "user",
                    operation: destSensitive ? "memory_restrict" : "memory_open",
                    resultCount: crossing
                ), in: db)
            }
            return moved
        }
    }

    public func getFolderCounts() async throws -> [UUID: Int] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT folder_id, COUNT(*) as c FROM memories GROUP BY folder_id")
            var counts: [UUID: Int] = [:]
            for row in rows {
                if let idStr = row["folder_id"] as String?, let id = UUID(uuidString: idStr), let count = row["c"] as Int? {
                    counts[id] = count
                }
            }
            return counts
        }
    }
    
    public func resolveProjectFolder(gitRoot: String) async throws -> Folder {
        return try await database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM folders WHERE project_root = ?", arguments: [gitRoot]) {
                return try Folder(row: row)
            }
            
            let folderName = (gitRoot as NSString).lastPathComponent.isEmpty ? "Project Folder" : (gitRoot as NSString).lastPathComponent
            
            var finalName = folderName
            var counter = 1
            while try Row.fetchOne(db, sql: "SELECT 1 FROM folders WHERE name = ?", arguments: [finalName]) != nil {
                counter += 1
                finalName = "\(folderName) (\(counter))"
            }
            
            let folder = Folder(name: finalName, kind: .project, projectRoot: gitRoot)
            let nowStr = DateFormat.iso8601.string(from: folder.createdAt)
            try db.execute(
                sql: """
                    INSERT INTO folders (id, name, kind, project_root, sensitive, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [folder.id.uuidString, folder.name, folder.kind.rawValue, folder.projectRoot, nowStr, nowStr]
            )
            return folder
        }
    }
    
    // MARK: - Agents
    
    public func getAgentStatus(id: String) async throws -> Agent.Status {
        try await database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT status FROM agents WHERE id = ?", arguments: [id]) {
                let statusStr: String = row["status"]
                return Agent.Status(rawValue: statusStr) ?? .all
            }
            let now = Date()
            let nowStr = DateFormat.iso8601.string(from: now)
            try db.execute(
                sql: "INSERT INTO agents (id, status, created_at, updated_at) VALUES (?, 'all', ?, ?)",
                arguments: [id, nowStr, nowStr]
            )
            return .all
        }
    }
    
    public func setAgentStatus(id: String, status: Agent.Status) async throws {
        try await database.write { db in
            let now = Date()
            let nowStr = DateFormat.iso8601.string(from: now)
            let previous = try String.fetchOne(
                db, sql: "SELECT status FROM agents WHERE id = ?", arguments: [id]
            ) ?? Agent.Status.all.rawValue
            try db.execute(
                sql: "INSERT INTO agents (id, status, created_at, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET status = ?, updated_at = ?",
                arguments: [id, status.rawValue, nowStr, nowStr, status.rawValue, nowStr]
            )
            // Narrowing or widening an agent's reach is an access change and
            // belongs in the audit log next to the folder events.
            if previous != status.rawValue {
                try ActivityStore.add(Activity(
                    actorKind: .cli,
                    actorID: "user",
                    operation: status == .nonSensitiveOnly ? "agent_restrict" : "agent_unrestrict",
                    query: id
                ), in: db)
            }
        }
    }
    
    public func listAgents() async throws -> [Agent] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM agents ORDER BY id ASC")
            return rows.compactMap { row in
                guard
                    let id: String = row["id"],
                    let statusStr: String = row["status"],
                    let status = Agent.Status(rawValue: statusStr),
                    let createdAtString: String = row["created_at"],
                    let createdAt = DateFormat.iso8601.date(from: createdAtString),
                    let updatedAtString: String = row["updated_at"],
                    let updatedAt = DateFormat.iso8601.date(from: updatedAtString)
                else {
                    return nil
                }
                return Agent(id: id, status: status, createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }
}
