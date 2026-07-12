import Foundation
import Testing
import GRDB
@testable import LocalmemCore

@Suite("Migrations")
struct MigrationsTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lm-mig-\(UUID().uuidString).sqlite3")
    }

    /// Reproduces the schema-drift bug: a database that ran the ORIGINAL
    /// `v3_sources` (with kind/auto_process/status NOT NULL) must be repaired by
    /// `v4` so the current `add()` — which no longer supplies those columns —
    /// can insert again. Without v4 the INSERT fails the NOT NULL constraint on
    /// `kind` and imports silently do nothing.
    @Test("v4 drops legacy sources columns so imports can insert again")
    func v4RepairsDriftedSources() async throws {
        let url = tempURL()

        // Seed a drifted database: the old sources shape, with v1..v3 recorded as
        // applied so the migrator runs only v4.
        var seed: DatabaseQueue? = try DatabaseQueue(path: url.path)
        try await seed!.write { db in
            try db.execute(sql: """
                CREATE TABLE sources (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    connector TEXT NOT NULL DEFAULT 'files',
                    kind TEXT NOT NULL,
                    path TEXT NOT NULL,
                    bookmark BLOB,
                    backend TEXT NOT NULL,
                    auto_process INTEGER NOT NULL DEFAULT 1,
                    status TEXT NOT NULL DEFAULT 'active',
                    last_run_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for id in ["v1_initial", "v2_activity_memory", "v3_sources"] {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [id])
            }
        }
        seed = nil   // release the connection before reopening the file

        // Opening through LocalmemDatabase runs the migrator, applying v4.
        let db = try LocalmemDatabase(url: url)

        let columns = try await db.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(sources)").map { $0["name"] as String })
        }
        #expect(columns.isDisjoint(with: ["kind", "auto_process", "status"]))

        // The insert that previously failed on the NOT NULL `kind` now succeeds.
        let store = SourceStore(database: db)
        let source = ImportSource(name: "notes.md", path: "/tmp/notes.md", backend: .apple)
        try await store.add(source)
        #expect(try await store.get(id: source.id)?.name == "notes.md")
        #expect(try await store.list().count == 1)
    }
}
