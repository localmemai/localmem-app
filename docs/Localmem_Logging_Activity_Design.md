# Localmem — Logging & Activity Design

Status: proposed, pre-implementation
Owner: localmem-app
Related: [Localmem_Technical_Design.md](Localmem_Technical_Design.md) § Access Transparency

## Goals

- Give the user a durable, human-readable trail of every memory operation that the upcoming desktop UI can render as an Activity feed.
- Give developers a structured app log that surfaces errors and slow paths without polluting the MCP stdio stream.
- Add zero external dependencies and zero network egress. Localmem stays local-first.

## Non-goals

- Metrics, dashboards, alerting, OpenTelemetry — overkill for a single-user local app.
- Crash reporting SDKs or any feature that phones home.
- Cross-machine log shipping or aggregation.

## Two streams

| Stream | Purpose | Backend | Audience | Durability |
|---|---|---|---|---|
| App log | Debug, errors, slow paths, startup notices | `os.Logger` + a rotating JSON-lines file at `~/Library/Logs/Localmem/localmem.log` | Developer / troubleshooting; the UI's log viewer | Bounded by rotation policy (50 MB cap) |
| Activity log | Audit trail of every memory operation | New SQLite table in `localmem.sqlite3` | End user (UI feed, badges) | Durable, capped at 100k rows |

The streams have different audiences and different lifetimes, so they are stored separately and accessed through different APIs.

## App log

Thin facade over `os.Logger` in `LocalmemCore`, fanning out to two sinks:

- **`os.Logger`** (subsystem `com.localmem`, categories `store` / `mcp` / `cli` / `setup`) — for Console.app, `log show`, and Apple's diagnostic tooling. The system manages retention; no work for us.
- **Rotating file** at `~/Library/Logs/Localmem/localmem.log` — JSON lines, one record per line. This is the source the desktop UI will tail and the file a user can attach to a bug report.

Levels follow the OSLog vocabulary: `debug`, `info`, `notice`, `error`, `fault`. `LOCALMEM_LOG_LEVEL` env var bumps verbosity.

The MCP binary's existing stderr write (`LocalmemMCP.log`) becomes a thin call into the facade — stderr stays for fatal/startup messages only, so we don't bloat whatever log the MCP launcher (Claude Desktop, etc.) writes its child stderr into.

No new SPM dependency: the rotating handler is ~100 lines of in-house code.

### Rotation policy

- **Location:** `~/Library/Logs/Localmem/` (the macOS convention; surfaces in Console.app and is the directory support workflows expect).
- **Active file:** `localmem.log`.
- **Rotation trigger:** size-based — when a write would push the active file over **10 MB**, the file is rotated before the write.
- **Naming on rotation:** `localmem.log` → `localmem.1.log`; existing `localmem.N.log` shifts to `localmem.(N+1).log`; the file beyond the retention count is unlinked.
- **Retention:** **5 archived files** (`localmem.1.log` through `localmem.5.log`) + the active file, for a **hard cap of 50 MB** on disk.
- **Why not time-based:** burstiness — a quiet week followed by a busy hour shouldn't either lose info or roll prematurely. Size-based gives a constant disk budget regardless of usage shape.

Why these numbers: ~10 MB holds tens of thousands of structured records, so a single archive captures a meaningful debugging window. 50 MB total is unnoticeable on any Mac that runs Localmem, and matches the order of magnitude users expect for an app's logs.

### What is written to the file

- All `notice`-level and above by default. `debug` and `info` go to OSLog only — they're useful while developing but would burn the disk budget quickly under chatty MCP clients.
- `LOCALMEM_LOG_FILE_LEVEL` env var overrides the file's minimum level for diagnostic captures (e.g. `debug` while reproducing a bug).
- Structured fields per line: `ts`, `level`, `category`, `message`, plus arbitrary key/value context.

### Concurrency and flushing

The rotating handler is an `actor` that owns the file handle. Log call sites enqueue work without blocking; writes (and rotation) are serialised inside the actor. Rotation is a single atomic sequence within the actor's executor — no other write can interleave.

