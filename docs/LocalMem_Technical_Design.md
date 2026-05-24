# LocalMem - Technical Design Document v0.2

## Technical Goals
- Keep user memory local-first
- Encrypt memory before any sync occurs
- Avoid LocalMem-operated backend infrastructure in V1
- Lean on Apple-native trust primitives such as biometrics, Keychain, Secure Enclave, and CryptoKit
- Expose a clean adapter layer for AI clients, with Claude first
- Keep the implementation simple enough to ship and validate quickly

## Architecture

```text
Claude Desktop
    ↓ MCP
Claude Adapter (Swift)
    ↓
LocalMem Core (Swift package)
    ↓
Encrypted Vault
    ↓
SQLite + FTS5
    ↓
Optional CloudKit Sync
```

The CLI, MCP server, and macOS app are all thin surfaces over the same `LocalMemCore` Swift package. There is exactly one implementation of memory CRUD, search, permissions, and audit logging.

## System Components

### LocalMem Core
A Swift package (`LocalMemCore`) that owns:
- memory CRUD
- search
- tagging
- review state
- export
- audit metadata
- source permissions
- access history

### Agent Adapter Layer
V1 includes:
- Claude Desktop MCP adapter, built on the official Swift MCP SDK (`modelcontextprotocol/swift-sdk`)

Future adapters may include other desktop AI clients, but adapters should remain separate from the vault and storage model.

Adapters should operate with least-privilege access to user-approved sources rather than unrestricted access to all indexed content.

### CLI
A Swift executable target in the same SwiftPM package as the core, built with `swift-argument-parser`. The CLI is the primary developer and pro-user surface during Phases 1-3.

### Desktop App
- SwiftUI application targeting macOS 14+
- AppKit interop where SwiftUI is insufficient (menu bar, file pickers, NSOpenPanel scopes)
- Local management interface for memory, review, and agent access

## Technology Stack

### Core
- Swift 5.10+
- Swift Package Manager
- GRDB.swift for SQLite access (FTS5, migrations, observation)
- Foundation, `async`/`await` for concurrency
- `Foundation.UUID`, `Foundation.Date`

### CLI
- `swift-argument-parser`

### MCP Server
- `modelcontextprotocol/swift-sdk`

### Desktop
- SwiftUI
- AppKit interop where needed

### Storage
- SQLite (via GRDB)
- FTS5

### Apple Security Primitives
- Touch ID / Optic ID via `LocalAuthentication`
- Apple Keychain for vault key storage with access control
- Secure Enclave backed key operations where the hardware supports it
- CryptoKit for symmetric encryption of memory content

### Sync
- CloudKit for optional Apple-device sync

## Security Model

### Product Promise
LocalMem should not require a LocalMem-operated server to access user plaintext in V1.

It should also provide better visibility and tighter access control than broad cloud connectors that expose an entire account or drive.

### Vault Encryption
- A vault encryption key is generated on-device using CryptoKit.
- Memory content is encrypted with AES-GCM before being written to persistent storage.
- The vault key is wrapped and stored in the Apple Keychain with an access control flag requiring biometric presence.
- On supported hardware, the wrapping key is held in the Secure Enclave so the raw vault key is never exposed outside trusted hardware.

### Biometrics
- Touch ID (and Optic ID on supported devices) gates access to the vault key via `LocalAuthentication`.
- Biometrics are a local unlock mechanism, not the storage mechanism.
- The vault key is held in memory only for the duration of an unlocked session; the session length is user-configurable.

### Sync Privacy
- Sync is optional.
- If CloudKit sync is enabled, CloudKit should receive encrypted records, not plaintext memories.
- LocalMem should define its own encrypted record format rather than making CloudKit the source of truth for the product model.

### Access Transparency
- Every MCP request should be attributable to an agent or client.
- Retrieval operations should produce an access log recording which source items were read.
- Users should be able to inspect recent access history in the desktop app.
- LocalMem should support revoking an agent's access without deleting the underlying user data.

## Data Model

```swift
public struct Memory: Codable, Identifiable, Sendable {
    public let id: UUID
    public var type: MemoryType
    public var title: String?
    public var content: String
    public var tags: [String]
    public var source: MemorySource
    public var reviewState: ReviewState
    public let createdAt: Date
    public var updatedAt: Date
}
```

### Memory Types

```swift
public enum MemoryType: String, Codable, Sendable {
    case fact
    case preference
    case decision
    case project
    case note
}
```

### Memory Source

```swift
public enum MemorySource: String, Codable, Sendable {
    case user
    case claude
    case `import`
}
```

### Review State

```swift
public enum ReviewState: String, Codable, Sendable {
    case suggested
    case accepted
    case archived
}
```

## SQLite Schema

```sql
CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT,
    content BLOB NOT NULL,
    source TEXT NOT NULL,
    review_state TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE memory_tags (
    memory_id TEXT NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY (memory_id, tag),
    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE
);

CREATE VIRTUAL TABLE memories_fts USING fts5(
    title,
    content_plaintext,
    content='',
    tokenize='unicode61'
);
```

> Note: the FTS5 index currently holds plaintext, which weakens the encryption-at-rest claim. The handling of search-index confidentiality is an open decision (encrypted index, in-memory index rebuilt on unlock, or accepted tradeoff with documented threat model).

## Search Strategy
- V1 uses local full text search.
- Search indexes should be built locally from decrypted content.
- Search should not depend on a remote service.
- Semantic search is not required for V1.
- Retrieval should respect user-approved source scopes for each agent.
- Query responses should be able to report which memories or source documents were used.

## MCP Tools
V1 Claude adapter exposes:
- `memory_store`
- `memory_search`
- `memory_recent`
- `memory_delete`

UI-only features in V1 may include:
- edit
- export
- review queue
- pause memory

The adapter should treat `memory_recent` as the V1 mechanism for listing recent memory, rather than implying unrestricted enumeration of all stored content.

If adapter capabilities expand later, they should remain explicit and documented rather than inferred from UI behavior.

## Export

Formats:
- JSON
- SQLite

Exports should be user-initiated and understandable without proprietary tooling.

## UX-Driven Technical Constraints
- First launch should not require account creation.
- Unlock should feel like opening a vault, not logging into a web service.
- The app should avoid exposing database or crypto jargon in the main UI.
- User actions such as delete, export, and pause memory should map cleanly to real system behavior.
- Source sharing should feel like selecting files or folders, not configuring infrastructure.
- Access history should be human-readable, not a raw debug log.

## Roadmap

### v0.2
- macOS vault app (SwiftUI)
- local encrypted storage
- Claude MCP adapter

### v0.3
- CloudKit encrypted sync
- iPhone companion app for browse, search, and capture

### v0.4
- review and approval flows
- improved tagging and organization

### v1.0
- additional agent adapters
- stronger retrieval and ranking
