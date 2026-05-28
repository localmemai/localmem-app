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

## How to think about Localmem vs. project files

| Surface | Scope | Mutability | Versioned |
|---|---|---|---|
| **Localmem** | User-level, cross-project | Mutable; updated each turn | No |
| **CLAUDE.md / AGENTS.md** | Project-level | Stable; edited deliberately | Yes (git) |

If a fact belongs to *the user* and is true across projects → Localmem.
If a fact belongs to *this codebase* and every contributor should follow it → the
project's instruction file.

## What the agent can do

Three MCP tools are exposed by the `localmem` server. Their detailed call-time
behavior (when to use, when not to, argument schemas) is described in the tool
descriptions themselves — the agent sees those every turn. This file is the
human-readable overview, not a substitute for reading the tool catalog.

- `memory_store` — persist a fact, preference, or decision
- `memory_search` — full-text search over stored memories
- `memory_recent` — most-recent-first listing

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

## Inspecting and managing memory

Outside of agent sessions, the `localmem` CLI can list, search, and remove
memories. Run `localmem --help` to see the full command set.
