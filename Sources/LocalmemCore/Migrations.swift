import GRDB

enum Migrations {
    // ─────────────────────────────────────────────────────────────────────────
    // MIGRATION DISCIPLINE — read before touching this file.
    //
    // `v1_initial` below is the complete launch schema, consolidated from the
    // pre-release migrations (v1–v4) just before first ship, while every
    // existing database was still a wipeable dev DB. That was the LAST in-place
    // schema edit ever.
    //
    // From the first shipped build onward, databases in the field have applied
    // `v1_initial` and will never re-run it. Any schema change — new table, new
    // column, new index, new trigger — MUST be a new `registerMigration` with a
    // new identifier (v2_..., v3_...), appended after v1. Never edit or remove
    // an already-shipped migration.
    // ─────────────────────────────────────────────────────────────────────────
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

            // Tags are indexed alongside title/content: they're the semantic
            // bridge for a lexical search — "coffee" must surface a memory
            // whose content only says "flat white". Kept in sync by the
            // memory_tags triggers below, since tags live in their own table.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memories_fts USING fts5(
                    memory_id UNINDEXED,
                    title,
                    content_plaintext,
                    tags,
                    tokenize = 'unicode61'
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER memories_after_insert AFTER INSERT ON memories BEGIN
                    INSERT INTO memories_fts(memory_id, title, content_plaintext, tags)
                    VALUES (NEW.id, COALESCE(NEW.title, ''), CAST(NEW.content AS TEXT), '');
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

            // Keep the FTS tags column in sync with the memory_tags table.
            // Fires for every write path — add, update (delete-all + reinsert),
            // and FK-cascade deletes — so application code never maintains the
            // index by hand. The UPDATE is a no-op when the FTS row is already
            // gone (memory delete cascades reach here after memories_after_delete).
            try db.execute(sql: """
                CREATE TRIGGER memory_tags_after_insert AFTER INSERT ON memory_tags BEGIN
                    UPDATE memories_fts
                    SET tags = COALESCE(
                        (SELECT group_concat(tag, ' ') FROM memory_tags WHERE memory_id = NEW.memory_id), '')
                    WHERE memory_id = NEW.memory_id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER memory_tags_after_delete AFTER DELETE ON memory_tags BEGIN
                    UPDATE memories_fts
                    SET tags = COALESCE(
                        (SELECT group_concat(tag, ' ') FROM memory_tags WHERE memory_id = OLD.memory_id), '')
                    WHERE memory_id = OLD.memory_id;
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

            // Which memories a single activity touched. A read (search/recent)
            // returns many memories but records one activity row with no single
            // `memory_id`, so per-memory audit filtering can't attribute reads
            // without this join. ON DELETE CASCADE keeps it pruned when the
            // activity-cap trigger deletes old rows.
            try db.execute(sql: """
                CREATE TABLE activity_memory (
                    activity_id TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
                    memory_id TEXT NOT NULL,
                    PRIMARY KEY (activity_id, memory_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_activity_memory_memory ON activity_memory(memory_id)")

            // File connector: files the user imported from (one source per file),
            // per-file processing state (for change detection), and which memories
            // came from which file (for replace-all reconciliation).
            // See docs/Technical_Design.md §10 (File connector).
            try db.execute(sql: """
                CREATE TABLE sources (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    connector TEXT NOT NULL DEFAULT 'files',
                    path TEXT NOT NULL,
                    bookmark BLOB,
                    backend TEXT NOT NULL,
                    last_run_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE source_files (
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
                CREATE TABLE source_memories (
                    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                    source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    rel_path TEXT NOT NULL,
                    PRIMARY KEY (memory_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_source_memories_file ON source_memories(source_id, rel_path)")
        }

        // Two-pass extract → verify (docs/Extraction_Quality_Design.md): the
        // "N extracted → M kept" transparency counts. Nullable — rows processed
        // before the verify pass shipped simply have no counts.
        migrator.registerMigration("v2_extraction_counts") { db in
            try db.execute(sql: "ALTER TABLE source_files ADD COLUMN extracted_count INTEGER")
            try db.execute(sql: "ALTER TABLE source_files ADD COLUMN kept_count INTEGER")
        }

        return migrator
    }
}
