# LocalMem V1 - Step-by-Step Build Guide

A learning-oriented walkthrough that builds the V1 slice end-to-end: a SwiftPM package containing `LocalMemCore`, a `localmem` CLI, and a `localmem-mcp` server, plus Claude Desktop registration.

Each step has:
- **Goal** — what you're building
- **Why** — the reasoning behind the choice
- **Do** — commands or code to write
- **Verify** — how to know it worked

---

## Phase 0 — Setup & Verification

### Step 0.1 — Confirm your toolchain
**Goal:** Make sure Swift 6+ and Xcode command-line tools are installed.

**Do:**
```bash
swift --version
xcode-select -p
```

**Verify:** You should see something like `Swift version 6.x` and a path like `/Applications/Xcode.app/Contents/Developer`. If `xcode-select -p` errors, run `xcode-select --install`.

**Why:** SwiftPM, the compiler, and the system SDKs all come from Xcode (or the standalone Command Line Tools). We need the toolchain that supports macOS 26 (Tahoe).

---

## Phase 1 — Scaffold the SwiftPM package

### Step 1.1 — Initialize the package
**Goal:** Create an empty SwiftPM package in the existing repo.

**Do:** From `/Users/viditgupta/projects/localmem-app`:
```bash
swift package init --type empty --name LocalMem
```

This drops a minimal `Package.swift` next to your `docs/` folder. We'll rewrite it in the next step.

### Step 1.2 — Write `Package.swift`
**Goal:** Declare one library target (`LocalMemCore`) and two executable targets (`localmem`, `localmem-mcp`), plus external dependencies.

**Why:** Keeping the core in its own library means the CLI and MCP server both call into the same code paths — no duplication of storage logic, no risk of drift.

**Do:** Replace the contents of `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalMem",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "LocalMemCore", targets: ["LocalMemCore"]),
        .executable(name: "localmem", targets: ["localmem"]),
        .executable(name: "localmem-mcp", targets: ["localmem-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "LocalMemCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "localmem",
            dependencies: [
                "LocalMemCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "localmem-mcp",
            dependencies: [
                "LocalMemCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "LocalMemCoreTests",
            dependencies: ["LocalMemCore"]
        ),
    ]
)
```

> **Note:** Version numbers above are reasonable defaults at the time of writing. If `swift package resolve` reports a version that doesn't exist, bump to the newest published tag for each dependency.

### Step 1.3 — Create the source directories
**Do:**
```bash
mkdir -p Sources/LocalMemCore Sources/localmem/Commands Sources/localmem-mcp/Tools Tests/LocalMemCoreTests
```

### Step 1.4 — Verify it resolves and builds
**Do:**
```bash
swift package resolve
swift build
```

**Verify:** Resolve downloads GRDB, swift-argument-parser, and swift-sdk into `.build/`. Build will fail because the targets have no sources yet — that's expected. Drop placeholders so the build succeeds:

```bash
printf "// placeholder — replaced in Phase 2.1\n" > Sources/LocalMemCore/Placeholder.swift
printf "print(\"localmem stub\")\n"               > Sources/localmem/main.swift
printf "print(\"localmem-mcp stub\")\n"           > Sources/localmem-mcp/main.swift
```

Now `swift build` should succeed.

**Why three placeholders:** SwiftPM treats an empty library product as an error and an empty executable target as an error. The stubs unblock the build until we replace them in Phases 2 (delete `Placeholder.swift` after creating `Paths.swift`), 3, and 4.

---

## Phase 2 — Build `LocalMemCore`

This is the heart of the system. We'll build it in five files.

### Step 2.1 — `Paths.swift`: where the database lives
**Goal:** A single source of truth for the database file location.

**Why:** macOS apps store persistent data under `~/Library/Application Support/<AppName>/`. Putting this in one place means the CLI, the MCP server, and (later) the app all read/write the same file without arguments.

**Do:** Create `Sources/LocalMemCore/Paths.swift`:

```swift
import Foundation

public enum Paths {
    /// Directory: ~/Library/Application Support/LocalMem
    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("LocalMem", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File: ~/Library/Application Support/LocalMem/memory.sqlite3
    public static func databaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("memory.sqlite3")
    }
}
```

