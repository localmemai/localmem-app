# Localmem v2.0 — Technical Roadmap & Architecture Proposal

This document outlines the technical design, database schemas, and implementation strategy for **Localmem v2.0**. 

---

## Premise

v1 shipped a mechanism: local SQLite, an MCP adapter, per-memory access control, an audit log. The mechanism works. The evidence is the store itself — a multi-day agent-written research journal (`structmem`, gate 0 → gate 23), each entry 200–400 words, linked to its predecessor with `[[wikilinks]]`, including the negative results and falsified theories that never survive in a hand-maintained file. Nobody writes that by hand. That is the use case v2 should serve.

Two things follow.

**The value is on the agent write path, not the human input path.** The journal arrived through `memory_store`, unprompted, as a side effect of work. Every hour spent on new ways to get content *in* — connectors, hotkeys, share sheets, mobile capture — serves a workflow that has not demonstrated value and makes the one that has demonstrably worse.

**Retrieval is the constraint.** The store is legible today at ~25 rows because everything fits in one glance. It will not be at 500. A flat list in the GUI becomes overwhelming, and a broad `memory_search` currently returns most of the store as full verbatim bodies — thousands of tokens per call — while the store's coherence comes from a wikilink chain the agent maintains by hand, not from the index. Both break with scale.

So v2 is four items, all on the retrieval, write, and organizational path, all invisible in a changelog. Everything else is deferred; see §6.

---

## 1. Split Retrieval: Index and Body

The highest-value, lowest-risk change. Days of work, not weeks.

### What to Build

`memory_search` and `memory_recent` currently return full memory bodies for every hit. With 400-word entries, a broad query returns the entire store verbatim into the agent's context on a single call. Split the read path: search returns a compact index; bodies are fetched by id, on demand, only for what the agent actually needs.

### How to Build

1. **Add a headline column.** One line per memory, ≤ 120 chars, generated on write (see §3) and stored alongside the body. Backfill existing rows.

   ```sql
   ALTER TABLE memories ADD COLUMN headline TEXT;
   ```

2. **Search returns the index, not the corpus.** `memory_search` / `memory_recent` return `{id, title, headline, tags, createdAt, supersededBy}` — no `content`. A 25-hit result becomes a few hundred tokens instead of several thousand.

3. **Add `memory_get(id)`** (or `ids: [String]`) returning full bodies for the handful of entries the agent selects. This is the "window" to search's "index."

4. **Rank by relevance, not recency.** The current read path appears to return matches newest-first over a substring match. FTS5 has BM25 built in — `ORDER BY rank` with a `bm25()` weighting that favors title and tags over body — so ranking is close to a one-liner.

5. **Fan out server-side, then delete the workaround.** `AGENTS.md` currently tells agents to "search broadly, then narrow" and issue two or three queries per question because multi-token search is AND and ranking is weak. That is a retrieval bug pushed onto every caller and paid for on every turn. Do the expansion in the server — one query, server-side fan-out, ranked union — and remove the instruction.

### Success Criterion

A broad query ("what did we learn about eviction?") returns the 3–5 entries that matter, ranked, in a few hundred tokens — and the agent fetches at most two bodies. Measure against the existing structmem corpus; it's a ready-made eval set with known right answers.

---

## 2. Supersession Edges

### What to Build

Facts change. The current store has no way to say "this entry replaces that one," so the agent hand-rolls it with `[[wikilinks]]` in prose — which works only because one careful agent was told to do it, and is invisible to search.

Make it a first-class edge. **Append-only: mark, never overwrite.**

### Why Not Overwrite

The store already proves the case. `structmem Phase-1 result` was revised downward by `structmem Phase-1 diagnostic correction` ("good number, wrong reason"). The correction is only instructive *because the original claim is still there*. Mutating the first entry into the second would have destroyed the most valuable thing in the pair — the record of being wrong, and how it was caught. Append-only also keeps the audit story coherent and makes a bad automatic judgment recoverable rather than destructive.

### Schema

```sql
CREATE TABLE memory_supersessions (
    superseded_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    superseding_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    PRIMARY KEY (superseded_id, superseding_id)
);
```

### How to Build

* Add `supersedes: [String]?` to `memory_store`. Writing a memory that supersedes others records the edges; nothing is mutated or deleted.
* Search **de-ranks** superseded entries and marks them (`supersededBy: [id]`) rather than hiding them — an agent asking "what did we try that failed?" must still find them.
* Add `includeSuperseded: Bool = false` to `memory_search` for history queries.
* App: show the chain on a memory's detail view. This is the feature the wikilinks are approximating.
* CLI: `localmem supersede <old-id> --with <new-id>`.

---

## 3. Extract-and-Verify on the Write Path

### What to Build

Today, memory quality depends entirely on the caller. The structmem entries are good because this user's `AGENTS.md` is unusually well-written and the client is strong; a weaker agent pointed at the same mechanism fills the store with sludge that every later agent pays for. The fix is not more prose in `AGENTS.md` — it's to make the agent *propose* and the store *dispose*.

The machinery already exists: the file connector's two-pass extract → verify (§10 of the Technical Design). Point it at `memory_store`.

### How to Build

1. Agent submits raw text — no format contract, no title discipline required.
2. Server extracts `{headline, title, tags, type}` and verifies every extracted claim against the submitted text.
3. Store the **original body verbatim** plus the derived index fields. The extraction is an addressing layer, never a rewrite.
4. New rows land as `reviewState = .suggested`; promote to `.accepted` on first successful retrieval, or via explicit review.

   ```swift
   public enum ReviewState: String, Codable, Sendable {
       case suggested, accepted, archived
   }
   ```

