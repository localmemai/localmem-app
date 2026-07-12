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

    @Test("a fresh database applies exactly the consolidated v1_initial")
    func freshDatabaseAppliesConsolidatedV1() async throws {
        let db = try LocalmemDatabase(url: tempURL())
        let applied = try await db.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied == ["v1_initial"])
    }

    @Test("v1_initial creates the full launch schema")
    func v1CreatesFullSchema() async throws {
        let db = try LocalmemDatabase(url: tempURL())

        let tables = try await db.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"))
        }
        for expected in [
            "memories", "memory_tags", "memory_agent_exclusions", "memories_fts",
            "activity", "activity_memory",
            "sources", "source_files", "source_memories",
        ] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }

        // The slim sources shape — the legacy kind/auto_process/status columns
        // from the pre-launch iterations must not exist.
        let sourceColumns = try await db.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(sources)").map { $0["name"] as String })
        }
        #expect(sourceColumns == [
            "id", "name", "connector", "path", "bookmark", "backend",
            "last_run_at", "created_at", "updated_at",
        ])

        let indexes = try await db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'"))
        }
        #expect(indexes == [
            "idx_excl_agent", "idx_memories_created_at",
            "idx_activity_occurred_at", "idx_activity_actor",
            "idx_activity_memory_memory", "idx_source_memories_file",
        ])

        let triggers = try await db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        }
        #expect(triggers == [
            "memories_after_insert", "memories_after_update", "memories_after_delete",
            "activity_cap_after_insert",
        ])
    }

    @Test("the launch schema round-trips a memory and a source end to end")
    func schemaSupportsCoreWrites() async throws {
        let db = try LocalmemDatabase(url: tempURL())
        let memoryStore = MemoryStore(database: db)
        let sourceStore = SourceStore(database: db)

        let memory = try await memoryStore.add(
            content: "Launch schema works.", type: .note, tags: ["launch"],
            actorKind: .cli, actorID: "test")
        #expect(try await memoryStore.search(query: "launch").map(\.id) == [memory.id])

        let source = ImportSource(name: "notes.md", path: "/tmp/notes.md", backend: .apple)
        try await sourceStore.add(source)
        #expect(try await sourceStore.get(id: source.id)?.name == "notes.md")
    }
}