**Verify:** `swift build` still succeeds.

### Step 2.2 — `Memory.swift`: the data model
**Goal:** Define the Swift types that flow through every layer.

**Do:** Create `Sources/LocalMemCore/Memory.swift`:

```swift
import Foundation

public struct Memory: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var type: MemoryType
    public var title: String?
    public var content: String
    public var tags: [String]
    public var source: MemorySource
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        type: MemoryType,
        title: String? = nil,
        content: String,
        tags: [String] = [],
        source: MemorySource,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case fact, preference, decision, project, note
}

public enum MemorySource: String, Codable, Sendable {
    case user, claude, `import`
}
```

**Why `Sendable`:** Swift 6's strict concurrency requires values that cross actor/task boundaries to be `Sendable`. Our struct only contains value types and arrays of value types, so the conformance is automatic but worth declaring for clarity.

### Step 2.3 — `Migrations.swift`: schema
**Goal:** Set up the SQLite schema, FTS5 virtual table, and triggers that keep the search index in sync.

**Why a migrator:** GRDB's `DatabaseMigrator` tracks which migrations have run in a `grdb_migrations` table. On future schema changes you add a new `registerMigration(...)` block and old databases upgrade in place — you don't manually inspect schema versions.

**Why triggers on memories → memories_fts:** FTS5 indexes are populated by writes to the virtual table. Rather than remembering to insert into both tables, the triggers make it automatic. When you delete a memory, the trigger removes the index entry too — so search results can't go stale.

**Do:** Create `Sources/LocalMemCore/Migrations.swift`:

```swift
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
```

**Why `CAST(NEW.content AS TEXT)`:** Our `content` column is `BLOB` (to leave room for ciphertext later). For V1 the bytes happen to be UTF-8 plaintext, so SQLite can cast directly to TEXT for the FTS index. When encryption lands this trigger has to be revisited — the design doc flags this as an open question.

### Step 2.4 — `MemoryStore.swift`: the public API
**Goal:** A small, focused API that callers use to add, get, search, and list memories.

**Why an `actor`:** `MemoryStore` is a shared mutable resource. Actor isolation guarantees no two callers can interleave operations on it, which removes whole classes of bugs by construction.

**Why `prepareDatabase`:** SQLite pragmas like `journal_mode=WAL` must be set outside any transaction, on the raw connection. GRDB's `prepareDatabase` hook runs on every new connection before it's used.

**Do:** Create `Sources/LocalMemCore/MemoryStore.swift`:

```swift
import Foundation
import GRDB

public actor MemoryStore {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try Migrations.migrator.migrate(dbQueue)
    }

    // MARK: - Write

    public func add(
        content: String,
        type: MemoryType,
        title: String? = nil,
        tags: [String] = [],
        source: MemorySource
    ) async throws -> Memory {
        let memory = Memory(
            type: type,
            title: title,
            content: content,
            tags: tags,
            source: source
        )
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memories (id, type, title, content, source, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    memory.id.uuidString,
                    memory.type.rawValue,
                    memory.title,
                    Data(memory.content.utf8),
                    memory.source.rawValue,
                    DateFormat.iso8601.string(from: memory.createdAt),
                    DateFormat.iso8601.string(from: memory.updatedAt),
                ]
            )
            for tag in memory.tags {
                try db.execute(
                    sql: "INSERT INTO memory_tags (memory_id, tag) VALUES (?, ?)",
                    arguments: [memory.id.uuidString, tag]
                )
            }
        }
        return memory
    }

    // MARK: - Read

    public func get(id: UUID) async throws -> Memory? {
        try await dbQueue.read { db in
            try Self.fetchMemory(id: id.uuidString, in: db)
        }
    }

    public func recent(limit: Int = 20) async throws -> [Memory] {
        try await dbQueue.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM memories ORDER BY created_at DESC LIMIT ?",
                arguments: [limit]
            )
            return try ids.compactMap { try Self.fetchMemory(id: $0, in: db) }
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> [Memory] {
        let fts = Self.sanitizeFTSQuery(query)
        guard !fts.isEmpty else { return [] }
        return try await dbQueue.read { db in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT memory_id FROM memories_fts
                    WHERE memories_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [fts, limit]
            )
            return try ids.compactMap { try Self.fetchMemory(id: $0, in: db) }
        }
    }

    // MARK: - Helpers

    private static func fetchMemory(id: String, in db: Database) throws -> Memory? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM memories WHERE id = ?",
            arguments: [id]
        ) else {
            return nil
        }
        let tags = try String.fetchAll(
            db,
            sql: "SELECT tag FROM memory_tags WHERE memory_id = ?",
            arguments: [id]
        )
        return try Memory(row: row, tags: tags)
    }

    /// Wraps user input so it cannot break FTS5 syntax.
    /// Quoting the whole query treats it as a phrase or sequence of phrases.
    private static func sanitizeFTSQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Escape embedded double-quotes by doubling them, then wrap in quotes.
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Row decoding

extension Memory {
    init(row: Row, tags: [String]) throws {
        guard
            let idString: String = row["id"],
            let id = UUID(uuidString: idString),
            let typeString: String = row["type"],
            let type = MemoryType(rawValue: typeString),
            let sourceString: String = row["source"],
            let source = MemorySource(rawValue: sourceString),
            let contentData: Data = row["content"],
            let content = String(data: contentData, encoding: .utf8),
            let createdAtString: String = row["created_at"],
            let createdAt = DateFormat.iso8601.date(from: createdAtString),
            let updatedAtString: String = row["updated_at"],
            let updatedAt = DateFormat.iso8601.date(from: updatedAtString)
        else {
            throw MemoryStoreError.decodingFailed
        }
        self.init(
            id: id,
            type: type,
            title: row["title"],
            content: content,
            tags: tags,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum MemoryStoreError: Error {
    case decodingFailed
}

// MARK: - Date formatting

enum DateFormat {
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
```

