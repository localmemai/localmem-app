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

        // Which memories a single activity touched. A read (search/recent) returns
        // many memories but records one activity row with no single `memory_id`,
        // so per-memory audit filtering can't attribute reads without this join.
        // ON DELETE CASCADE keeps it pruned when the activity-cap trigger deletes
        // old rows.
        //
        // This is a *separate* migration, not an edit to v1_initial: databases in
        // the field already applied v1, so a v1 edit would never reach them. Uses
        // IF NOT EXISTS so it's a no-op on any dev DB that got the table from an
        // earlier in-place attempt.
        migrator.registerMigration("v2_activity_memory") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS activity_memory (
                    activity_id TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
                    memory_id TEXT NOT NULL,
                    PRIMARY KEY (activity_id, memory_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_activity_memory_memory ON activity_memory(memory_id)")
        }

        // File connector: sources the user imports from, per-file processing
        // state (for change detection), and which memories came from which file
        // (for replace-all reconciliation). See docs/File_Connector_Design.md.
        migrator.registerMigration("v3_sources") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sources (
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
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS source_files (
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    rel_path TEXT NOT NULL,
                    content_sha256 TEXT,
                    modified_at TEXT,
                    processed_at TEXT,
                    status TEXT NOT NULL,
                    reason_code TEXT,
                    error TEXT,
                    PRIMARY KEY (source_id, rel_path)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS source_memories (
                    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    rel_path TEXT NOT NULL,
                    PRIMARY KEY (memory_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_source_memories_file ON source_memories(source_id, rel_path)")
        }

        return migrator
    }
}
