# Per-Memory Agent Access Control — Design

Status: Proposed · Author: design discussion 2026-06-13 · Scope: LocalmemCore + MCP + app

## Goal

Let the user decide, per memory, which agents may see it. Not every agent should
be trusted with every personal fact. The user grants or revokes access with
checkboxes when creating or editing a memory; Localmem honors that at MCP call
time.

This is an **organizational boundary, not a security wall** (see Non-goals).

## Decisions (settled)

| Decision | Choice |
|---|---|
| Granularity | Per **memory**, per **agent** (not tiers, not categories) |
| Default | **Open** — every agent has access unless excluded |
| Storage shape | **Denylist** — persist only the *exclusions*, never the grants |
| Enforcement surface | **MCP only** — CLI is the admin surface and bypasses |
| Edit points | At create and at update, via checkboxes (all ticked by default) |
| Identity | Self-declared `actor_id`; not hardened |

### Why denylist, not allowlist

"Default open" must keep its promise when a *new* agent appears after a memory
was written. If we stored the allowed set, a memory created today would freeze
the agent roster as of today and silently exclude any agent wired up later. By
storing only exclusions, the empty set means "everyone, including future
agents," and unticking a box simply records an exception. It is also strictly
less data — we persist only the deviations from the default.

## Non-goals

- **Not a security boundary.** Agent identity is the self-declared `actor_id`
  (from `clientInfo` during MCP `initialize`, falling back to
  `LOCALMEM_CLIENT_ID`; see `MCPClientIdentity`). A misbehaving agent can claim
  another agent's name and read what it shouldn't. We accept this. Hardening
  identity (per-client tokens at registration) is a possible later, separate
  effort and is out of scope here.
- **No per-operation granularity.** Exclusion is binary: an excluded agent sees
  the memory in neither read nor search. We are *not* modeling read-only vs.
  read-write per memory (that's what the prototype matrix did — see
  Reconciliation).
- **No multi-user / auth.** Localmem stays single-user and local.

## Where "the agents" come from

The checkbox roster reuses the **same agent universe that powers the connection-
status UI** — there is no separate presence store to build against:

- **Universe:** the hardcoded `KnownAgents` catalog
  (`Sources/localmem-app/LocalmemApp.swift`) — Claude Code, Claude Desktop,
  Cursor, Codex, Antigravity. Each entry's `id` is the canonical `actor_id`.
- **Liveness:** derived from `ActivityStore`. `VaultStatusViewModel.refresh()`
  takes the distinct `actor_id` set from recent activity; an agent is
  "connected" when its newest activity row is within a 300s window.

For the access checkboxes we want a **stable** list (you must be able to exclude
an agent before it has ever written a memory), so the roster is driven by
`KnownAgents`, with connection state shown only as an affordance ("● connected"
next to the row). Agents that have acted but aren't in `KnownAgents` are not
individually excludable yet; under denylist semantics they keep default-open
access until the catalog is updated or the UI grows an "observed unknown agents"
section.

> **Action:** lift `KnownAgents` out of the app target into `LocalmemCore` so the
> roster has one source of truth. Enforcement itself does **not** need the
> catalog — it only checks "is my `actor_id` in this memory's exclusion set" —
> but sharing the catalog keeps IDs canonical across CLI, MCP, and app.

## Data model