**Verify:** `swift build` succeeds. If you get GRDB compiler errors complaining about Sendable closures, add `@unchecked Sendable` to `MemoryStore` temporarily — newer GRDB versions are fully Sendable-clean but exact wording may differ.

### Step 2.5 — Write a test
**Goal:** Prove `add` → `recent` → `search` works end-to-end against a real SQLite database.

**Do:** Create `Tests/LocalMemCoreTests/MemoryStoreTests.swift`:

```swift
import XCTest
@testable import LocalMemCore

final class MemoryStoreTests: XCTestCase {
    func makeStore() throws -> (MemoryStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite3")
        return (try MemoryStore(databaseURL: tmp), tmp)
    }

    func testAddAndRecent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "Hello world",   type: .note, source: .user)
        _ = try await store.add(content: "Second memory", type: .note, source: .user)

        let recent = try await store.recent(limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.content, "Second memory")
    }

    func testSearchMatchesAndExcludes() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await store.add(content: "The cat sat on the mat", type: .note, source: .user)
        _ = try await store.add(content: "Dogs are loyal",          type: .note, source: .user)

        let hits = try await store.search(query: "cat")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].content.contains("cat"))

        let misses = try await store.search(query: "elephant")
        XCTAssertTrue(misses.isEmpty)
    }
}
```

**Do:**
```bash
swift test
```