### Do Not Add Schema Validation

`AGENTS.md` mandates one fact, third person, 3–6 word title. **Every valuable
memory in the store violates all of it** — the structmem entries are 200–400
word structured briefs with result tables and caveats, and they are better for
it. Validation on `memory_store` would reject exactly this content. Keep the
body long and verbatim; normalize only the *index over it* (headline, tags,
type). The real shape of a high-value memory is a lab-notebook entry, not a
one-line fact.

---

## 4. Automatic Categorisation & Organisation (Source & Project Grouping)

### What to Build

A flat list of 100+ memories in the vault app is unmanageable. A single PDF import can yield 20+ memories, and an agent session can generate several entries. Instead of manual categorization (which users never maintain), introduce **automatic, zero-friction grouping** in the SwiftUI sidebar based on the *provenance* of the memories.

Organize the memory list into collapsible folders based on:
1. **File Imports:** Memories linked via `source_memories` are grouped under folders named after the source file (e.g., `📁 architecture_spec.pdf (8)`).
2. **Project Context:** Memories written by agents are grouped under the project directory or repository they were created in (e.g., `📁 Project: localmem-app (12)`).
3. **Manual Entries:** Direct inputs from the user (via CLI or App) are grouped under `📁 Manual Entries`.

### Schema Changes

Add project and session tracking columns to `memories` table:

```sql
ALTER TABLE memories ADD COLUMN project_name TEXT;
ALTER TABLE memories ADD COLUMN session_id TEXT;
```

### How to Build

1. **MCP Directory/Project Detection:**
   Modify the `memory_store` tool schema to allow the agent to optionally pass a `project_name` or `session_id`. If omitted, the MCP server automatically infers the project name from the repository name or root directory path of the active workspace session.
2. **SwiftUI Sidebar outline structure:**
   Update `MemoryListPane` to group the flat array of loaded memories:
   * Match memories to `source_memories` to identify if they belong to a file import.
   * Group remaining memories by their `project_name` value (defaulting to "Manual" if `project_name` is null).
   * Render using a nested SwiftUI `List` with `Section` or an `OutlineGroup` allowing the user to collapse/expand folders.
   * Add a secondary filter/grouping toggle in the list header to switch between **Group by Origin (Files & Projects)**, **Group by Type**, and **Group by Tag**.

> **Grouping is display-only; it never scopes what an agent retrieves.** This is
> the line that separates §4 from the cut directory-routing feature. Folders
> organize the human's view of the vault; `memory_search` still spans every
> group, so cross-project recall — the core thesis — is untouched. An easy
> regression is to slide from "group by project in the sidebar" into "filter
> search by project"; do not. Note also that a chain spanning several projects
> (e.g. the structmem entries, written across five directories) scatters across
> folders under **Group by Origin** — **Group by Tag** is the view that keeps
> such a chain together, since the entries share a common tag across projects.

---

## 5. Sequencing

| Order | Item | Effort | Risk |
|---|---|---|---|
| 1 | Split retrieval + BM25 ranking (§1) | Days | Low — pure read path, nothing destroyed if ranking is wrong |
| 2 | Automatic Categorization & Organisation (§4) | ~1 week | Low — cosmetic GUI changes + non-breaking schema columns |
| 3 | Supersession edges (§2) | ~1 week | Low — append-only |
| 4 | Extract-and-verify on write (§3) | Weeks | Medium — touches every write |

**Gate between 3 and 4.** §1, §2, and §3 are justified by daily use today: they make the existing loop measurably better this week, and are cheap. §4 is where the real weeks go, so it needs the thesis validated first.

---

## 6. Deferred and Cut

Each of these was specified in the previous draft. None survive contact with the one workflow that has demonstrated value.

| Feature | Disposition | Reason |
|---|---|---|
| **Spaces** (colors / manual drag-drop) | **Replaced** | Replaced by **Automatic Categorisation** (§4) which groups by file and project provenance rather than forcing manual classification. |
| **Context-aware directory routing** (`cwd` → Space) | **Cut** | Contradicts the core thesis. The README's claim is that memory is user-level and cross-project — "that's the whole point." Routing by `cwd` would have fragmented the structmem chain. If the motivation is noise, the answer is ranking (§1), not walls. |
| **CLI shell + daemon manager** | Deferred | Plumbing. `localmem daemon` does resolve open question #3 (daemon ownership) in the Technical Design — worth doing eventually, not a v2 headline. |
| **iOS companion + CloudKit sync** | Deferred | Large lift (Secure Enclave keys, App Group migration, E2E encryption) for unclear demand. Nobody needs `gate19_reroping` on their phone. |
| **Suggested Inbox** (J/K triage deck) | **Partially adopted** | The `suggested` state is right and is adopted in §3 — but rewired to the *agent write path*, not file import. The J/K deck is the wrong ergonomic for agent writes; auto-promote on retrieval instead. |
| **Obsidian / Apple Notes connectors** | **Cut** | More input. Input is not the problem — the store already receives excellent content from agents. Additional volume degrades §1. |
| **Global hotkeys + share sheets** | **Cut** | More input, manually captured. Also drags the App Group / shared-SQLite complexity (multi-process writers) in for a workflow that has not shown value. |
