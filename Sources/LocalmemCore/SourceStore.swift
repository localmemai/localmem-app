import Foundation
import GRDB

/// Persistence for connected sources, per-file processing state, and the
/// file→memory links that make replace-all reconciliation possible. Shares the
/// same database as `MemoryStore`.
public final class SourceStore: Sendable {
    private let database: LocalmemDatabase

    public init() throws {
        self.database = try LocalmemDatabase()
    }

    public init(database: LocalmemDatabase) {
        self.database = database
    }

    // MARK: - Sources

    public func add(_ source: ImportSource) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sources
                    (id, name, connector, path, bookmark, backend, last_run_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    source.id.uuidString, source.name, source.connector,
                    source.path, source.bookmark, source.backend.storageValue,
                    source.lastRunAt.map(DateFormat.iso8601.string(from:)),
                    DateFormat.iso8601.string(from: source.createdAt),
                    DateFormat.iso8601.string(from: source.updatedAt),
                ]
            )
        }
    }

    public func list() async throws -> [ImportSource] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY created_at DESC")
                .compactMap(Self.source(from:))
        }
    }

    public func get(id: UUID) async throws -> ImportSource? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id = ?", arguments: [id.uuidString])
                .flatMap(Self.source(from:))
        }
    }

    /// Replaces the mutable fields of an existing source (bumps updated_at).
    public func update(_ source: ImportSource) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE sources SET name = ?, backend = ?, last_run_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    source.name, source.backend.storageValue,
                    source.lastRunAt.map(DateFormat.iso8601.string(from:)),
                    DateFormat.iso8601.string(from: Date()), source.id.uuidString,
                ]
            )
        }
    }

    public func delete(id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - File state

    public func fileHash(sourceID: UUID, relPath: String) async throws -> String? {
        try await database.read { db in
            try String.fetchOne(db,
                sql: "SELECT content_sha256 FROM source_files WHERE source_id = ? AND rel_path = ?",
                arguments: [sourceID.uuidString, relPath])
        }
    }

    public func upsertFileState(sourceID: UUID, _ state: SourceFileState) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO source_files
                    (source_id, rel_path, content_sha256, modified_at, processed_at, status, reason_code, error, extracted_count, kept_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    sourceID.uuidString, state.relPath, state.contentSHA256,
                    state.modifiedAt.map(DateFormat.iso8601.string(from:)),
                    state.processedAt.map(DateFormat.iso8601.string(from:)),
                    state.status.rawValue, state.reasonCode, state.error,
                    state.extractedCount, state.keptCount,
                ]
            )
        }
    }

    public func listFileStates(sourceID: UUID) async throws -> [SourceFileState] {
        try await database.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT * FROM source_files WHERE source_id = ? ORDER BY rel_path",
                arguments: [sourceID.uuidString])
            return try rows.map { row in
                let rel: String = row["rel_path"]
                let facts = try Int.fetchOne(db,
                    sql: "SELECT COUNT(*) FROM source_memories WHERE source_id = ? AND rel_path = ?",
                    arguments: [sourceID.uuidString, rel]) ?? 0
                return SourceFileState(
                    relPath: rel,
                    contentSHA256: row["content_sha256"],
                    modifiedAt: (row["modified_at"] as String?).flatMap(DateFormat.iso8601.date(from:)),
                    processedAt: (row["processed_at"] as String?).flatMap(DateFormat.iso8601.date(from:)),
                    status: SourceFileState.Status(rawValue: row["status"]) ?? .failed,
                    reasonCode: row["reason_code"],
                    error: row["error"],
                    factCount: facts,
                    extractedCount: row["extracted_count"],
                    keptCount: row["kept_count"]
                )
            }
        }
    }

    // MARK: - Memory links + reconciliation

    public func memoryIDs(sourceID: UUID, relPath: String) async throws -> [UUID] {
        try await database.read { db in
            try String.fetchAll(db,
                sql: "SELECT memory_id FROM source_memories WHERE source_id = ? AND rel_path = ?",
                arguments: [sourceID.uuidString, relPath])
                .compactMap(UUID.init(uuidString:))
        }
    }

    public func link(memoryID: UUID, sourceID: UUID, relPath: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO source_memories (memory_id, source_id, rel_path) VALUES (?, ?, ?)",
                arguments: [memoryID.uuidString, sourceID.uuidString, relPath])
        }
    }

    /// Delete memories (cascades tags/exclusions/source_memories via FK).
    /// Writes one `memory_delete` activity row per memory in the same
    /// transaction, so connector deletions show up in the audit log exactly
    /// like `MemoryStore.delete` ones.
    public func deleteMemories(ids: [UUID], actorKind: ActorKind, actorID: String? = nil) async throws {
        guard !ids.isEmpty else { return }
        try await database.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id.uuidString])
                guard db.changesCount > 0 else { continue }
                try ActivityStore.add(Activity(
                    actorKind: actorKind,
                    actorID: actorID,
                    operation: "memory_delete",
                    memoryID: id
                ), in: db)
            }
        }
    }

    /// Replace-all reconciliation for one file, in a single transaction:
    /// deletes the file's previous memories, inserts the freshly extracted
    /// set, links each new memory back to the file, and writes the audit rows.
    /// Atomic — a crash or error can never land between the delete and the
    /// insert, so the store always holds either the file's old set or its new
    /// set, never neither. Returns the number of memories actually inserted.
    @discardableResult
    public func replaceMemories(
        sourceID: UUID,
        relPath: String,
        with memories: [Memory],
        actorKind: ActorKind,
        actorID: String? = nil
    ) async throws -> Int {
        try await database.write { db in
            // Drop this file's old memories (cascades tags/exclusions/links).
            let old = try String.fetchAll(
                db,
                sql: "SELECT memory_id FROM source_memories WHERE source_id = ? AND rel_path = ?",
                arguments: [sourceID.uuidString, relPath]
            )
            for id in old {
                try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
                guard db.changesCount > 0 else { continue }
                try ActivityStore.add(Activity(
                    actorKind: actorKind,
                    actorID: actorID,
                    operation: "memory_delete",
                    memoryID: UUID(uuidString: id)
                ), in: db)
            }

            // Insert the new set and link each memory back to the file.
            var imported = 0
            for memory in memories {
                guard try MemoryStore.insertPreservingIdentity(memory, in: db) else { continue }
                imported += 1
                try db.execute(
                    sql: "INSERT OR REPLACE INTO source_memories (memory_id, source_id, rel_path) VALUES (?, ?, ?)",
                    arguments: [memory.id.uuidString, sourceID.uuidString, relPath]
                )
            }
            if imported > 0 {
                try ActivityStore.add(Activity(
                    actorKind: actorKind,
                    actorID: actorID,
                    operation: "memory_import",
                    resultCount: imported
                ), in: db)
            }
            return imported
        }
    }

    /// All memory ids produced by a source (for Remove → delete option).
    public func allMemoryIDs(sourceID: UUID) async throws -> [UUID] {
        try await database.read { db in
            try String.fetchAll(db,
                sql: "SELECT memory_id FROM source_memories WHERE source_id = ?",
                arguments: [sourceID.uuidString])
                .compactMap(UUID.init(uuidString:))
        }
    }

    // MARK: - Row mapping

    private static func source(from row: Row) -> ImportSource? {
        guard let id = UUID(uuidString: row["id"]),
              let backend = ExtractionBackend(storageValue: row["backend"]),
              let created = DateFormat.iso8601.date(from: row["created_at"]),
              let updated = DateFormat.iso8601.date(from: row["updated_at"])
        else { return nil }
        return ImportSource(
            id: id,
            name: row["name"],
            connector: row["connector"],
            path: row["path"],
            bookmark: row["bookmark"],
            backend: backend,
            lastRunAt: (row["last_run_at"] as String?).flatMap(DateFormat.iso8601.date(from:)),
            createdAt: created,
            updatedAt: updated
        )
    }
}