**Verify:** Both tests pass. If they don't, the failure message tells you whether it's a schema issue (migration didn't run), a decoding issue (row → Memory mapping wrong), or a search issue (FTS query syntax).

---

## Phase 3 — Build the CLI (`localmem`)

### Step 3.1 — Set up the root command
**Goal:** Wire `swift-argument-parser` into a command group that supports `list`, `search`, `show`, and `path`.

**Why argument-parser:** Apple's official CLI framework. You declare commands as types conforming to `ParsableCommand`; the framework handles `--help`, validation, and error printing for free.

**Do:** Replace `Sources/localmem/main.swift` with a small stub and add `Sources/localmem/LocalMemCLI.swift`:

```swift
// Sources/localmem/main.swift
import ArgumentParser

LocalMemCLI.main()
```

```swift
// Sources/localmem/LocalMemCLI.swift
import ArgumentParser
import Foundation
import LocalMemCore

struct LocalMemCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localmem",
        abstract: "Inspect LocalMem memories.",
        subcommands: [ListCommand.self, SearchCommand.self, ShowCommand.self, PathCommand.self],
        defaultSubcommand: ListCommand.self
    )
}
```

### Step 3.2 — `list` command
**Goal:** Print the most recent memories.

**Do:** Create `Sources/localmem/Commands/ListCommand.swift`:

```swift
import ArgumentParser
import Foundation
import LocalMemCore

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List most recent memories."
    )

    @Option(name: .shortAndLong, help: "Maximum number of memories to show.")
    var limit: Int = 20

    @Flag(help: "Emit JSON instead of a table.")
    var json: Bool = false

    func run() async throws {
        let store = try MemoryStore(databaseURL: try Paths.databaseURL())
        let memories = try await store.recent(limit: limit)
        if json {
            try OutputFormatter.printJSON(memories)
        } else {
            OutputFormatter.printTable(memories)
        }
    }
}
```

### Step 3.3 — `search` command
**Do:** Create `Sources/localmem/Commands/SearchCommand.swift`:

```swift
import ArgumentParser
import Foundation
import LocalMemCore

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search over stored memories."
    )

    @Argument(help: "Query string.")
    var query: String

    @Option(name: .shortAndLong)
    var limit: Int = 20

    @Flag var json: Bool = false

    func run() async throws {
        let store = try MemoryStore(databaseURL: try Paths.databaseURL())
        let memories = try await store.search(query: query, limit: limit)
        if json {
            try OutputFormatter.printJSON(memories)
        } else {
            OutputFormatter.printTable(memories)
        }
    }
}
```

### Step 3.4 — `show` command
**Goal:** Print the full content of a single memory by id (or unique id prefix, git-style).

**Do:** Create `Sources/localmem/Commands/ShowCommand.swift`:

```swift
import ArgumentParser
import Foundation
import LocalMemCore

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show full content of a memory."
    )

    @Argument(help: "Memory id (full UUID, or unique prefix).")
    var idOrPrefix: String

    @Flag var json: Bool = false

    func run() async throws {
        let store = try MemoryStore(databaseURL: try Paths.databaseURL())

        // Try direct UUID first.
        if let uuid = UUID(uuidString: idOrPrefix),
           let memory = try await store.get(id: uuid) {
            try render(memory)
            return
        }

        // Fall back to prefix matching against recent memories.
        let candidates = try await store.recent(limit: 500)
            .filter { $0.id.uuidString.lowercased().hasPrefix(idOrPrefix.lowercased()) }
        guard let memory = candidates.first else {
            throw ValidationError("No memory matching '\(idOrPrefix)'.")
        }
        guard candidates.count == 1 else {
            throw ValidationError("Ambiguous prefix '\(idOrPrefix)' matches \(candidates.count) memories.")
        }
        try render(memory)
    }

    private func render(_ memory: Memory) throws {
        if json {
            try OutputFormatter.printJSON([memory])
        } else {
            OutputFormatter.printDetail(memory)
        }
    }
}
```

### Step 3.5 — `path` command
**Do:** Create `Sources/localmem/Commands/PathCommand.swift`:

```swift
import ArgumentParser
import LocalMemCore

struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the LocalMem database path."
    )

    func run() throws {
        print(try Paths.databaseURL().path)
    }
}
```

### Step 3.6 — Output formatter
**Do:** Create `Sources/localmem/OutputFormatter.swift`:

```swift
import Foundation
import LocalMemCore

enum OutputFormatter {
    static func printTable(_ memories: [Memory]) {
        guard !memories.isEmpty else {
            print("(no memories)")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        print("ID        CREATED              TYPE        TITLE")
        for memory in memories {
            let shortId  = String(memory.id.uuidString.prefix(8)).lowercased()
            let created  = formatter.string(from: memory.createdAt)
            let type     = memory.type.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let title    = memory.title ?? memory.content.prefix(60).description
            print("\(shortId)  \(created)  \(type)  \(title)")
        }
    }

    static func printDetail(_ memory: Memory) {
        print("id:         \(memory.id.uuidString)")
        print("type:       \(memory.type.rawValue)")
        print("source:     \(memory.source.rawValue)")
        print("created_at: \(memory.createdAt)")
        print("updated_at: \(memory.updatedAt)")
        if let title = memory.title { print("title:      \(title)") }
        if !memory.tags.isEmpty { print("tags:       \(memory.tags.joined(separator: ", "))") }
        print("---")
        print(memory.content)
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
```

### Step 3.7 — Try the CLI
**Do:**
```bash
swift run localmem list
swift run localmem path
```

**Verify:** `list` prints `(no memories)` against a fresh database; `path` prints `~/Library/Application Support/LocalMem/memory.sqlite3`.

You can't write yet — that's intentional, writes happen via MCP. To smoke-test reads, drop into Swift and seed a memory:

```bash
swift run -c release localmem list   # also confirms release build works
```

Or temporarily, use the test scaffolding to insert a memory and re-run `list` pointing at the same DB.

---

## Phase 4 — Build the MCP server (`localmem-mcp`)

> The exact API of `modelcontextprotocol/swift-sdk` evolves between releases. The code below shows the structure and intent; if a type or method name has shifted, check the SDK README and adapt. The shape (one server, three tools, stdio transport) does not change.

### Step 4.1 — Entry point
**Goal:** Spin up a `Server`, register tool handlers, and serve over stdio until Claude Desktop closes the pipe.

**Why stdio:** Claude Desktop launches each MCP server as a child process and communicates via JSON-RPC framed over stdin/stdout. The server doesn't open a port and isn't reachable from other apps — only from the parent process that spawned it.

**Why stderr-only logging:** stdout is the JSON-RPC channel. A stray `print()` corrupts the protocol. All diagnostics go to `FileHandle.standardError`.

**Do:** Replace `Sources/localmem-mcp/main.swift`:

```swift
import Foundation
import LocalMemCore
import MCP

@main
struct LocalMemMCP {
    static func main() async throws {
        let store = try MemoryStore(databaseURL: try Paths.databaseURL())
        let registry = ToolRegistry(store: store)

        let server = Server(
            name: "localmem",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: registry.toolDescriptors)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await registry.call(name: params.name, arguments: params.arguments)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        log("LocalMem MCP server ready.")
        await server.waitUntilCompleted()
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[localmem-mcp] \(message)\n".utf8))
    }
}
```

### Step 4.2 — Tool registry and schemas
**Do:** Create `Sources/localmem-mcp/Tools/ToolRegistry.swift`:

```swift
import Foundation
import LocalMemCore
import MCP

struct ToolRegistry {
    let store: MemoryStore

    var toolDescriptors: [Tool] {
        [
            Tool(
                name: "memory_store",
                description: "Persist a new memory.",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("content")]),
                    "properties": .object([
                        "content": .object(["type": .string("string")]),
                        "title":   .object(["type": .string("string")]),
                        "type":    .object([
                            "type": .string("string"),
                            "enum": .array(MemoryType.allCases.map { .string($0.rawValue) }),
                            "default": .string("note"),
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "default": .array([]),
                        ]),
                    ]),
                ])
            ),
            Tool(
                name: "memory_search",
                description: "Full-text search over stored memories.",
                inputSchema: .object([
                    "type": .string("object"),
                    "required": .array([.string("query")]),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "limit": .object([
                            "type": .string("integer"),
                            "minimum": .number(1),
                            "maximum": .number(50),
                            "default": .number(20),
                        ]),
                    ]),
                ])
            ),
            Tool(
                name: "memory_recent",
                description: "Most recently created memories, newest first.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "minimum": .number(1),
                            "maximum": .number(50),
                            "default": .number(20),
                        ]),
                    ]),
                ])
            ),
        ]
    }

    func call(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        let args = arguments ?? [:]
        switch name {
        case "memory_store":  return try await handleStore(args)
        case "memory_search": return try await handleSearch(args)
        case "memory_recent": return try await handleRecent(args)
        default:
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    // MARK: - Handlers

    private func handleStore(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let content = args["content"]?.stringValue, !content.isEmpty else {
            throw MCPError.invalidParams("`content` is required and must be non-empty.")
        }
        let title = args["title"]?.stringValue
        let typeRaw = args["type"]?.stringValue ?? "note"
        guard let type = MemoryType(rawValue: typeRaw) else {
            throw MCPError.invalidParams("Unknown memory type: \(typeRaw)")
        }
        let tags = args["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let memory = try await store.add(
            content: content,
            type: type,
            title: title,
            tags: tags,
            source: .claude
        )
        return .init(content: [.text("{\"id\":\"\(memory.id.uuidString)\"}")])
    }

    private func handleSearch(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let query = args["query"]?.stringValue else {
            throw MCPError.invalidParams("`query` is required.")
        }
        let limit = args["limit"]?.intValue ?? 20
        let memories = try await store.search(query: query, limit: limit)
        return .init(content: [.text(try memories.toJSONString())])
    }

    private func handleRecent(_ args: [String: Value]) async throws -> CallTool.Result {
        let limit = args["limit"]?.intValue ?? 20
        let memories = try await store.recent(limit: limit)
        return .init(content: [.text(try memories.toJSONString())])
    }
}

// MARK: - JSON helper

extension Array where Element == Memory {
    func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
```

> **Adaptation note:** `Value`, `MCPError`, `CallTool.Result`, and `StdioTransport` are the names used by the current swift-sdk at time of writing. If you see compile errors, look at the SDK's `Examples/` directory — the structure (one server, `withMethodHandler` per JSON-RPC method, stdio transport) is consistent across versions.

### Step 4.3 — Build the server
**Do:**
```bash
swift build
```

**Verify:** No errors. If you see complaints about MCP types, that's where the SDK API has shifted — open the SDK's README and update names.

### Step 4.4 — Manual smoke-test (optional)
**Goal:** Confirm the server speaks JSON-RPC over stdio before handing it to Claude.

**Do:** Send a minimal handshake by hand:

```bash
swift run localmem-mcp <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"manual","version":"0.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
EOF
```

**Verify:** You see two JSON responses on stdout: an `initialize` result and a `tools/list` result containing your three tools. If you see your `[localmem-mcp] ready` log on stderr but nothing on stdout, the server isn't reading stdin correctly — re-check `StdioTransport`.

---

## Phase 5 — Install & register with Claude Desktop

### Step 5.1 — Release build
**Do:**
```bash
swift build -c release
```

This produces `.build/release/localmem` and `.build/release/localmem-mcp`.

### Step 5.2 — Install binaries
**Do:**
```bash
sudo install -m 0755 .build/release/localmem /usr/local/bin/localmem
sudo install -m 0755 .build/release/localmem-mcp /usr/local/bin/localmem-mcp
```

**Verify:**
```bash
which localmem
which localmem-mcp
localmem path
```

The first two should resolve to `/usr/local/bin/...`. `localmem path` should print the database location.

### Step 5.3 — Register with Claude Desktop
**Goal:** Tell Claude Desktop how to launch your MCP server.

**Do:** Open `~/Library/Application Support/Claude/claude_desktop_config.json` (create it if missing) and add a `mcpServers` entry. If the file already has servers configured, merge — do not overwrite.

```json
{
  "mcpServers": {
    "localmem": {
      "command": "/usr/local/bin/localmem-mcp"
    }
  }
}
```

Restart Claude Desktop (quit completely with ⌘Q, then relaunch).

**Verify:** In Claude Desktop, open the tools/connectors panel. You should see a `localmem` server with three tools listed.

### Step 5.4 — End-to-end test
**Goal:** Confirm the full loop works.

**Do:** In Claude Desktop, prompt:

> Save a memory: my preferred coffee order is a flat white with oat milk.

Claude should call `memory_store`. Then prompt:

> What do you remember about my coffee?

Claude should call `memory_search` for "coffee" and surface the memory.

**Verify in the CLI:**
```bash
localmem list
localmem search coffee
```

Both should show the memory. Now you have the loop closed.

---

## What's next

You now have a working V1 of LocalMem. The natural next slices, in order:

1. **Encryption** — wrap `content` in AES-GCM, store the key in Keychain behind a biometric access control. Decide what to do with the plaintext FTS index (see open question in the design doc).
2. **`memory_delete`** — add the fourth MCP tool plus a CLI `delete` command with confirmation.
3. **Access log** — start writing `access_events` rows for every MCP read/write, surface them via `localmem activity`.
4. **macOS app** — SwiftUI shell that uses the same `LocalMemCore` package; no new business logic, just UI.

Each lands additively on top of the V1 schema — no breaking migrations.
