import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
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
        }

        return migrator
    }
}
