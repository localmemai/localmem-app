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