New table. While Localmem is in development we don't add migrations — the table
goes **inside the existing `v1_initial` block** in `Migrations.swift` (delete the
local dev database and it's recreated fresh). It sits alongside `memory_tags`:

```sql
CREATE TABLE memory_agent_exclusions (
    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    agent_id  TEXT NOT NULL,
    PRIMARY KEY (memory_id, agent_id)
);
CREATE INDEX idx_excl_agent ON memory_agent_exclusions(agent_id);
```

- `ON DELETE CASCADE` mirrors `memory_tags`: deleting a memory drops its rows.
- An empty set for a memory = visible to all agents.
- Rows are written/replaced inside the same write transaction as the memory
  (same pattern `MemoryStore.add`/`update` already use for tags).

The `Memory` struct gains `var excludedAgents: [String]` (or `Set<String>`),
populated on read the way `tags` already are via the batched `attachTags`
helper — add a parallel `attachExclusions`, or fold both into one pass.

## Enforcement seam

The read methods on `MemoryStore` — `search`, `recent`, `get`, `findIDs` — gain
an optional caller identity:

```swift
func search(query: String, limit: Int = 20, requestingAgent: String? = nil) async throws -> [Memory]
```

- `requestingAgent == nil` → **no filtering** (CLI / app admin path). This is the
  bypass: CLI handlers in `Sources/localmem/Commands/*` and the app's view models
  pass nil.
- `requestingAgent == "<id>"` → exclude any memory that has a matching row in
  `memory_agent_exclusions`. Implemented as a `NOT EXISTS` / anti-join in SQL so
  filtering happens in the query, not in Swift. For FTS search, this filter must
  run before `ORDER BY rank LIMIT ?` so hidden rows do not consume result slots.

The MCP handlers already have the caller identity in hand: every handler in
`ToolRegistry` calls the store with `actorID: await identity.name`. The same
value gets threaded as `requestingAgent`. So the wiring is:

| Caller | `requestingAgent` |
|---|---|
| MCP `memory_search` / `memory_recent` / `memory_update` readback | `await identity.name` |
| CLI commands | `nil` (bypass) |
| App view models | `nil` (bypass) |

`memory_store` is unaffected at read time. `memory_update` reads the existing
memory through the filtered path before writing, so an excluded agent cannot edit
what it cannot see; after writing, the store returns the updated row from inside
the write transaction without applying the read filter.

MCP responses use an agent-facing DTO and do not encode `excludedAgents`; the
denylist is admin metadata visible to the CLI/app, not to arbitrary MCP clients.

### Edge: an excluded agent fetches by id

`get(id:requestingAgent:)` must return `nil` (not the row) when the agent is
excluded, so `memory_update` by id can't peek around the filter. `memory_update`
from an MCP agent therefore cannot edit a memory it's excluded from —
acceptable; the CLI/app can.

## UI

### Create / edit memory sheet

- A disclosure row: **"Agent access"** showing "All agents" by default.
- Expands to a checklist of `KnownAgents`, all ticked. Unticking persists an
  exclusion. A "● connected" dot shows liveness but does not affect editability.
- Copy: *"Unchecked agents can't see this memory over MCP. You (CLI and this app)
  always can."*

### Reconciliation with the existing prototype

The app already ships a **different, UI-only** access prototype that predates
this design and must be reconciled:

- `MemoryCategory` (`preferences / projects / personal / private`) — *distinct
  from* the real `MemoryType` (`fact / preference / decision / project / note`).
- `AccessLevel` (`noAccess / askFirst / readOnly / readWrite`).
- `AccessRulesView` — a category×agent matrix with `defaultLevel(...)` mock data,
  explicitly "Phase 10 — UI only," no persistence.

That prototype models **category-level, 4-state** rules. Our design is
**per-memory, binary, denylist**. They are not compatible and we should not ship
both. Recommendation:

1. **Adopt** the per-memory denylist as the real, persisted model.
2. **Retire** `MemoryCategory` and `AccessLevel`; repurpose the Access Rules page
   as a *roster view* rather than a rules editor.
3. Keep `AgentSnapshot` / `KnownAgents` / connection-status plumbing — that's
   reused as-is for the checkbox roster.

This removes the category-level prototype from the product surface; everything
else follows the settled decisions.

## Work breakdown

1. **Core:** migration for `memory_agent_exclusions`; `Memory.excludedAgents`;
   read/write of exclusions in `MemoryStore.add`/`update`; `attachExclusions`.
2. **Core:** `requestingAgent` param + anti-join filter on `search`/`recent`/
   `get`/`findIDs`; CLI/app pass nil, MCP passes identity.
3. **Shared:** lift `KnownAgents` into `LocalmemCore`.
4. **MCP:** thread `identity.name` as `requestingAgent`; document the visibility
   rule in the tool descriptions (an agent only sees memories it isn't excluded
   from).
5. **App:** access checklist in the create/edit sheet; repurpose
   `AccessRulesView` as the roster page.
6. **Tests:** exclusion round-trips; MCP-filtered vs. CLI-unfiltered reads;
   get-by-id denial; cascade on delete; default-open for unknown/new agents.

## Open questions

- Does `memory_recent`/`memory_search` need to *signal* that results were
  filtered (e.g. "3 memories hidden by access rules"), or stay silent? Silent is
  simpler and matches "organizational boundary."
