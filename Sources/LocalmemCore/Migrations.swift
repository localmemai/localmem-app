import GRDB
import Foundation

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
            // See docs/Technical_Design.md section 10 (File connector).
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

        // Two-pass extract → verify (docs/Technical_Design.md section 10): the
        // "N extracted → M kept" transparency counts. Nullable — rows processed
        // before the verify pass shipped simply have no counts.
        migrator.registerMigration("v2_extraction_counts") { db in
            try db.execute(sql: "ALTER TABLE source_files ADD COLUMN extracted_count INTEGER")
            try db.execute(sql: "ALTER TABLE source_files ADD COLUMN kept_count INTEGER")
        }

        migrator.registerMigration("v3_retrieval_and_supersession") { db in
            try db.execute(sql: "ALTER TABLE memories ADD COLUMN headline TEXT")
            try db.execute(sql: """
                CREATE TABLE memory_supersessions (
                    superseded_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                    superseding_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (superseded_id, superseding_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_supersessions_superseded ON memory_supersessions(superseded_id)")
            try db.execute(sql: "CREATE INDEX idx_supersessions_superseding ON memory_supersessions(superseding_id)")

            try db.execute(sql: """
                UPDATE memories SET headline = CASE
                    WHEN INSTR(CAST(content AS TEXT), '.') > 0 AND INSTR(CAST(content AS TEXT), '.') <= 120
                    THEN SUBSTR(CAST(content AS TEXT), 1, INSTR(CAST(content AS TEXT), '.'))
                    ELSE SUBSTR(CAST(content AS TEXT), 1, 120)
                END
                """)
        }

        migrator.registerMigration("v4_folders") { db in
            // 1. Create folders table
            try db.execute(sql: """
                CREATE TABLE folders (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    project_root TEXT,
                    sensitive INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            
            // 2. Create unique index on project_root
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_folders_root ON folders(project_root) 
                WHERE project_root IS NOT NULL
                """)
            
            // 3. Create agents table
            try db.execute(sql: """
                CREATE TABLE agents (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL DEFAULT 'all',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            
            // 4. Create Inbox folder with fixed UUID
            let nowStr = DateFormat.iso8601.string(from: Date())
            try db.execute(
                sql: """
                    INSERT INTO folders (id, name, kind, project_root, sensitive, created_at, updated_at)
                    VALUES (?, ?, ?, NULL, 0, ?, ?)
                    """,
                arguments: ["00000000-0000-0000-0000-000000000000", "Inbox", "default", nowStr, nowStr]
            )
            
            // 5. Add folder_id and session_id to memories table
            try db.execute(sql: "ALTER TABLE memories ADD COLUMN folder_id TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000' REFERENCES folders(id) ON DELETE SET DEFAULT")
            try db.execute(sql: "ALTER TABLE memories ADD COLUMN session_id TEXT")
            
            // 6. Create index on memories(folder_id)
            try db.execute(sql: "CREATE INDEX idx_memories_folder ON memories(folder_id)")
            
            // 7. Group memories by source folder parent directories
            let sourceFileRows = try Row.fetchAll(db, sql: """
                SELECT sm.memory_id, s.path, sm.rel_path
                FROM source_memories sm
                JOIN sources s ON sm.source_id = s.id
                """)
            
            var folderPathsToIDs: [String: String] = [:]
            for row in sourceFileRows {
                guard let memoryID: String = row["memory_id"],
                      let basePath: String = row["path"],
                      let relPath: String = row["rel_path"] else { continue }

                // The files connector stores one source per file, so `path` is
                // already the full file path and `rel_path` repeats its last
                // component. Appending regardless would make the file look like
                // a directory and produce one folder per file — the exact
                // outcome parent-directory grouping exists to avoid. Only join
                // when `path` is genuinely a containing directory.
                let filePath = basePath.hasSuffix(relPath)
                    ? basePath
                    : (basePath as NSString).appendingPathComponent(relPath)
                let parentDir = (filePath as NSString).deletingLastPathComponent

                let folderID: String
                if let existing = folderPathsToIDs[parentDir] {
                    folderID = existing
                } else {
                    let newID = UUID().uuidString
                    let folderName = Self.folderName(forDirectory: parentDir)
                    // Stamp the directory as the folder's canonical path so a
                    // later import of a sibling file resolves to this folder
                    // even if the user has renamed it.
                    try db.execute(
                        sql: """
                            INSERT INTO folders (id, name, kind, project_root, sensitive, created_at, updated_at)
                            VALUES (?, ?, ?, ?, 0, ?, ?)
                            """,
                        arguments: [newID, folderName, "source", parentDir, nowStr, nowStr]
                    )
                    folderPathsToIDs[parentDir] = newID
                    folderID = newID
                }
                
                try db.execute(
                    sql: "UPDATE memories SET folder_id = ? WHERE id = ?",
                    arguments: [folderID, memoryID]
                )
            }
            
            // 8. Drop memory_agent_exclusions
            try db.execute(sql: "DROP TABLE memory_agent_exclusions")
        }

        // Source folders are matched by their directory path, not their display
        // name — renaming one must not split its next import into a fresh
        // folder, and two directories sharing a leaf name must not collapse.
        // Databases that already ran v4 have `project_root` NULL on their source
        // folders, so recover each folder's directory from the sources its
        // memories came from.
        migrator.registerMigration("v5_source_folder_paths") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT m.folder_id AS folder_id, s.path AS path
                FROM memories m
                JOIN folders f ON f.id = m.folder_id
                JOIN source_memories sm ON sm.memory_id = m.id
                JOIN sources s ON s.id = sm.source_id
                WHERE f.kind = 'source' AND f.project_root IS NULL
                """)

            var seen: Set<String> = []
            for row in rows {
                guard let folderID: String = row["folder_id"],
                      let path: String = row["path"],
                      !seen.contains(folderID) else { continue }
                let parent = (path as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != "/" else { continue }
                // The unique index on project_root means a directory already
                // claimed by another folder must not be written twice.
                let taken = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS (SELECT 1 FROM folders WHERE project_root = ?)",
                    arguments: [parent]
                ) ?? false
                guard !taken else { continue }
                try db.execute(
                    sql: "UPDATE folders SET project_root = ? WHERE id = ?",
                    arguments: [parent, folderID]
                )
                seen.insert(folderID)
            }
        }

        return migrator
    }

    /// Names a migrated source folder after the directory its files came from.
    /// A purely numeric leaf ("2026") is meaningless on its own, so it inherits
    /// its parent — "Apple Health Card/2026" becomes "Apple Health Card 2026".
    static func folderName(forDirectory path: String) -> String {
        let leaf = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespaces)
        guard !leaf.isEmpty, leaf != "/" else { return "Imported" }

        let isNumeric = !leaf.isEmpty && leaf.allSatisfy(\.isNumber)
        guard isNumeric else { return leaf }

        let parent = ((path as NSString).deletingLastPathComponent as NSString)
            .lastPathComponent
            .trimmingCharacters(in: .whitespaces)
        return parent.isEmpty ? leaf : "\(parent) \(leaf)"
    }
}
