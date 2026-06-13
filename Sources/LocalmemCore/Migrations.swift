import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            // memories + tags + FTS

            try db.execute(sql: """
                CREATE TABLE memories (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    title TEXT,
                    content BLOB NOT NULL,
                    source TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE memory_tags (
                    memory_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (memory_id, tag),
                    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE
                )
                """)

            // Per-memory agent access (denylist). Empty set = visible to every
            // agent, including ones added later. We persist only the exclusions.
            try db.execute(sql: """
                CREATE TABLE memory_agent_exclusions (
                    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                    agent_id TEXT NOT NULL,
                    PRIMARY KEY (memory_id, agent_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_excl_agent ON memory_agent_exclusions(agent_id)")

            try db.execute(sql: "CREATE INDEX idx_memories_created_at ON memories(created_at DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE memories_fts USING fts5(
                    memory_id UNINDEXED,
                    title,
                    content_plaintext,
                    tokenize = 'unicode61'
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER memories_after_insert AFTER INSERT ON memories BEGIN
                    INSERT INTO memories_fts(memory_id, title, content_plaintext)
                    VALUES (NEW.id, COALESCE(NEW.title, ''), CAST(NEW.content AS TEXT));
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER memories_after_update AFTER UPDATE ON memories BEGIN
                    UPDATE memories_fts
                    SET title = COALESCE(NEW.title, ''),
                        content_plaintext = CAST(NEW.content AS TEXT)
                    WHERE memory_id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER memories_after_delete AFTER DELETE ON memories BEGIN
                    DELETE FROM memories_fts WHERE memory_id = OLD.id;
                END
                """)

            // activity log

            try db.execute(sql: """
                CREATE TABLE activity (
                    id TEXT PRIMARY KEY,
                    occurred_at TEXT NOT NULL,
                    actor_kind TEXT NOT NULL,
                    actor_id TEXT,
                    operation TEXT NOT NULL,
                    memory_id TEXT,
                    query TEXT,
                    result_count INTEGER
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_activity_occurred_at ON activity(occurred_at DESC)")
            try db.execute(sql: "CREATE INDEX idx_activity_actor ON activity(actor_kind, actor_id)")

            // Sample every 1000 inserts instead of COUNT(*) on every one.
            // Worst-case overshoot is ~1000 rows, acceptable for a 100k audit cap.
            try db.execute(sql: """
                CREATE TRIGGER activity_cap_after_insert AFTER INSERT ON activity
                WHEN NEW.rowid % 1000 = 0 AND (SELECT COUNT(*) FROM activity) > 100000
                BEGIN
                    DELETE FROM activity
                    WHERE rowid IN (
                        SELECT rowid FROM activity ORDER BY rowid ASC LIMIT (SELECT COUNT(*) - 100000 FROM activity)
                    );
                END
                """)
        }

        return migrator
    }
}
