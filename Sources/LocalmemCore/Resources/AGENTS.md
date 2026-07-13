<!-- Managed by localmem. This file is overwritten on every `localmem setup`. -->
<!-- To add your own guidance, edit your agent's own instruction file (CLAUDE.md, AGENTS.md) -->
<!-- — the import line keeps this file's content in scope alongside your customizations.    -->

# Localmem — Persistent Memory for AI Agents

Localmem is a local, file-based memory store that this agent reads from and writes
to over MCP. Use it to persist context across conversations: user preferences,
ongoing project decisions, and pointers to external resources.

Memory is **user-level and cross-project**. A fact stored in one repo's session is
visible from every other repo's session — that's the whole point. Anything that
should *only* apply to one codebase belongs in that codebase's own `CLAUDE.md` or
`AGENTS.md`, not here.

## When to act

**Trigger.** When the user says "remember X," states a preference about
themselves or their workflow, or corrects you in a way that should outlive this
conversation, call `memory_store` on the first mention. Don't wait to be asked
twice, and don't defer to a project-scoped memory file when the fact is about
the user.

**Precedence over built-in memory.** Many agents ship their own memory system
(e.g. Claude Code's auto-memory, ChatGPT memory). Those are typically
project- or assistant-scoped. For anything **user-level and cross-project**,
Localmem wins — store it here, and skip the built-in store for that fact so
the same memory doesn't get duplicated in two places. Reserve the built-in
system for project-scoped state, if you use it at all.

## How to think about Localmem vs. project files

| Surface | Scope | Mutability | Versioned |
|---|---|---|---|
| **Localmem** | User-level, cross-project | Mutable; updated each turn | No |
| **CLAUDE.md / AGENTS.md** | Project-level | Stable; edited deliberately | Yes (git) |

If a fact belongs to *the user* and is true across projects → Localmem.
If a fact belongs to *this codebase* and every contributor should follow it → the
project's instruction file.

## What the agent can do

Four MCP tools are exposed by the `localmem` server. Their detailed call-time
behavior (when to use, when not to, argument schemas) is described in the tool
descriptions themselves — the agent sees those every turn. This file is the
human-readable overview, not a substitute for reading the tool catalog.

- `memory_store` — persist a new fact, preference, or decision
- `memory_search` — full-text search over stored memories
- `memory_recent` — most-recent-first listing
- `memory_update` — replace fields on an existing memory (**destructive — the
  client will prompt the user every call; it is deliberately excluded from
  Localmem's pre-authorized tools**)

## When to update vs. when to store

A stored memory is a snapshot of a fact at a point in time. When the same
fact changes, you have two choices:

| The fact is… | Use |
|---|---|
| The same fact, with a new value (the old value is now wrong) | `memory_update` |
| A correction of a fact you stored earlier | `memory_update` |
| A refinement of a vague memory (more detail, broader tags) | `memory_update` |
| A new fact, related to but distinct from the existing one | `memory_store` |
| A reversal that should be reviewable later | `memory_store` (creates a second row; let the user dedupe via the app) |

**Examples.**
- User: "Actually I drink cortados now, not flat whites." → `memory_update` on the existing coffee memory.
- User: "I also drink matcha in the afternoons." → `memory_store` a new memory; the coffee preference still holds.
- User: "I switched to Cursor for the editor." → `memory_update` on the existing editor preference.

**Always search first.** `memory_update` needs the memory's `id`. Run
`memory_search` (or `memory_recent`) to find the exact row before calling
update, and make sure you're patching the right memory.

**Partial update.** Pass only the fields you want to change — title, content,
type, and tags each default to the existing value when omitted. Pass `tags: []`
to clear the tag list.

## What goes in memory

**Yes:**
- Stated user preferences (workflow, tools, communication style).
- Decisions that should outlive the current conversation.
- Pointers to external systems the agent will need to find again.
- Corrections the user makes — the agent should not need to be told twice.

**No:**
- Code patterns, file paths, or conventions that can be re-derived from the
  current project state.
- Information already captured in git history or `git blame`.
- Ephemeral task state (in-flight TODOs, current scratchpad).
- Anything already documented in a project's `CLAUDE.md` / `AGENTS.md`.

## Format

Every memory follows the same shape so the store stays searchable across agents
and the CLI/UI renders cleanly. **Do not invent your own conventions.**

**Title** — a 3–6 word noun phrase in sentence case. Names the fact, does not
state it. No trailing period. No `User` prefix — every memory is implicitly
about the user.
- Good: `Coffee preference`, `Backend role`, `Linear INGEST tracker`
- Bad: `User Preference: Coding`, `User likes coffee.`, `coffee`

**Content** — one fact, third person, present tense, full sentence with
terminal punctuation. The subject is implicit — never write "User" or
"User likes…". Write what's true, not who it's about.
- Good: `Prefers flat white with oat milk.`
- Good: `Backend engineer with ten years of Go; new to React.`
- Bad: `User loves coffee.`, `Likes eating food`, `Flat white. Oat milk.`

**Type** — pick exactly one of the five values the schema allows:
- `preference` — how the user wants to work, communicate, or be treated.
- `decision` — a choice made (product, technical, personal) that future
  sessions should respect without re-deriving.
- `fact` — biographical or contextual fact about the user (role, location,
  expertise).
- `project` — an ongoing initiative or work context.
- `note` — fallback when nothing else fits. Use sparingly; a vague `note`
  hurts recall.

**Tags** — 3–6 lowercase tags, `snake_case` for multi-word. **Always
singular** (`preference`, not `preferences`). Do **not** tag with `user` or
`user_profile` — every row is about the user. Before adding a new tag, run
`memory_search` for a synonym; reuse beats invent.

Tag for **discoverability**, not just topic. A memory tagged only with the
narrowest term (`vegan`) won't surface when a future agent searches the
broader category (`food`, `restaurant`, `diet`). Include the specific topic
**plus the categories an agent might search from a different starting
question**.
- Good: "Vegan diet" → `[diet, food, eating, restaurant, nutrition, vegan]`
- Good: "Coffee preference" → `[coffee, drink, morning_routine, preference]`
- Good: "SF Mono editor font" → `[editor, font, typography, tools, preference]`
- Bad: `[vegan]` only — too narrow; the next agent asking about restaurants
  will miss it.
- Bad: `[preferences]` (plural), `User Preference` (case + prefix),
  `userprofile`

## Searching memory

When the user's request *could* be answered by a stored memory — preferences,
prior decisions, biographical facts — search **before** answering. Do not
guess what the user wants and check after.

**Search broadly, then narrow.** A single query rarely covers a topic.
Run two or three `memory_search` calls with different angles of the same
question:

- User asks "plan a restaurant for tonight" → search `restaurant`, then
  `food`, then `diet`. The relevant memory might be tagged any of those.
- User asks "what editor should I use" → search `editor`, then `font`, then
  `tools`. A `font` preference can imply an editor preference.
- User asks about coding style → search `style`, then the language name
  (`python`, `javascript`), then the broader topic (`workflow`).

**When in doubt, list `memory_recent`.** If two or three targeted searches
return nothing, call `memory_recent(limit: 20)` and skim the titles —
faster than guessing more search terms, and you'll spot adjacent context
the user didn't explicitly mention.

**Visibility is per agent.** `memory_search` and `memory_recent` only return
memories this MCP client is allowed to see. The CLI and Localmem app remain the
admin surfaces and can see everything.

**Multi-token search is AND, not OR.** `memory_search("vegan restaurant")`
requires BOTH terms to match the same memory. To cast a wider net, issue
two single-token searches, not one multi-token one.

**One fact per call.** "I'm a Go engineer who hates frontend and drinks
oat-milk lattes" is three memories, not one: a `fact` for the role, a
`preference` for the frontend aversion, a `preference` for the coffee.

**Canonical example:**

```
memory_store(
    title: "Coffee preference",
    content: "Prefers flat white with oat milk.",
    type: "preference",
    tags: ["coffee", "preference"]
)
```

## Inspecting and managing memory

Outside of agent sessions, the `localmem` CLI can list, search, and remove
memories. Run `localmem --help` to see the full command set.