Short-lived processes need an explicit drain point. The facade exposes `Log.flush() async`, which waits for the rotating file handler to finish all writes enqueued before the flush call. Long-lived MCP processes rarely need it, but CLI commands and tests should call it before process exit / assertion so notice-and-above file records are not lost to fire-and-forget task scheduling.

### Failure modes

- Disk full / write error: the handler swallows the error after logging once to OSLog (so we don't crash the host process). Subsequent writes continue to try — a transient ENOSPC heals on its own.
- Logs directory missing: created on first write.
- File replaced externally (rotated by something else, deleted): the handler reopens on the next write.

### Out of scope for v1 file rotation

- Compression of archived files (gzip). Easy follow-up; the JSON-lines format compresses ~10×, which would bump effective retention to ~500 MB worth at the same on-disk footprint. Deferred until the UI lands and we see real volumes.
- Per-category file splits. One file keeps reasoning about the budget simple.

## Activity log

A new SQLite table inside `localmem.sqlite3`, populated by every MCP tool call and every CLI command that touches memory state.

### Storage decision

The activity table lives in the **same** SQLite file as `memories`. This lets a memory write and its activity row commit in a single transaction, keeps the user's data in one backup-able file, and reuses the existing WAL + `busy_timeout=5000` configuration. The actor split (`MemoryStore`, `ActivityStore`) shares one `DatabaseQueue`.

### Schema (migration v2)

```sql
CREATE TABLE activity (
    id            TEXT PRIMARY KEY,         -- UUID
    occurred_at   TEXT NOT NULL,            -- ISO8601 with fractional seconds
    actor_kind    TEXT NOT NULL,            -- 'mcp' | 'cli'
    actor_id      TEXT,                     -- MCP client name; null for CLI
    operation     TEXT NOT NULL,            -- 'memory_store' | 'memory_search' | 'memory_recent' | 'memory_delete' | ...
    status        TEXT NOT NULL,            -- 'ok' | 'error' | 'cancelled'
    duration_ms   INTEGER NOT NULL,
    memory_id     TEXT,                     -- target memory if applicable (soft FK — survives delete)
    query         TEXT,                     -- raw search query when operation = 'memory_search'
    result_count  INTEGER,                  -- count for search/recent results
    error_message TEXT                      -- short error string if status = 'error' or cancellation reason if available
);

CREATE INDEX idx_activity_occurred_at ON activity(occurred_at DESC);
CREATE INDEX idx_activity_actor       ON activity(actor_kind, actor_id);
```

### What is deliberately NOT stored

- Full memory content — already in `memories`; activity rows reference by `memory_id`.
- Full result sets — only `result_count`.
- Arbitrary argument blobs — only the small set of fields above. New operations add new columns through migrations, not a generic JSON blob.

### Query handling

Search queries are stored **verbatim** in the `query` column. Rationale: Localmem is a local, single-user tool; the value of "what did Claude search for" in the UI outweighs the risk of a sensitive substring sitting on disk next to the memories it could have already retrieved. A future setting can downgrade this to a hash if the multi-user / shared-machine model ever appears.

### Retention

Capped at **100,000 rows**, oldest dropped on insert. Implementation: an `AFTER INSERT` trigger that deletes rows below the cutoff `rowid`. Rationale: bounded disk footprint without requiring user intervention; 100k is enough for years of single-agent usage given expected operation rates. A `localmem activity prune --before <date>` CLI can be added later for manual trims.

```sql
CREATE TRIGGER activity_cap_after_insert AFTER INSERT ON activity
WHEN (SELECT COUNT(*) FROM activity) > 100000
BEGIN
    DELETE FROM activity
    WHERE rowid IN (
        SELECT rowid FROM activity ORDER BY rowid ASC LIMIT (SELECT COUNT(*) - 100000 FROM activity)
    );
END;
```

The trigger runs in the same transaction as the insert, so cap enforcement is atomic.

## API surface (`LocalmemCore`)

```swift
public struct ActivityEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let occurredAt: Date
    public let actorKind: ActorKind        // .mcp, .cli
    public let actorID: String?
    public let operation: String
    public let status: ActivityStatus      // .ok, .error
    public let durationMs: Int
    public let memoryID: UUID?
    public let query: String?
    public let resultCount: Int?
    public let errorMessage: String?
}

public enum ActorKind: String, Codable, Sendable { case mcp, cli }
public enum ActivityStatus: String, Codable, Sendable { case ok, error, cancelled }

public actor ActivityStore {
    // Shares the DatabaseQueue with MemoryStore — see "DB ownership" below.
    public func record(_ entry: ActivityEntry) async throws
    public func recent(limit: Int = 100) async throws -> [ActivityEntry]
}

public enum ActivityTiming {
    public static func durationMs(since start: ContinuousClock.Instant) -> Int
}
```

There is intentionally no generic recorder abstraction in v1. Read call sites (`memory_search`, `memory_recent`) record activity with local `do/catch` blocks. The duplication is small, keeps control flow obvious, and avoids making simple CLI commands feel like framework code.

Mutating memory operations that need "memory row + activity row" atomicity use the lower-level database transaction API described in "DB ownership" below instead of calling `MemoryStore.add(...)` and then `ActivityStore.record(...)` as two independent operations.

### Logging facade

```swift
public enum LogCategory: String, Sendable {
    case store, mcp, cli, setup
}

public enum Log {
    // Fans out to both os.Logger and the rotating file handler.
    public static func debug (_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:])
    public static func info  (_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:])
    public static func notice(_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:])
    public static func error (_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:])
    public static func fault (_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:])
    public static func flush() async
}

actor RotatingFileLogHandler {
    init(directory: URL, baseName: String = "localmem.log", maxBytes: Int = 10_000_000, retainedArchives: Int = 5)
    func write(_ line: String) async
    func flush() async
}
```

The fan-out lives inside `Log` so callers can't accidentally bypass one sink. `@autoclosure` defers string interpolation when a level is filtered out — important because per-request paths call this hot. `flush()` is intentionally async and file-sink-specific; OSLog has its own buffering and retention semantics.

## DB ownership

`MemoryStore.init(databaseURL:)` currently owns its own `DatabaseQueue`. To share with `ActivityStore`, refactor as:

```swift
public final class Database: Sendable {
    public init(url: URL) throws  // applies pragmas + migrations
    let queue: DatabaseQueue
    func read<T>(_ body: @Sendable (GRDB.Database) throws -> T) async throws -> T
    func write<T>(_ body: @Sendable (GRDB.Database) throws -> T) async throws -> T
}

public actor MemoryStore   { public init(database: Database) }
public actor ActivityStore { public init(database: Database) }
```

A single `Database` is created once at process startup. The default public initialiser on each store still exists as a convenience that opens the default URL.

The `Database.write` closure is the boundary for operations that must commit memory state and activity state atomically. For example, `memory_store` should insert the `memories` row, insert the `activity` row, and let SQLite commit or roll back both together. Read-only activity rows (`memory_search`, `memory_recent`) are recorded after the read with explicit `do/catch` blocks; if that audit insert fails, the command surfaces that error just like any other local persistence failure.

## Integration

### MCP server

- On `initialize`, capture `clientInfo.name` (verify swift-sdk exposes it on the request handler; if not, fall back to `LOCALMEM_CLIENT_ID` env var, then `"unknown-mcp"`).
- `ToolRegistry.call(...)` receives an `ActivityStore` configured with the captured client name, plus access to the shared `Database` for transactional mutations.
- Each read handler records `resultCount` directly after fetching results.
- Each mutating handler (`memory_store`, future `memory_delete`) records activity in the same `Database.write` transaction as the memory mutation, populating `memoryID` directly.
- `memory_store` continues to write the existing `Memory.source` value for backward compatibility, but the activity row is the authoritative source for the MCP client identity. Do not overload `Memory.source` with client names.

### CLI

- Memory-touching commands construct an `ActivityStore` with `actorKind = .cli`, `actorID = nil`.
- Search/list commands use explicit `do/catch` blocks to record `ok`, `error`, or `cancelled`. Mutating commands use transaction-aware helpers. Pure read-only commands like `path` and `status` may opt out — they reveal nothing about the user's memories and aren't interesting for an audit feed.
- CLI entrypoints call `await Log.flush()` before exit when they emitted file-backed log records.

## UI consumers (future work, not in this milestone)

- Activity feed view: a future filtered query API driving a SwiftUI list with date / actor / operation / status columns; tap row to expand.
- Per-memory access trail: a future `memoryID` filter for "who has touched this memory" UX.
- "Last accessed by …" badges on memories: a join over the latest activity row per memory_id.

None of those views ship in this milestone. The data they need must, however, be present from day one — that is the whole point of doing this work now rather than after the UI lands.

## Implementation plan

Numbered tasks, intended to land as small, separately-reviewable commits.

1. **Migration v2: `activity` table + cap trigger.** Update `Sources/LocalmemCore/Migrations.swift`. Add a migration test that asserts the table, indexes, and trigger are present.
2. **`Activity.swift` model.** `ActivityEntry`, `ActorKind`, `ActivityStatus`. Codable + Sendable.
3. **`Database` wrapper.** Extract pragma + migrator handling from `MemoryStore` into a `Database` type that both stores consume. Update `MemoryStore.init` overloads; preserve the existing public no-arg init.
4. **`ActivityStore` actor.** `record`, `recent`. Unit-tested against an in-memory DB.
5. **Transactional mutation helpers.** Add shared helpers for memory mutations that must commit their activity row in the same `Database.write` transaction. Tests cover rollback: force an activity insert failure and assert the memory mutation is not committed.
6. **`RotatingFileLogHandler` + `Log.swift` facade.** Implement the rotating actor (size check, atomic rotation, lazy reopen, `flush()`). Wire the facade to fan out into both `os.Logger` and the handler. Replace `LocalmemMCP.log(_:)`'s direct stderr write with the facade — stderr stays only for fatal/startup messages. Tests cover: write under threshold, rotation at threshold, retention dropping oldest, recovery after external delete, concurrent writes from multiple tasks, flush before assertion.
7. **Explicit read recording.** Add direct `do/catch` activity recording for `memory_search` and `memory_recent` in CLI and MCP code paths. Tests cover ok / error / cancellation paths where practical.
8. **MCP wiring.** Capture client name on `initialize`. Record reads explicitly; wrap mutations in transaction-aware helpers. Add an integration test that runs `memory_store` + `memory_search` and asserts the corresponding activity rows, including atomicity for `memory_store`.
9. **CLI wiring.** Wrap every memory-touching command. Add a CLI test that runs `localmem add` and asserts an activity row. Add a smoke test or unit seam for `Log.flush()` on CLI shutdown.
10. **Docs update.** Append the schema and behaviour notes to `docs/Localmem_Technical_Design.md` § Access Transparency, with a back-link to this file.

Each step compiles and tests green on its own.

## Open questions to resolve during implementation

- **`clientInfo` exposure** — confirm `modelcontextprotocol/swift-sdk` ≥ 0.7.0 surfaces `initialize.clientInfo.name` on the server side. If not, document the env-var fallback explicitly and file a follow-up.
- **CLI vs MCP source field** — today `Memory.source` is `user | claude | import`. Once the activity log carries `actor_kind / actor_id`, `source` becomes partially redundant. Defer reconciling them until the UI work surfaces a real conflict; both are cheap to keep.
- **MCP `memory_delete`** — currently CLI-only per commit `b838742`. When MCP delete lands behind access control, it inherits this design with no schema change.
- **Verbatim query visibility** — v1 stores search queries as local audit data. Before the desktop UI exposes the feed, decide whether to add copy that makes this obvious to users, or a setting that hashes / suppresses query text for shared-machine workflows.
- **Activity cap trigger cost** — seed a test database at or above 100k rows and measure insert latency before shipping. If the trigger is too expensive, replace the `COUNT(*)` trigger condition with a cheaper periodic prune strategy.
