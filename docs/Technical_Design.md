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
8. [Folders and agent visibility](#8-folders-and-agent-visibility)
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
  deployment target macOS 14. Features that need newer frameworks
  (FoundationModels / Apple Intelligence extraction) are gated at runtime and
  degrade to a CLI-agent backend rather than raising the floor.
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
    public var folderID: UUID             // see §8; defaults to Inbox
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
    -- Fixed sentinel = Inbox, so a stale binary that knows nothing about
    -- folders still writes valid rows instead of violating NOT NULL.
    folder_id TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'
        REFERENCES folders(id) ON DELETE SET DEFAULT,
    session_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE memory_tags (
    memory_id TEXT NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY (memory_id, tag),
    FOREIGN KEY (memory_id) REFERENCES memories(id) ON DELETE CASCADE
);

CREATE TABLE folders (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    kind         TEXT NOT NULL,   -- default | project | source | manual
    project_root TEXT,            -- git root, for kind='project'
    sensitive    INTEGER NOT NULL DEFAULT 0,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_folders_root ON folders(project_root)
    WHERE project_root IS NOT NULL;

CREATE TABLE agents (
    id         TEXT PRIMARY KEY,  -- canonical actor_id
    status     TEXT NOT NULL DEFAULT 'all',  -- all | non_sensitive_only
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE memories_fts USING fts5(
    title,
    content_plaintext,
    content='',
    tokenize='unicode61'
);
```

Tags are written/replaced inside the same write transaction as the memory and
populated on read via a batched attach helper. `ON DELETE CASCADE` drops a
memory's tag rows with it. Deleting a folder reassigns its memories to `Inbox`
rather than deleting them.

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

### Network posture

The product promise is about *plaintext*, not about a literal zero-packet app —
but the difference is only credible if the exceptions are enumerated. This is the
complete list of outbound connections the app, CLI, and MCP server make:

| Connection | Made by | Sends | Cadence |
|---|---|---|---|
| Update check — `api.github.com/repos/localmemai/localmem-app/releases/latest` | App only | Nothing but the HTTPS request itself (GitHub sees IP + user agent) | ≤ once per 24h, on launch |

That's the whole table. No memory content, no counts, no folder or agent names,
no identifiers of any kind leave the machine, and the CLI and MCP server make no
network calls at all. **Any new entry belongs in this table before it ships** —
if a change can't be written as a row here, it's a change to the product promise
and needs to be argued as one.

A version check is a question, not a report: it transmits nothing about the user
that isn't inherent to opening a TCP connection, and the IP it discloses to
GitHub is the same one that downloaded the DMG. This is the settled norm for
privacy-positioned apps rather than a compromise unique to us — Obsidian checks
by default and documents the off switch in Settings → About; Cryptomator's
privacy policy discloses that its check sends OS version, app version, time, and
IP; Signal auto-updates with no opt-out at all. Users who want zero connections
have a real answer: the toggle (see §12), and the CLI, which never checks.

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

The MCP server exposes five tools. Every handler attributes the call to an agent
via `MCPClientIdentity` and threads that identity into the store for filtering
and audit logging.

- `memory_store` — persist a new fact, preference, or decision. Optional `supersedes` parameter versions older entries.
- `memory_search` — full-text search over stored memories, ranked by relevance
  (FTS5 BM25). Returns compact metadata (omits the verbatim `content` body).
  Superseded memories are hidden by default; `includeSuperseded` surfaces them
  de-ranked below live results.
- `memory_recent` — most-recent-first listing. Returns compact metadata (omits
  the verbatim `content` body). Same `includeSuperseded` behavior as search.
- `memory_get` — retrieves the full verbatim body for a set of memory IDs, in
  request order, each carrying its `supersededBy` / `supersedes` edges so an
  agent can walk the history chain. Ids that are unknown or access-blocked are
  reported back in `missingIds` rather than silently dropped.
- `memory_update` — replace fields on an existing memory, including its
  `supersedes` edges (omit to keep, `[]` to clear). **Destructive**;
  deliberately excluded from the pre-authorized tool set so clients prompt on
  each call.

MCP responses use an agent-facing DTO and **do not** encode folder identity or
sensitivity — that is admin metadata for the CLI/app, not for arbitrary MCP
clients. What a restricted agent does get is the `accessNote` (§8): the fact that
results were withheld, without the shape of what was withheld.

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

## 8. Folders and agent visibility

Every memory belongs to **exactly one folder**. The folder decides which agents
may read it. Everything defaults open, so the feature is invisible until a user
marks a folder.

This is an **organizational boundary, not a security wall** (see Non-goals).

### The whole rule

A folder is **sensitive** or **not sensitive** (default). An agent is **all**
(default) or **non-sensitive only**. An agent set to non-sensitive only skips
sensitive folders. Nothing else.

Because visibility lives on the folder, a memory carries no visibility state of
its own. Moving a memory between folders *is* how it is reclassified, and moving
a selection is how you reclassify in bulk — so there is no per-memory override
and no inherited-versus-explicit distinction to reconcile.

### Settled decisions

| Decision | Choice |
|---|---|
| Granularity | Per **folder**, per **agent status** (not per memory) |
| Hierarchy | **Flat** — no nesting |
| Membership | Every memory in exactly one folder; no unfiled state |
| Default folder | `Inbox`, at a fixed sentinel UUID; permanently not sensitive, cannot be renamed or deleted |
| Defaults | Folders not sensitive; agents `all`, including agents installed later |
| Enforcement surface | **MCP only** — CLI and app are admin surfaces and bypass |
| Identity | Self-declared `actor_id`; not hardened |

**Why this replaced per-memory denylists.** The previous design stored one
exclusion per memory per agent. That cost one decision per memory per agent — a
cost that grows with the product's own success, which is why the feature went
unused. Folders collapse it to one decision per folder, applying to memories that
do not exist yet.

**Why `Inbox` is immutable.** It guarantees a safe home always exists and that a
user cannot accidentally hide their entire vault. Its controls are disabled in
the UI rather than hidden — a missing control reads as a bug — with the reason
stated and an exit ("move them to another folder").

**Why new agents default to `all`.** The reverse produces a worse failure: a
newly installed tool that silently retrieves nothing, with no visible cause.
An unknown `actor_id` resolves to `all` without needing a registration step.

### How memories reach a folder

| Origin | Folder |
|---|---|
| Agent writing in a project | The project's folder, keyed on **git root path** (not repo name, or `~/work/acme/api` and `~/personal/api` collide). Created on first write. |
| Agent with no project | `Inbox` |
| Document import | A folder named after the source's **parent directory** — `sources` holds one row per file, so grouping per source would turn a 60-file import into 60 folders |
| Manual entry (app/CLI) | User picks; defaults to `Inbox` |

Auto-created folders are always **not sensitive**. Nothing prompts, blocks, or
infers sensitivity from content.

### Non-goals

- **Not a security boundary.** Agent identity is the self-declared `actor_id`
  (from `clientInfo` during MCP `initialize`, falling back to
  `LOCALMEM_CLIENT_ID`; see `MCPClientIdentity`). A misbehaving agent can claim
  another's name. The honest promise is *"restricted agents stay in their
  lane"* — it stops a trusted but overbroad tool from surfacing memories, and is
  not a defence against a malicious local process. Neither UI copy nor
  documentation should imply otherwise. Hardening identity (a per-client secret
  provisioned at setup and verified server-side) is a possible later, separate
  effort; `localmem setup` already writes and merges keys into each client's MCP
  config block, so the mechanism exists.
- **Grouping does not scope retrieval by default.** It scopes retrieval only
  where the user has explicitly marked a folder sensitive *and* explicitly
  restricted an agent. Both are deliberate acts; either alone changes nothing.
  Scoping by *project context* was considered and cut — it fragments the
  cross-project recall that is the product's core thesis. Sensitivity is
  orthogonal to project: an agent set to `all` retains complete cross-project
  recall no matter how many folders exist.
- **No per-operation granularity.** Visibility is binary — a hidden memory is
  hidden in read and search alike.
- **No multi-user / auth.** Localmem stays single-user and local.

### Agent roster

The status list reuses the same agent universe that powers the connection-status
UI: the `KnownAgents` catalog in `LocalmemCore` — Claude Code, Claude Desktop,
Cursor, Codex, Antigravity — whose `id` is the canonical `actor_id`. Liveness
comes from `ActivityStore` (newest activity row within a 300s window) and is an
affordance only; it does not affect editability.

### Enforcement seam

The read methods on `MemoryStore` — `search`, `recent`, `get`, `get(ids:)`,
`findIDs` — take an optional caller identity:

```swift
func search(query: String, limit: Int = 20,
            requestingAgent: String? = nil) async throws
    -> (memories: [Memory], withheld: Int)
```

- `requestingAgent == nil` → **no filtering** (CLI/app admin bypass).
- `requestingAgent == "<id>"` → resolve the agent's status, then join `folders`
  and keep rows where `folders.sensitive = 0 OR status = 'all'` — filtering in
  the query, not in Swift.

| Caller | `requestingAgent` |
|---|---|
| MCP `memory_search` / `memory_recent` / `memory_get` / `memory_update` readback | `await identity.name` |
| CLI commands | `nil` (bypass) |
| App view models | `nil` (bypass) |

`memory_update` reads the existing memory through the **filtered** path before
writing, so a restricted agent cannot edit what it cannot see, and
`get(id:requestingAgent:)` returns `nil` so update-by-id can't peek around the
filter.

A restricted agent is still **told** that results were held back: the result
envelope carries an `accessNote`, and an `access_filtered` activity row records
the count. Silently returning less would teach the agent the fact does not exist
rather than that it cannot see it.

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
section is the source of truth (it absorbed `File_Connector_Design.md` and,
once implemented, `Extraction_Quality_Design.md`). Additional input connectors
(Obsidian, Apple Notes) were cut — see §13 Out of scope.

### Model

**Deliberate multi-file import, non-blocking, no approval gate.**

- **One source per file.** The open panel is multi-select, files only
  (Text/Markdown/PDF). No folder walking, no watching, no sync — nothing is
  ever processed without an explicit user gesture (import, per-file
  Reprocess). Re-picking an imported file reprocesses it instead of
  duplicating it.
- **No approval gate.** Extracted memories store directly (`source =
  "import"`, default-open access); curation happens afterwards in the detail
  view (per-memory delete). Extraction quality is carried by the two-pass
  pipeline below.
- **Non-blocking.** Imports queue through a cancellable 2-wide background
  runner (`ConnectorsViewModel`); the UI stays interactive with live
  per-file status. Stop drops queued files; the in-flight file finishes.

### Extraction backends

Ladder: **Apple Foundation Models (on-device, preferred) → a CLI-capable
configured agent (Claude Code, Codex) → unavailable.** Localmem never calls a
model API or holds a key. The backend is chosen *before* file selection (with
disclosure when an agent backend reads the files); there is **no silent
fallback** from on-device to agent. The extract and verify passes share the
same backend, always. Agent invocations are headless and injection-hardened:
imported text is untrusted, so the CLI runs as a pure text→text call with
tools disabled and MCP config stripped (`AgentCLIInvocation`, used by both
`AgentCLIExtractor` and `AgentCLIVerifier`). The backend implementations live
in `LocalmemCore/Backends.swift`, shared by the app and the eval harness.

### Engine & reconciliation

`ExtractionEngine.process(source:extractor:verifier:force:)` handles one
file: read → hash-based change detection (unchanged files skip extraction
unless forced) → **Pass 1 extract** (liberal) → deterministic
`BoilerplateFilter` + within-file dedup → **Pass 2 verify** (strict curator;
one batched call judging every candidate against the source text; verdicts
`keep | revise | drop`) → **replace-all for that file in a single audited
transaction** (`SourceStore.replaceMemories`). Nothing reaches the vault
without passing verification: a verify failure fails the file retriably
(`verify_timeout`, `verify_error`, `verify_invalid_output`), and the
"N extracted → M kept" counts persist per file for the detail pane. Per-file
limits (20 MB pre-read size gate, ~1 MB text, 200 facts, 180 s timeout per
pass) and every skip/failure end in a `status` + plain-language reason
(`missing`, `unsupported`, `too_large`, `no_text`, `timeout`, …) — nothing
fails silently. Prompt tuning is measured, not vibes: golden fixtures under
`Tests/LocalmemCoreTests/Fixtures/extraction/` and the hidden
`localmem eval-extraction` dev harness score junk-kept / good-lost /
duplicate rates for extract-only vs extract+verify.

### Extraction quality — the two-pass design (settled)

Why two passes: a single prompt is asked to do two opposing jobs —
extraction is a *generate* task (rewarded for output → over-extracts),
judgment is a *reject* task. Models judge candidates against criteria far
better than they avoid generating them, so the jobs are split. Two
load-bearing rules: **the verifier sees the source text** (grounding, not
just form) and **verifies the set in one batched call** (per-document
budget, duplicate detection, 1 extra invocation instead of N).

The verifier is a strict curator with five hard gates — grounded, durable,
owner-relevant (the owner *or their immediate world*), atomic &
self-contained, non-transactional — and a soft budget of 3–10 memories per
typical document. Verdict contract: `keep | revise | drop`, exactly one per
candidate index; `revise` returns the repaired fact (field-wise fallback to
the original) so a good fact with a bad title is fixed, not lost; `drop`
carries a one-line reason that is debug-logged, never persisted.

Settled decisions: same backend extracts and verifies (permanently — the
task-framing split is the whole mechanism, cross-backend verification was
rejected); verification is always on, no setting; partial/invalid verdict
output fails the whole file (`verify_invalid_output`, retriable) — no
silent per-candidate fallback; merge groups were cut from the contract (the
verifier `drop`s near-duplicates with a reason naming the kept candidate);
"N extracted" is the raw Pass-1 count, before deterministic filters;
revisions are trusted (no grounding re-check).

Remaining (v1.0.x/v1.1): on-device guided generation (`@Generable`) for
both passes + per-chunk verification with chunking; vault-level dedup;
recorded harness baselines.

### Schema

`sources` (one row per imported file: path, bookmark, backend, last_run_at),
`source_files` (per-file hash/mtime/status/reason for change detection, plus
nullable `extracted_count`/`kept_count` added by `v2_extraction_counts`), and
`source_memories` (file → memory links that make replace-all possible), with
`ON DELETE CASCADE` throughout. The base tables ship in the consolidated
`v1_initial`; every post-launch schema change is a new appended migration —
the standing lesson: **never edit an applied migration in place.**

### UI

The Connectors section is a catalog page (available card: Files, with
Import…/Manage; coming-soon cards: Apple Notes, Obsidian, Notion). Import
lands directly in the **in-window split-pane detail view** — flat file list
left (live `○ → ⟳ → ✓` status, fact counts, `Add files…`), per-file detail
right (status/reason, its memories with per-memory delete, **Reprocess** and
**Remove**, which deletes the file's imported memories with it after a
confirm — an imported memory without its file has no provenance, so there is
no keep-memories option). Modality budget: the open
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

### Memories navigator (300pt)

A Finder/VS Code style **tree**: folders at the top level, their memories nested
beneath, with a disclosure chevron that toggles independently of selection (so a
folder can be opened without navigating away from what is being read). `Inbox`
sorts first; the rest alphabetically.

Sensitivity is marked on the folder row itself — an orange lock rather than a
folder glyph — so a restricted folder reads at a glance without opening
settings. Every row carries a hover-revealed delete button whose space is
reserved, so rows do not reflow as the pointer crosses them.

Folder children are loaded **per folder on expand**, not filtered out of the
search/recent window — a folder outside that window would otherwise show a
correct count above an empty body. Selection and expansion persist across
launches, skipping folders that no longer exist.

While a search is active the tree mirrors the results: counts become match
counts and matching folders auto-expand, but every folder stays listed (dimmed
when it has no matches). Hiding rows outright makes a working filter look like
data loss. A completed import clears the search, since it would otherwise file
new memories behind a filter that hides them.

### Detail pane

Selected memory: inline-editable title (double-click); metadata strip
(`● Source · type · created · updated`, hover for absolute times); wrapping
content (click-to-focus, saves on blur or ⌘S); tag chips (`+` to add, Backspace
removes last); action bar (`Edit`, `Delete` with confirm, `Audit trail`). The
metadata strip leads with the memory's folder, orange when sensitive.

The action bar **flows with the content** rather than pinning to the pane's
bottom edge — a two-line memory in a tall window otherwise strands its buttons
far below the thing they act on. Empty state prompts ⌘N.

Selecting a folder instead of a memory shows **folder settings** in the same
pane: name, project path, and a "Who can read this" control. `Inbox`'s controls
are disabled rather than hidden, with the reason stated. Marking a folder
sensitive while no agent is restricted says so, rather than implying protection
that is not in effect.

**Audit trail** slides in a 320pt right inspector, grouping `ActivityStore` rows
for the memory by day, with **Export CSV** and a confirm-gated **Clear log**
(scoped to that memory).

### Add / edit memory sheet

Modal (~560×480). Fields: Title, Type (dropdown), Content (Save disabled until
non-empty), Tags, and **Folder** (defaults to the selected folder, else `Inbox`).
Visibility is not set here — it belongs to the folder, so moving a memory between
folders is how it is reclassified. Source is hard-coded to `.user` for GUI
writes. Esc cancels, ⌘S saves.

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

### Version & update cell (footer)

The shipped footer is a 52pt bar of five equal `StatusSegment` cells
(`LocalmemApp.swift`). The leftmost cell showed vault lock state — `Locked` /
`Unlocked` with `Touch ID required` / `Touch ID on` — which was the bar's weakest
cell twice over: the top toolbar already carries the lock *action*, and when the
vault is locked a full-window `LockScreen` covers the content area, so the cell
announced "Locked" beside a floor-to-ceiling lock screen. Nothing was learnable
there. It becomes the version and update cell.

Same `StatusSegment` shape, so no other cell moves. Three states:

| State | Glyph | Title | Detail |
|---|---|---|---|
| Idle | `checkmark.seal`, secondary | `Localmem 1.0.1` | `Up to date` |
| Checking | `checkmark.seal`, secondary | `Localmem 1.0.1` | `Checking…` |
| Update available | `arrow.down.circle.fill`, accent | `Update available` | `1.1.0 — Download` |

Only the third state is clickable. Bottom-left is where users already look for a
version string, and it makes bug reports legible without asking anyone to find an
About panel. Lock state is not replaced by anything: it was never information the
user lacked.

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

Two earlier access models were tried and retired. A **UI-only** prototype
(`MemoryCategory`, `AccessLevel = noAccess/askFirst/readOnly/readWrite`, a
category×agent matrix) modeled 4-state rules; the shipped v1 replaced it with a
per-memory binary denylist. Both were superseded by folders (§8) for the same
reason: their configuration cost scaled with the number of memories, so neither
survived a growing vault. `AgentSnapshot` / `KnownAgents` / connection-status
plumbing is kept — it backs the agent status list.

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
  baked into client configs is unchanged, so registrations survive. The app
  surfaces its version and tells the user when a newer one exists — see
  "Version display & update checking" below.
- **Deferred:** Homebrew formula + curl script (CLI-only channels), a Homebrew
  Cask, a ZIP artifact, and Sparkle auto-updates — see the target shape below.

**Update safety.** User data is never inside the bundle: memories live in
`~/Library/Application Support/Localmem/`, instruction files in `~/.localmem/`,
and client configs in each client's own file. An install or update only ever
replaces the binaries under `Localmem.app`, so memories and configs are preserved
by construction.

### Version display & update checking

**Where the version comes from.** `LocalmemVersion.current`
([`Sources/LocalmemCore/LocalmemVersion.swift`](../Sources/LocalmemCore/LocalmemVersion.swift)),
not `CFBundleShortVersionString`. The release workflow already fails the build
when the constant doesn't equal the `vX.Y.Z` tag, so the constant *is* the
released version — and unlike the Info.plist it exists in `swift run` dev builds,
which have no bundle at all. One string, already CI-enforced, already shared by
`localmem --version` and the MCP `initialize` response.

**The check (phase A — no new dependencies).** A `GET` against
`api.github.com/repos/localmemai/localmem-app/releases/latest`, reading
`tag_name`. Rules:

- **Cadence:** at most once per 24h, on launch. `lastCheckedAt` and
  `latestSeenVersion` persist in `UserDefaults`, so relaunching in a loop doesn't
  re-check and the footer can render the last known answer instantly.
- **Comparison is component-wise semver**, never string compare — `1.10.0` is
  newer than `1.9.0` and a lexical compare gets that backwards.
- **Failure is silent.** Offline, rate-limited, DNS-poisoned, GitHub down: the
  cell keeps showing the current version. An update check is not something the
  user asked for, so it never earns an error state in the chrome.
- **Unauthenticated rate limit** (60/hr/IP) is irrelevant at ≤1 request/day.
- **The click opens the releases page** in the browser. Phase A discovers
  updates; it does not install them. The user still drags the DMG over.
- **Toggle** in Settings → General, on by default, matching Obsidian. The README
  and the privacy copy state in one sentence what the check sends (§5).

**Phase B — Sparkle, for true in-place updates.** Three properties already make
the app safe to swap in place, and they were designed in for this: the bundle
lives at a fixed `/Applications/Localmem.app` so the `localmem-mcp` path baked
into client configs survives; user data lives outside the bundle; and builds are
Developer ID–signed, notarized, and stapled, which Sparkle requires. Sparkle 2
can update straight from the **DMG already published**, so no ZIP artifact is
needed. What phase B costs:

1. An **EdDSA key pair** (`generate_keys`); private half into repo secrets,
   public half into `SUPublicEDKey`.
2. **`appcast.xml` served from [`web/`](../web)** at `localmem.ai/appcast.xml` —
   the Vercel deployment already there — plus `SUFeedURL` in the Info.plist.
3. A **`sign_update` step** in [`release.yml`](../.github/workflows/release.yml)
   that signs the DMG and writes the signature into the appcast.
4. **`Sparkle.framework` folded into the inside-out signing** in
   [`build-dmg.sh`](../packaging/build-dmg.sh) — the only genuinely fiddly part,
   since the current script signs a flat list of binaries with no
   `Contents/Frameworks` to walk.

**Do not set `SUEnableAutomaticChecks`.** Left unset, Sparkle asks the user's
permission on *second* launch (first launch stays clean) and honors the answer.
That prompt is Sparkle's own default, it costs one dialog, and "we asked" is a
materially stronger claim for this product than "we defaulted it on."

**Known wrinkle:** an AI client may be running `localmem-mcp` out of the old
bundle when the swap happens. Replacing a bundle under a running process is safe
on macOS — the open inode survives — and the next spawn picks up the new binary,
so a long-lived agent session keeps the old MCP server until it restarts. No data
risk; worth knowing when triaging "I updated but the version didn't change."

**Phases are independently shippable.** The footer states don't change when
Sparkle lands — `Download` becomes `Install and Relaunch`. Landing phase B on its
own tag means verifying the signed-notarized-appcast path without simultaneously
debugging new UI.

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

The marketing site lives in this repo under [`web/`](../web) (a single static
`index.html`), deployed on Vercel with the project's Root Directory set to
`web` — pushes that don't touch `web/` skip deployment automatically. The
site serves the download button (the stable
`releases/latest/download/Localmem.dmg` URL) and will later serve the
install command, `install.sh`, and the Sparkle appcast.

The CI release pipeline is **implemented** in
[`.github/workflows/release.yml`](../.github/workflows/release.yml): pushing a
`v*` tag builds the universal binaries, assembles and signs the `.app` (via
`build-dmg.sh`), signs the DMG container, notarizes + staples, verifies the
Gatekeeper verdict, and publishes a GitHub Release with the versioned DMG, the
stable `Localmem.dmg` alias (the site's download URL), and checksums.
Credentials come from repo secrets (Developer ID `.p12` + App Store Connect
API key). Still deferred: ZIP artifact, Sparkle appcast update, Homebrew
formula/cask.

### Prerequisites & costs

Apple Developer Program ($99/yr); notarization in CI (`.app` bundling is scripted
in [`packaging/build-dmg.sh`](../packaging/build-dmg.sh)); universal binaries; an
EdDSA key for Sparkle; a Homebrew tap (unless going into homebrew-core).

## 13. Roadmap

- **v1.0 (shipped)** — macOS vault app (SwiftUI), local storage, MCP adapter,
  file connector (§10), signed + notarized DMG via the tag-triggered release
  pipeline (§12).
- **v2.0 (shipped)** — split retrieval (compact index + `memory_get`, BM25
  ranking); append-only supersession edges; two-pass extract → verify on the
  write path (§10); folders with per-folder agent visibility (§8); graceful
  degradation on older macOS.
- **next** — version + update-available cell in the footer and the once-daily
  release check (§12 phase A); vault-level dedup; folder merge/rename ergonomics
  as auto-created project folders accumulate; Homebrew channel and Sparkle
  in-place updates (§12 phase B).
- **later** — optional CloudKit **encrypted** sync; iPhone companion
  (browse/search/capture); additional connectors (Apple Notes, Notion) and
  agent adapters; stronger retrieval and ranking.

### Out of scope (for now)

Windows/Linux; Mac App Store (sandbox-incompatible); enterprise MDM; multi-user /
auth; hardened agent identity; semantic / vector retrieval; memory version
history beyond the audit log. Also cut: routing retrieval by working directory
(fragments cross-project recall — see §8 Non-goals); additional input surfaces
(Obsidian/Apple Notes connectors, global hotkeys, share sheets) — input is not
the constraint, retrieval is.

## 14. Open questions

1. **Search-index confidentiality** — encrypted FTS index, in-memory rebuild on
   unlock, or documented-tradeoff plaintext index?
2. **Daemon ownership** — should the GUI manage `localmem-mcp` via a LaunchAgent
   (so "quit the app, daemon stops"), or assume the wizard configured it?
3. **Source-string normalization** — a canonical `KnownClient` enum in
   `LocalmemCore` so CLI, MCP, and GUI agree on source strings.
4. **Audit-log retention** — unbounded, or a Data-tab setting (30d / 90d /
   forever)?
5. **Distribution specifics** — primary CLI channel (brew vs. curl vs. both);
   Homebrew cask yes/no; where release artifacts live (GitHub Releases vs. own
   CDN). *Settled:* DMG only (Sparkle 2 updates from it, so no ZIP), and Sparkle
   is committed as phase B rather than skipped — see §12.
6. **Update-feed host** — phase A checks GitHub's releases API, which keeps user
   IPs with GitHub. A `version.json` (or the Sparkle appcast) on `localmem.ai`
   would allow staged rollouts and a kill switch, but makes *us* the party seeing
   the IPs. Phase B forces the question, since the appcast must be hosted
   somewhere.
