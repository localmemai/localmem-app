# Localmem V1 Core Build - Design Document

## Scope
This document covers the first shippable slice of Localmem: a local SQLite-backed memory store, an MCP server that Claude Desktop talks to, and a read-only CLI for inspecting stored memory.

### In scope
- Swift package with a reusable core (`LocalmemCore`)
- Local SQLite store with FTS5 full-text search
- MCP server exposing `memory_store`, `memory_search`, `memory_recent`
- CLI: `list`, `search`, `show`, `add`, `path`
- Claude Desktop registration

> The CLI was initially scoped as read-only with all writes going through MCP. We later added `add` as a developer/scripting surface so the CLI can be exercised end-to-end before the MCP server lands, and to support automation use cases (cron jobs, import scripts). The mental model: **CLI is the developer/power-user surface; MCP is the agent surface.**

### Explicitly deferred
- Encryption (vault key, CryptoKit, Keychain, biometric unlock)
- `memory_delete` MCP tool
- Sources (folders/files), source registration, source-scoped permissions
- Per-agent attribution beyond a single `source: claude` stamp
- Access event audit log surfaced to users
- macOS app, review queue, export
- CloudKit sync

The schema and Swift types are shaped so these deferred items can land later without breaking changes — see [Forward Compatibility](#forward-compatibility).

## Project Layout
Single SwiftPM package with three targets:

```
localmem-app/
├── Package.swift
├── Sources/
│   ├── LocalmemCore/          # library target
│   │   ├── Memory.swift
│   │   ├── MemoryStore.swift
│   │   ├── Database.swift
│   │   ├── Migrations.swift
│   │   └── Paths.swift
│   ├── localmem/              # CLI executable
│   │   ├── LocalmemCLI.swift
│   │   └── Commands/
│   │       ├── ListCommand.swift
│   │       ├── SearchCommand.swift
│   │       ├── ShowCommand.swift
│   │       ├── AddCommand.swift
│   │       └── PathCommand.swift
│   └── localmem-mcp/          # MCP server executable
│       ├── main.swift
│       └── Tools/
│           ├── MemoryStoreTool.swift
│           ├── MemorySearchTool.swift
│           └── MemoryRecentTool.swift
└── Tests/
    └── LocalmemCoreTests/
```

### Dependencies
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite, FTS5, migrations
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) — CLI
- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) — MCP server

Target platform: macOS 26+ (Tahoe). Swift 6+. SwiftPM platform pin: `.macOS(.v26)`.

## Storage

### Location
```
~/Library/Application Support/Localmem/memory.sqlite3
```

Created on first run if missing. The directory is also created if missing.

### SQLite configuration
- WAL mode (`PRAGMA journal_mode=WAL`) so the CLI can read while the MCP server has the database open.
- Foreign keys on (`PRAGMA foreign_keys=ON`).
- Busy timeout 5s.

## Data Model

### Swift types

```swift
public struct Memory: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var type: MemoryType
    public var title: String?
    public var content: String
    public var tags: [String]
    public var source: MemorySource
    public let createdAt: Date
    public var updatedAt: Date
}

public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case fact, preference, decision, project, note
}

public enum MemorySource: String, Codable, Sendable {
    case user, claude, `import`
}
```

### SQLite schema

```sql
CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT,
    content BLOB NOT NULL,                -- UTF-8 bytes in V1; ciphertext later
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,             -- ISO 8601
    updated_at TEXT NOT NULL
);

CREATE TABLE memory_tags (
    memory_id TEXT NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY (memory_id, tag),
    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE
);

CREATE INDEX idx_memories_created_at ON memories(created_at DESC);

CREATE VIRTUAL TABLE memories_fts USING fts5(
    title,
    content_plaintext,
    content='',
    tokenize='unicode61'
);

-- Triggers to keep FTS in sync with memories table.
-- (Simple direct INSERT/UPDATE/DELETE triggers; spelled out in Migrations.swift.)
```

`content` is `BLOB` in V1 holding UTF-8 bytes. When encryption lands the column type does not change — the bytes become AES-GCM ciphertext + nonce + tag.

## Core API

`LocalmemCore` exposes one main type:

```swift
public actor MemoryStore {
    public init(databaseURL: URL) throws

    public func add(
        content: String,
        type: MemoryType,
        title: String? = nil,
        tags: [String] = [],
        source: MemorySource
    ) async throws -> Memory

    public func get(id: UUID) async throws -> Memory?

    public func search(query: String, limit: Int = 20) async throws -> [Memory]

    public func recent(limit: Int = 20) async throws -> [Memory]
}
```

All three surfaces (CLI, MCP server, future app) construct a `MemoryStore` pointing at the same database file. The actor wraps GRDB's connection pool — concurrent reads, serialized writes.

