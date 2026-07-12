# Localmem — Technical Design

> Single source of truth for Localmem's architecture, data model, security model,
> per-memory access control, the macOS app UI, and distribution. Localmem is a
> **macOS-only** product.

## Contents

1. [Goals](#1-goals)
2. [Architecture](#2-architecture)
3. [Technology stack](#3-technology-stack)
4. [Data model](#4-data-model)
5. [Security & privacy model](#5-security--privacy-model)
6. [Search](#6-search)
7. [MCP server & tools](#7-mcp-server--tools)
8. [Per-memory agent access control](#8-per-memory-agent-access-control)
9. [CLI](#9-cli)
10. [File connector](#10-file-connector)
11. [macOS app UI](#11-macos-app-ui)
12. [Distribution & packaging](#12-distribution--packaging)
13. [Roadmap](#13-roadmap)
14. [Open questions](#14-open-questions)

---

## 1. Goals

- Keep user memory **local-first** — no Localmem-operated backend to access user
  plaintext.
- Give agents a **persistent, cross-project memory** they read and write over MCP.
- Provide **better visibility and tighter access control** than broad cloud
  connectors that expose an entire account or drive.
- Lean on Apple-native trust primitives (biometrics, Keychain, Secure Enclave,
  CryptoKit) where they add value.
- Expose one clean core through three surfaces — app, CLI, MCP — with a single
  implementation of CRUD, search, permissions, and audit logging.
- Stay simple enough to ship and validate quickly.

## 2. Architecture

Localmem is a single Swift package. `LocalmemCore` owns all real logic; the app,
CLI, and MCP server are thin surfaces over it. There is exactly one
implementation of memory CRUD, search, permissions, and audit logging.

```text
Claude Code / Claude Desktop / Cursor / Codex / Antigravity
    ↓ MCP
localmem-mcp (MCP server)      localmem (CLI)      localmem-app (SwiftUI)
    └───────────────┬───────────────┴───────────────┘
                    ↓
             LocalmemCore (Swift package)
                    ↓
              SQLite + FTS5 (via GRDB)
```

### Products

Three binaries that must travel together (they share a database and the MCP
server is located as a **sibling of the running binary**):

| Binary | Role |
|---|---|
| `localmem-app` | SwiftUI vault app — browse memory, manage agent access, audit log, setup wizard |
| `localmem` | Command-line tool (`setup`, `add`, `search`, …); the admin/debug surface |
| `localmem-mcp` | The MCP server AI clients actually talk to |

`LocalmemCore` owns: memory CRUD, search, tagging, review state, source
permissions, access history, and export.

## 3. Technology stack

- **Language:** Swift, Swift Package Manager (`swift-tools-version: 6.2`),
  targeting macOS 26+.
- **Storage:** SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) —
  FTS5, migrations, observation.
- **CLI:** `swift-argument-parser`.
- **MCP server:** the official [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk).
- **App:** SwiftUI, with AppKit interop where SwiftUI is insufficient (menu bar,
  file pickers, `NSOpenPanel` scopes).
- **Config parsing:** `TOMLKit` (for clients such as Codex that use TOML).
- **Apple security primitives (planned, see §5):** `LocalAuthentication`,
  Keychain, Secure Enclave, CryptoKit.

## 4. Data model

A few durable concepts anchor the system and should stay stable as the UI
evolves: **Memory**, **Agent** (a connected MCP client), **access exclusions**,
and **AccessEvent** (the audit log).

```swift
public struct Memory: Codable, Identifiable, Sendable {
    public let id: UUID
    public var type: MemoryType
    public var title: String?
    public var content: String
    public var tags: [String]
    public var source: MemorySource
    public var reviewState: ReviewState
    public var excludedAgents: [String]   // see §8
    public let createdAt: Date
    public var updatedAt: Date
}

public enum MemoryType: String, Codable, Sendable {
    case fact, preference, decision, project, note
}

public enum MemorySource: String, Codable, Sendable {
    case user, claude, `import`
}

public enum ReviewState: String, Codable, Sendable {
    case suggested, accepted, archived
}
```

### SQLite schema

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

CREATE TABLE memory_agent_exclusions (
    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    agent_id  TEXT NOT NULL,
    PRIMARY KEY (memory_id, agent_id)
);
CREATE INDEX idx_excl_agent ON memory_agent_exclusions(agent_id);

CREATE VIRTUAL TABLE memories_fts USING fts5(
    title,
    content_plaintext,
    content='',
    tokenize='unicode61'
);
```

Tags and exclusions are written/replaced inside the same write transaction as
the memory, and populated on read via batched attach helpers (`attachTags`,
`attachExclusions`). `ON DELETE CASCADE` drops a memory's tag and exclusion rows
with it.

> **Migrations during development.** While Localmem is pre-release we do not add
> new migrations — schema changes go **inside the existing `v1_initial` block**
> in `Migrations.swift`. Delete the local dev database and it is recreated fresh.

### Import / export

User-initiated **JSON** import and export, driven from the top-toolbar
**Import / Export** menu — primarily for moving a vault between Macs, plus
plain-text backup understandable without any proprietary tooling.

The codec lives in `LocalmemCore` (`MemoryArchive`) so the CLI can reuse it and
it is unit-testable without the GUI. Export writes a versioned envelope
(`schemaVersion`, `exportedAt`, `app`, `memories[]`); each memory round-trips at
full fidelity — id, fractional-second ISO-8601 timestamps, tags, exclusions, and
source. Import (`MemoryStore.importMemories`) inserts with `INSERT OR IGNORE`,
**skipping ids that already exist** so re-importing the same archive is
idempotent, and reports `imported` / `skipped` counts. Decode rejects malformed
files and archives from a newer `schemaVersion` with a clear message.

## 5. Security & privacy model

### Product promise

Localmem should not require a Localmem-operated server to access user plaintext.
It should also provide better visibility and tighter access control than broad
cloud connectors that expose an entire account or drive.

### Vault encryption (planned)

- A vault key is generated on-device with CryptoKit; memory content is encrypted
  with AES-GCM before being written.
- The vault key is wrapped and stored in the Keychain with an access-control flag
  requiring biometric presence; on supported hardware the wrapping key lives in
  the Secure Enclave so the raw key never leaves trusted hardware.
- Touch ID / Optic ID (`LocalAuthentication`) gates access to the vault key. The
  key is held in memory only for the duration of an unlocked session
  (user-configurable length).

> **Open tension:** the FTS5 index holds plaintext, which weakens
> encryption-at-rest. Handling search-index confidentiality (encrypted index,
> in-memory index rebuilt on unlock, or an accepted tradeoff with a documented
> threat model) is an open decision.

### Sync privacy (planned)

Sync is optional. If CloudKit sync is enabled, CloudKit receives **encrypted
records**, not plaintext. Localmem defines its own encrypted record format rather
than making CloudKit the source of truth for the product model.

### Access transparency

- Every MCP request is attributable to an agent/client.
- Reads, searches, writes, and deletes are logged as access events.
- Users inspect recent access history in the app (see §11).
- An agent's access can be revoked without deleting the underlying user data
  (see §8).

## 6. Search

- V1 uses **local full-text search** (SQLite FTS5), built from decrypted content;
  no remote service.
- Multi-token search is **AND**, not OR.
- Retrieval respects per-agent access rules (§8): the exclusion filter runs
  before `ORDER BY rank LIMIT ?` so hidden rows do not consume result slots.
- Semantic search is **not** required for V1.

## 7. MCP server & tools

The MCP server exposes four tools. Every handler attributes the call to an agent
via `MCPClientIdentity` and threads that identity into the store for filtering
and audit logging.

- `memory_store` — persist a new fact, preference, or decision.
- `memory_search` — full-text search over stored memories.
- `memory_recent` — most-recent-first listing (the V1 listing mechanism, not
  unrestricted enumeration).
- `memory_update` — replace fields on an existing memory. **Destructive**;
  deliberately excluded from the pre-authorized tool set so clients prompt on
  each call.

MCP responses use an agent-facing DTO and **do not** encode `excludedAgents` —
the denylist is admin metadata for the CLI/app, not for arbitrary MCP clients.

### Setup & registration

`localmem setup` registers `localmem-mcp` with every installed client by writing
the server's **absolute path** into each client's config
(`~/.claude.json`, `~/.codex/config.toml`, etc.). It also, unless opted out:

- Installs agent instruction files (`~/.localmem/AGENTS.md` and per-agent
  imports).
- **Pre-authorizes** Localmem's non-destructive tools so clients don't prompt on
  every call.

Setup is **idempotent** ("whoever ran setup last wins") and registers its own
sibling `localmem-mcp`. Supported clients: **Claude Code, Claude Desktop, Cursor,
Codex, Antigravity.**

## 8. Per-memory agent access control

Let the user decide, **per memory, which agents may see it**. Not every agent
should be trusted with every personal fact. This is an **organizational
boundary, not a security wall** (see Non-goals).

### Settled decisions

| Decision | Choice |
|---|---|
| Granularity | Per **memory**, per **agent** (not tiers, not categories) |
| Default | **Open** — every agent has access unless excluded |
| Storage shape | **Denylist** — persist only the *exclusions*, never the grants |
| Enforcement surface | **MCP only** — CLI and app are admin surfaces and bypass |
| Edit points | At create and update, via checkboxes (all ticked by default) |
| Identity | Self-declared `actor_id`; not hardened |

**Why denylist, not allowlist.** "Default open" must keep its promise when a
*new* agent appears after a memory was written. Storing the allowed set would
freeze the roster as of write time and silently exclude any agent wired up later.
Storing only exclusions means the empty set is "everyone, including future
agents," and unticking a box records an exception. It is also strictly less data.

### Non-goals

- **Not a security boundary.** Agent identity is the self-declared `actor_id`
  (from `clientInfo` during MCP `initialize`, falling back to
  `LOCALMEM_CLIENT_ID`; see `MCPClientIdentity`). A misbehaving agent can claim
  another's name. Hardening identity (per-client tokens at registration) is a
  possible later, separate effort.
- **No per-operation granularity.** Exclusion is binary — an excluded agent sees
  the memory in neither read nor search. Read-only vs. read-write per memory is
  not modeled.
- **No multi-user / auth.** Localmem stays single-user and local.

### Agent roster

The checkbox roster reuses the same agent universe that powers the connection-
status UI:

- **Universe:** the `KnownAgents` catalog — Claude Code, Claude Desktop, Cursor,
  Codex, Antigravity. Each entry's `id` is the canonical `actor_id`.
  `KnownAgents` should live in `LocalmemCore` so IDs stay canonical across CLI,
  MCP, and app.
- **Liveness:** derived from `ActivityStore` — an agent is "connected" when its
  newest activity row is within a 300s window. Shown only as an affordance
  ("● connected"); it does not affect editability.

Agents that have acted but aren't in `KnownAgents` keep default-open access until
the catalog (or an "observed unknown agents" UI) grows to cover them.

### Enforcement seam

The read methods on `MemoryStore` — `search`, `recent`, `get`, `findIDs` — take
an optional caller identity:

```swift
func search(query: String, limit: Int = 20,
            requestingAgent: String? = nil) async throws -> [Memory]
```

- `requestingAgent == nil` → **no filtering** (CLI/app admin bypass).
- `requestingAgent == "<id>"` → exclude any memory with a matching row in
  `memory_agent_exclusions`, via a `NOT EXISTS` / anti-join in SQL (filtering in
  the query, not in Swift).

| Caller | `requestingAgent` |
|---|---|
| MCP `memory_search` / `memory_recent` / `memory_update` readback | `await identity.name` |
| CLI commands | `nil` (bypass) |
| App view models | `nil` (bypass) |

`memory_update` reads the existing memory through the **filtered** path before
writing, so an excluded agent cannot edit what it cannot see;
`get(id:requestingAgent:)` returns `nil` for an excluded agent so update-by-id
can't peek around the filter. After writing, the store returns the updated row
from inside the write transaction without re-applying the read filter.

## 9. CLI

The `localmem` command is the pro-user and debugging surface. It shares
`LocalmemCore`, so its behavior matches the app and MCP server exactly, and it
**bypasses** access filtering (it is an admin surface).

| Command | Description |
|---|---|
| `localmem setup` | Register the MCP server with all installed clients |
| `localmem add` | Add a memory |
| `localmem search` | Full-text search |
| `localmem list` | List recent memories |
| `localmem show` | Show a single memory |
| `localmem update` | Edit a memory |
| `localmem delete` | Remove a memory |
| `localmem status` | Store and registration status |
| `localmem path` | Print the database path |

## 10. File connector

Import memories from files the user deliberately picks — implemented; this
section is the source of truth (it absorbed `File_Connector_Design.md`).
Planned successors live in their own design docs:
[Extraction_Quality_Design.md](Extraction_Quality_Design.md) (two-pass
extract → verify) and
[Obsidian_Connector_Design.md](Obsidian_Connector_Design.md).

### Model

**Deliberate multi-file import, non-blocking, no approval gate.**

- **One source per file.** The open panel is multi-select, files only
  (Text/Markdown/PDF). No folder walking, no watching, no sync — nothing is
  ever processed without an explicit user gesture (import, per-file
  Reprocess). Re-picking an imported file reprocesses it instead of
  duplicating it.
- **No approval gate.** Extracted memories store directly (`source =
  "import"`, default-open access); curation happens afterwards in the detail
  view (per-memory delete). Extraction quality is carried by the pipeline —
  see the extraction-quality design.
- **Non-blocking.** Imports queue through a cancellable 2-wide background
  runner (`ConnectorsViewModel`); the UI stays interactive with live
  per-file status. Stop drops queued files; the in-flight file finishes.

### Extraction backends

Ladder: **Apple Foundation Models (on-device, preferred) → a CLI-capable
configured agent (Claude Code, Codex) → unavailable.** Localmem never calls a
model API or holds a key. The backend is chosen *before* file selection (with
disclosure when an agent backend reads the files); there is **no silent
fallback** from on-device to agent. Agent invocations are headless and
injection-hardened: imported text is untrusted, so the CLI runs as a pure
text→text call with tools disabled and MCP config stripped
(`AgentCLIExtractor`).

### Engine & reconciliation

`ExtractionEngine.process(source:extractor:force:)` handles one file:
read → hash-based change detection (unchanged files skip extraction unless
forced) → extract → deterministic `BoilerplateFilter` + within-file dedup →
**replace-all for that file in a single audited transaction**
(`SourceStore.replaceMemories`). Per-file limits (20 MB pre-read size gate,
~1 MB text, 200 facts, 180 s timeout) and every skip/failure end in a
`status` + plain-language reason (`missing`, `unsupported`, `too_large`,
`no_text`, `timeout`, …) — nothing fails silently.

### Schema

`sources` (one row per imported file: path, bookmark, backend, last_run_at),
`source_files` (per-file hash/mtime/status/reason for change detection), and
`source_memories` (file → memory links that make replace-all possible), with
`ON DELETE CASCADE` throughout. Created by `v3_sources`;
`v4_sources_drop_legacy_columns` drops the folder-era columns
(kind/auto_process/status) from databases that ran the original v3 — the
lesson: **never edit an applied migration in place.**

### UI

The Connectors section is a catalog page (available card: Files, with
Import…/Manage; coming-soon cards: Apple Notes, Obsidian, Notion). Import
lands directly in the **in-window split-pane detail view** — flat file list
left (live `○ → ⟳ → ✓` status, fact counts, `Add files…`), per-file detail
right (status/reason, its memories with per-memory delete, **Reprocess** and
**Remove** with a keep/delete-memories confirm). Modality budget: the open
panel, a one-shot backend choice (only when >1 backend is available), and
destructive confirms — no wizards, no stacked sheets.

## 11. macOS app UI

Native macOS app, SwiftUI, links `LocalmemCore`. Apple-native design language —
system primitives, SF Pro, 8pt grid, system accent + neutral grays, first-class
dark mode, SwiftUI-default motion only.

### Window anatomy

Three resizable panes (persisted across launches), one toolbar, one status bar:

```
┌──────────────────────────────────────────────────────────────────────┐
│ ⚙︎  Localmem              [ 🔎 Search memories… ]              [ + ]  │  toolbar
├──────────────────────┬───────────────────────────────────────────────┤
│  🔎 Search…          │   Coffee preference                           │
│  Tags [all ▾]        │   ● You · preference · 3 days ago · updated…  │
│  ● Coffee preference │   Flat white with oat milk.                   │
│  ◐ Activity log path │   #preferences #drinks                        │
│  ● Modern frameworks │   [ Edit ] [ Delete ] [ Audit trail ]         │
├──────────────────────┴───────────────────────────────────────────────┤
│ ● Connected: claude-code, cursor   last access 2s ago   47 memories ▴ │  status bar
└──────────────────────────────────────────────────────────────────────┘
```

### First-run setup wizard

Triggered when `~/.localmem/db.sqlite` is missing (or the store is empty and no
clients are configured). Modal, dismissible only by Quit or Finish. Five steps
(Back / Continue), **re-runnable** from Settings → General:

1. **Welcome** — pitch + "Get started."
2. **Choose data location** — default `~/.localmem`; custom path picker; note that
   the directory is user-level and not synced unless the user places it in iCloud
   Drive themselves.
3. **Connect your agents** — auto-detects installed clients; each row has a
   checkbox + status (`Detected` / `Not installed` / `Already configured`);
   Continue writes each ticked client's MCP config.
4. **Test it works** — writes a seed memory and live-tails activity; the step
   turns green on a successful `memory_store`. Retry/Skip if no connection in 5s.
5. **You're set** — summary of location, clients, test result.

### Sidebar (240pt)

Search field (Cmd-F, live FTS), horizontally scrollable tag chips (`[all ▾]`
multi-select placeholder), and a tight memory list — title + source dot (§ below)
+ optional type line, no preview text. Untitled memories fall back to the first
~40 chars of content, italicized. Right-click: Open / Edit / Duplicate / Copy ID
/ Delete. ⌘-click multi-select for bulk delete.

### Detail pane

Selected memory: inline-editable title (double-click); metadata strip
(`● Source · type · created · updated`, hover for absolute times); wrapping
content (click-to-focus, saves on blur or ⌘S); tag chips (`+` to add, Backspace
removes last); action bar (`Edit`, `Delete` with confirm, `Audit trail`, and
`Access…`). Empty state prompts ⌘N.

**Audit trail** slides in a 320pt right inspector, grouping `ActivityStore` rows
for the memory by day, with **Export CSV** and a confirm-gated **Clear log**
(scoped to that memory).

### Add / edit memory sheet

Modal (~560×480). Fields: Title, Type (dropdown), Content (Save disabled until
non-empty), Tags. **Agent access** disclosure row — "All agents" by default,
expands to a checklist of `KnownAgents` (all ticked; unticking persists an
exclusion; "● connected" dot shows liveness). Copy: *"Unchecked agents can't see
this memory over MCP. You (CLI and this app) always can."* Source is hard-coded
to `.user` for GUI writes. Esc cancels, ⌘S saves.

### Source color coding

`source` maps deterministically to a dot color via a single `SourcePalette`
(GUI target): `.user` → blue; `claude-*` → orange; `cursor` → purple;
`chatgpt`/`codex` → green; other clients → gray; unknown/null → hollow gray ring.
Unknown sources hash to one of three muted neutrals. The same color language is
reused in the audit trail and status bar.

### Status bar & popover

Always-visible 28pt bar: health dot (green/yellow/red), connected clients (capped
at 3 + `+N`, each in its source color), relative last-access (ticks every
second), total memory count, and a `▴` that opens a popover with daemon health,
DB path/size, connected clients, the last 10 activity rows, and
Restart-daemon / Open-logs actions.

### Settings

Tabs: **General** (launch at login, menu bar, theme, re-run setup), **Access
control** (roster/overrides view), **Data** (DB path, Finder, disk usage, export
JSON, import, vacuum), **Clients** (the auto-detect grid, re-runnable; per-client
status, last access, Disconnect / Reconfigure), **About** (version, GitHub,
feedback).

### Keyboard shortcuts

⌘N new · ⌘F focus search · ⌘⌫ delete (confirm) · ⌘S save · ⌘, settings ·
⌘1 toggle sidebar · ⌘2 toggle audit inspector.

### Reconciliation note

An earlier **UI-only** access prototype (`MemoryCategory`,
`AccessLevel = noAccess/askFirst/readOnly/readWrite`, an `AccessRulesView`
category×agent matrix) modeled category-level, 4-state rules and is **not
compatible** with the per-memory binary denylist (§8). Resolution: adopt the
denylist as the real model, retire `MemoryCategory`/`AccessLevel`, and repurpose
the Access Rules page as a **roster view** rather than a rules editor. Keep the
`AgentSnapshot` / `KnownAgents` / connection-status plumbing — it's reused for the
checkbox roster.

## 12. Distribution & packaging

Two audiences: **terminal/power users** who want just the CLI (installed like any
dev tool), and **app users** who download the GUI (which carries the CLI with it).
macOS-only — no Windows/Linux installer is in scope.

### Constraints that dictate the design

1. **The MCP server needs a stable, absolute path.** Setup writes the absolute
   path of `localmem-mcp` into each client's config; if it moves, clients silently
   break. The three binaries must stay co-located, and the registered path must
   survive updates. `BinaryLocator` handles the two co-location shapes this
   creates: when both binaries sit in the same dir (dev build, or a Homebrew
   prefix where `localmem` *and* `localmem-mcp` are both symlinked) it registers
   the unresolved sibling — the stable, non-versioned path; when only `localmem`
   is symlinked (the app-installed CLI) it follows the symlink into the bundle to
   find `localmem-mcp`. Both paths are update-stable.
2. **Everything must be code-signed and notarized.** Any binary outside the Mac
   App Store is Gatekeeper-checked; without a Developer ID signature +
   notarization users see "Localmem is damaged." Cost: Apple Developer Program
   ($99/yr) + a notarization step in CI.
3. **The Mac App Store is ruled out.** Localmem edits *other apps'* config files
   and shells out to their CLIs — the sandbox forbids this.
4. **The GUI ships as a signed `.app` bundle.** `localmem-app` is a plain SwiftPM
   executable, so [`packaging/build-dmg.sh`](../packaging/build-dmg.sh) wraps it
   into `Localmem.app` (using [`packaging/Info.plist`](../packaging/Info.plist)),
   co-locating all three binaries plus the SwiftPM resource bundles in
   `Contents/MacOS/`, then signs, notarizes, and produces the DMG.

### v1 shape (implemented)

v1 ships a single channel — the **notarized DMG** — and defers the CLI channels:

- **App:** notarized **DMG** (drag to `/Applications`), built by
  [`packaging/build-dmg.sh`](../packaging/build-dmg.sh). The app bundles the CLI
  and, from the setup wizard, offers to symlink `localmem` into `/usr/local/bin`
  (`CLIToolInstaller`, the VS Code / Ollama pattern; falls back to an
  administrator prompt via osascript when `/usr/local/bin` isn't user-writable).
- **Updates:** **re-download** — the user drags a new DMG over the old app.
  Because the app stays at `/Applications/Localmem.app`, the `localmem-mcp` path
  baked into client configs is unchanged, so registrations survive.
- **Deferred:** Homebrew formula + curl script (CLI-only channels), a Homebrew
  Cask, a ZIP artifact, and Sparkle auto-updates — see the target shape below.

**Update safety.** User data is never inside the bundle: memories live in
`~/Library/Application Support/Localmem/`, instruction files in `~/.localmem/`,
and client configs in each client's own file. An install or update only ever
replaces the binaries under `Localmem.app`, so memories and configs are preserved
by construction.

### Target shape (later releases)

Ship both families of channels — they're different artifacts for different
audiences:

- **CLI:** Homebrew formula (primary) **+** curl script (fallback). Both install
  `localmem` + `localmem-mcp`.
- **App:** the DMG **+** a ZIP for Sparkle, **and** a Homebrew **Cask**.
- **Updates:** **Sparkle** for the app (appcast XML hosted at
  `localmem.ai/appcast.xml`, EdDSA-signed releases; in-place swap keeps the
  `/Applications` path stable); `brew upgrade` / re-run curl for the CLI.
- **Skip the PKG** unless the website installer specifically needs to configure
  the CLI without the app touching `/usr/local/bin`.

**Version skew** (a bundled CLI vs. a separate Homebrew CLI) is mitigated by
setup being idempotent and the app's status view flagging + repairing a stale
registration.

### Website & release pipeline

The marketing site lives in its own repo,
[`localmemai/localmem-web`](https://github.com/localmemai/localmem-web) (a
single static `index.html`, deployed on Vercel) — it is no longer vendored in
this repo. The site serves the download button (DMG), the install command,
`install.sh`, the Sparkle appcast, the release artifacts, and docs. This implies a CI release
pipeline: build the three binaries (universal arm64 + x86_64) → assemble the
signed `.app` → sign + notarize → produce DMG + ZIP → upload artifacts → update
the appcast + Homebrew formula/cask.

### Prerequisites & costs

Apple Developer Program ($99/yr); notarization in CI (`.app` bundling is scripted
in [`packaging/build-dmg.sh`](../packaging/build-dmg.sh)); universal binaries; an
EdDSA key for Sparkle; a Homebrew tap (unless going into homebrew-core).

## 13. Roadmap

- **v0.2** — macOS vault app (SwiftUI), local storage, MCP adapter, per-memory
  access control, file connector (§10).
- **v0.3** — extraction quality: two-pass extract → verify + eval harness
  ([design](Extraction_Quality_Design.md)); Obsidian connector
  ([design](Obsidian_Connector_Design.md)); signed/notarized distribution
  (DMG + Homebrew), Sparkle updates.
- **v0.4** — optional CloudKit **encrypted** sync; iPhone companion
  (browse/search/capture); review/approval flows; improved tagging and
  organization.
- **v1.0** — additional connectors (Apple Notes, Notion) and agent adapters;
  stronger retrieval and ranking.

### Out of scope (for now)

Windows/Linux; Mac App Store (sandbox-incompatible); enterprise MDM; multi-user /
auth; hardened agent identity; semantic / vector retrieval; memory version
history beyond the audit log.

## 14. Open questions

1. **Search-index confidentiality** — encrypted FTS index, in-memory rebuild on
   unlock, or documented-tradeoff plaintext index?
2. **Filtered-result signaling** — should `memory_search` / `memory_recent`
   signal that results were hidden by access rules ("3 memories hidden"), or stay
   silent? (Silent is simpler and matches "organizational boundary.")
3. **Daemon ownership** — should the GUI manage `localmem-mcp` via a LaunchAgent
   (so "quit the app, daemon stops"), or assume the wizard configured it?
4. **Source-string normalization** — a canonical `KnownClient` enum in
   `LocalmemCore` so CLI, MCP, and GUI agree on source strings.
5. **Audit-log retention** — unbounded, or a Data-tab setting (30d / 90d /
   forever)?
6. **Distribution specifics** — primary CLI channel (brew vs. curl vs. both);
   DMG vs. ZIP; Homebrew cask yes/no; commit to Sparkle for v1 or ship
   re-download-only; where release artifacts live (GitHub Releases vs. own CDN).
