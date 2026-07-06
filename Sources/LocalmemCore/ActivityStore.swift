import Foundation
import GRDB

public actor ActivityStore {
    private let database: LocalmemDatabase

    public init() throws {
        self.database = try LocalmemDatabase()
    }

    public init(database: LocalmemDatabase) {
        self.database = database
    }

    /// Standalone audit insert. Throws on failure — callers decide whether
    /// to log and swallow (the typical case, audit failure should never
    /// break a user-facing op) or propagate. For inserts that need to be
    /// part of a caller's existing transaction (so the memory write rolls
    /// back together with the audit row), use the static `add(_:in:)`.
    public func add(_ activity: Activity) async throws {
        try await database.write { db in
            try Self.add(activity, in: db)
        }
    }

    /// Insert an activity along with the set of memories it touched. Used by
    /// reads (search/recent), which return many memories under one activity row;
    /// the links let per-memory audit filtering attribute those reads. Written in
    /// one transaction so the row and its links can't diverge.
    public func add(_ activity: Activity, memoryIDs: [UUID]) async throws {
        try await database.write { db in
            try Self.add(activity, in: db)
            for memoryID in Set(memoryIDs) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO activity_memory (activity_id, memory_id) VALUES (?, ?)",
                    arguments: [activity.id.uuidString, memoryID.uuidString]
                )
            }
        }
    }

    public func recent(limit: Int = 100) async throws -> [Activity] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM activity ORDER BY occurred_at DESC, rowid DESC LIMIT ?",
                arguments: [max(1, limit)]
            )
            return try rows.map(Self.decode(row:))
        }
    }

    /// The memories each of the given activities touched, via `activity_memory`.
    /// Only activities that recorded links (reads) appear in the result.
    public func memoryLinks(activityIDs: [UUID]) async throws -> [UUID: Set<UUID>] {
        guard !activityIDs.isEmpty else { return [:] }
        return try await database.read { db in
            let placeholders = databaseQuestionMarks(count: activityIDs.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT activity_id, memory_id FROM activity_memory WHERE activity_id IN (\(placeholders))",
                arguments: StatementArguments(activityIDs.map(\.uuidString))
            )
            var links: [UUID: Set<UUID>] = [:]
            for row in rows {
                guard let aid: String = row["activity_id"], let activityID = UUID(uuidString: aid),
                      let mid: String = row["memory_id"], let memoryID = UUID(uuidString: mid)
                else { continue }
                links[activityID, default: []].insert(memoryID)
            }
            return links
        }
    }

    static func add(_ activity: Activity, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO activity (
                    id, occurred_at, actor_kind, actor_id, operation,
                    memory_id, query, result_count
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                activity.id.uuidString,
                DateFormat.iso8601.string(from: activity.occurredAt),
                activity.actorKind.rawValue,
                activity.actorID,
                activity.operation,
                activity.memoryID?.uuidString,
                activity.query,
                activity.resultCount,
            ]
        )
    }

    private static func decode(row: Row) throws -> Activity {
        guard
            let idString: String = row["id"],
            let id = UUID(uuidString: idString),
            let occurredAtString: String = row["occurred_at"],
            let occurredAt = DateFormat.iso8601.date(from: occurredAtString),
            let actorKindString: String = row["actor_kind"],
            let actorKind = ActorKind(rawValue: actorKindString),
            let operation: String = row["operation"]
        else {
            throw ActivityStoreError.decodingFailed
        }
        let memoryIDString: String? = row["memory_id"]
        return Activity(
            id: id,
            occurredAt: occurredAt,
            actorKind: actorKind,
            actorID: row["actor_id"],
            operation: operation,
            memoryID: memoryIDString.flatMap(UUID.init(uuidString:)),
            query: row["query"],
            resultCount: row["result_count"]
        )
    }
}

public enum ActivityStoreError: Error {
    case decodingFailed
}