## MCP Server

Binary name: `localmem-mcp`. Communicates over stdio (the transport Claude Desktop uses to spawn local MCP servers).

### Tools

#### `memory_store`
Persist a new memory.

Input schema:
```json
{
  "type": "object",
  "required": ["content"],
  "properties": {
    "content": { "type": "string", "description": "The memory content." },
    "title":   { "type": "string", "description": "Optional short title." },
    "type":    { "type": "string", "enum": ["fact","preference","decision","project","note"], "default": "note" },
    "tags":    { "type": "array", "items": { "type": "string" }, "default": [] }
  }
}
```

Output: `{ "id": "<uuid>" }`.

All memories written via this tool are stamped `source: claude`.

#### `memory_search`
Full-text search over stored memories.

Input schema:
```json
{
  "type": "object",
  "required": ["query"],
  "properties": {
    "query": { "type": "string" },
    "limit": { "type": "integer", "minimum": 1, "maximum": 50, "default": 20 }
  }
}
```

Output: array of memory objects (id, type, title, content, tags, createdAt).

Implementation note: queries pass through GRDB's FTS5 match syntax. Wrap user input to avoid syntax errors (escape quotes, treat as a phrase if it contains spaces).

#### `memory_recent`
Most recently created memories, newest first.

Input schema:
```json
{
  "type": "object",
  "properties": {
    "limit": { "type": "integer", "minimum": 1, "maximum": 50, "default": 20 }
  }
}
```

Output: array of memory objects.

### Logging
The MCP server logs to stderr only — stdout is the MCP transport channel and must stay clean. Claude Desktop captures stderr; for dev, also tee to `~/Library/Logs/Localmem/mcp.log`.

### Errors
Surfaced as MCP tool errors with a short human-readable message. No stack traces over the wire.

## CLI

Binary name: `localmem`. Built with `swift-argument-parser`.

### Commands

```
localmem list [--limit N]              # most recent memories, default 20
localmem search <query> [--limit N]    # FTS search
localmem show <id>                     # full content of a single memory
localmem path                          # print the database path (debug helper)
```

### Output format
Default is a compact human-readable table. `--json` flag on every command emits the raw memory objects for scripting.

Example `localmem list` output:
```
ID        CREATED              TYPE        TITLE
a1b2c3d4  2026-05-24 14:02:11  note        First memory
e5f6g7h8  2026-05-24 13:51:09  preference  Prefers terse answers
```

`localmem show <id>` accepts a unique prefix (matching `git`-style short IDs) and prints the full memory including content and tags.

## Claude Desktop Registration

The user adds an entry to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "localmem": {
      "command": "/usr/local/bin/localmem-mcp"
    }
  }
}
```

Install path: `swift build -c release` produces `.build/release/localmem-mcp` and `.build/release/localmem`. A simple `make install` (or `scripts/install.sh`) copies both into `/usr/local/bin/`.

After editing the config the user restarts Claude Desktop. The three tools appear under the `localmem` server in Claude's tool list.

## Build & Run

```bash
swift build                    # debug build
swift run localmem list        # run CLI from build dir
swift run localmem-mcp         # run MCP server (stdio; for manual testing pipe JSON-RPC)
swift test                     # run LocalmemCore unit tests
swift build -c release         # release build
```

## Testing Strategy

V1 tests focus on `LocalmemCore`:
- round-trip `add` → `get` → `search` → `recent`
- FTS5 returns matches and excludes non-matches
- migrations apply cleanly to a fresh DB
- ordering: `recent` is newest-first

MCP and CLI layers get smoke tests only — they are thin wrappers and the real logic lives in the core.

## Forward Compatibility

Decisions made now to avoid breaking changes later:

| Future feature | What we did in V1 |
|---|---|
| Encryption | `content` is already `BLOB`; swap UTF-8 bytes for AES-GCM ciphertext, store key wrapping in Keychain. |
| Review queue | Additive: add a `review_state` column with a default, plus a `ReviewState` enum on `Memory`. |
| Sources / permissions | Not introduced; will be additive tables (`sources`, `permission_grants`) with no change to `memories`. |
| Per-agent attribution | `source` enum already exists; adding an `agent_id` column later is additive. |
| Audit log | Not introduced; will be a new `access_events` table. |

## Open Questions

1. **FTS index confidentiality** — the FTS5 `content_plaintext` column will hold plaintext even after we add content encryption. Resolution deferred to the encryption milestone, but flagged here so we don't forget.
2. **Tool result token budget** — `memory_search` and `memory_recent` return full content. For agents this can blow context if memories are long. Decide later whether to truncate by default and offer a `full=true` flag.
3. **Tag normalization** — should tags be lowercased / trimmed at write time? V1 stores them verbatim; revisit after seeing real usage.
