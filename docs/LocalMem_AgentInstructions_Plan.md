# LocalMem — Agent Instructions Implementation Plan

**Status:** Draft / proposed
**Owner:** Vidit
**Last updated:** 2026-05-27

## 1. Problem

When a user installs LocalMem via `localmem setup`, the MCP server is registered with their AI agents (Claude Code, Claude Desktop, Cursor, Codex, Antigravity). The agents can *discover* the three tools (`memory_recent`, `memory_search`, `memory_store`) via MCP, but they don't know:

- **When** to call them (e.g. "store this after a non-obvious decision," "search before answering a question that depends on past context").
- **What style** of content belongs in memory vs. ephemeral chat.
- **How** the tools compose (search → store, recent → context window).

Without usage guidance, agents either ignore the tools or overuse them. We need to ship **agent-readable usage instructions** alongside the MCP registration so the tools are actually useful from turn one.

## 2. Landscape — Why AGENTS.md

As of May 2026:

| Agent | Native instruction file |
|---|---|
| Codex CLI | `AGENTS.md` |
| Cursor | `AGENTS.md` |
| Windsurf | `AGENTS.md` |
| GitHub Copilot | `AGENTS.md` |
| Gemini CLI | `AGENTS.md` (also `GEMINI.md`) |
| Aider / Amp / Devin / Jules | `AGENTS.md` |
| **Claude Code** | **`CLAUDE.md`** (does *not* read `AGENTS.md` natively — [issue #34235](https://github.com/anthropics/claude-code/issues/34235)) |
| Claude Desktop | No project file convention; uses MCP server description |
| Antigravity | No documented convention yet |

**Decision:** Author the canonical guidance once in `AGENTS.md`, and bridge to Claude Code via either a symlink or an `@AGENTS.md` import in `CLAUDE.md`. This is the broadest single-source approach available.

## 3. Scope Decisions (need user input)

These need to be settled before implementation:

### 3.1 Install scope

| Option | Where the file lives | Pros | Cons |
|---|---|---|---|
| **A. Global only** | `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.cursor/AGENTS.md` etc. | One install, applies everywhere | Some agents only respect repo-local files; harder to opt-out per project |
| **B. Project only** | `<repo>/AGENTS.md` + `CLAUDE.md` bridge | Respects per-project context; user controls | Has to be re-run per project; no use outside repos |
| **C. Both** | Global default + per-project override | Maximum coverage | More install logic; more places to keep in sync |

**Recommendation:** **A (global)** for V1. LocalMem is a user-level tool — memory lives in `~/.localmem/`, not per repo. Per-project overrides can be a V2 feature if users ask.

### 3.2 Install trigger

| Option | UX | Notes |
|---|---|---|
| **A. Bundled into `localmem setup`** | Single command writes MCP config *and* agent instructions | Simplest; matches user expectation |
| **B. Separate subcommand** (`localmem instructions install`) | Two-step: register MCP, then opt in to instructions | Cleaner separation; respects users who already have curated `CLAUDE.md` |
| **C. Prompted during `setup`** | `setup` asks "install agent instructions? [Y/n]" | Best UX but more CLI surface |

**Recommendation:** **C (prompted)**, with a `--with-instructions` / `--no-instructions` flag for non-interactive use.

### 3.3 Merge strategy for existing files

If `~/.claude/CLAUDE.md` already exists (very common for Claude Code users), we must not clobber it. Options:

- **Fenced block:** Insert a `<!-- LocalMem:start -->` … `<!-- LocalMem:end -->` block; replace contents inside on re-run.
- **Import directive:** Append a single line `@~/.localmem/AGENTS.md` and store the actual content in LocalMem's own data dir.
- **Sidecar:** Write `~/.claude/localmem.md` and tell the user to add `@localmem.md`.

**Recommendation:** **Import directive** — store canonical content at `~/.localmem/AGENTS.md` (single source of truth), and inject one-line imports into each agent's instruction file. Idempotent re-runs become trivial (line either present or not). Falls back to fenced block for agents that don't support imports.

## 4. Content — What the AGENTS.md Says

Skeleton of `~/.localmem/AGENTS.md` (this is the *content plan*, not the final copy):

```markdown
# LocalMem — Persistent Memory for AI Agents

LocalMem provides a local, file-based memory store accessible via three MCP tools.
Use it to persist context across conversations.

## Tools

### memory_store
Save a fact, preference, decision, or pointer. Use when:
- The user states something about themselves (role, preferences, workflow).
- The user corrects you, or validates a non-obvious approach.
- A project decision is made that future sessions should respect.

Do NOT store: code patterns derivable from the repo, git history, ephemeral task state.

### memory_search
Query existing memories by keyword/semantic match. Use BEFORE answering
questions that depend on prior conversations or user preferences.

### memory_recent
List the N most recently stored memories. Use at session start to refresh
context, or when the user references "what we talked about last time."

## When to use LocalMem vs. project files (CLAUDE.md, AGENTS.md)

- LocalMem = user-level, cross-project, mutable
- AGENTS.md/CLAUDE.md = project-level, version-controlled, stable

## Examples

[2-3 concrete store/search/recent flows]
```

Keep it under ~150 lines. Agent instruction files compete for context-window budget.

## 5. Phased Implementation

### Phase 1 — Author the content (no code)
- Write `templates/AGENTS.md.tmpl` in the repo.
- Review with a real Claude Code / Codex session to confirm the agent actually uses the tools correctly after reading it.
- Iterate copy until behavior is good.

### Phase 2 — Installer logic
- New file: `Sources/localmem/Setup/InstructionsInstaller.swift`
- Responsibilities:
  - Copy template to `~/.localmem/AGENTS.md` on first install.
  - For each registered agent, locate its instruction file and inject the import line.
  - Idempotent: re-running does nothing if line is present.
  - Per-agent strategy table (Claude Code → `~/.claude/CLAUDE.md` with `@~/.localmem/AGENTS.md`; Codex → `~/.codex/AGENTS.md` with `@~/.localmem/AGENTS.md`; etc.).
- Mirror the existing `Registrars/` pattern — one strategy per agent.

### Phase 3 — Wire into setup
- Extend `SetupCommand.swift` with `--with-instructions` / `--no-instructions` and the interactive prompt.
- Extend `SetupReport.swift` to report which instruction files were touched.

### Phase 4 — Uninstall / status
- `localmem instructions status` — show which agents have the import line.
- `localmem instructions remove` — remove the import line, leave `~/.localmem/AGENTS.md` in place.
- Hook into existing `StatusCommand` output.

### Phase 5 — Docs
- Update `LocalMem_Setup_Build_Guide.md` with the new flow.
- Add a short `docs/AgentInstructions.md` explaining the AGENTS.md strategy for end users.

## 6. Open Questions

1. Do we ship a version stamp in the imported file so re-runs can offer to update outdated copies?
2. For agents without import support (Antigravity, Claude Desktop) — skip, or inline the full content with fenced markers?
3. Should the content live in the repo (template) or be fetched from a URL at install time (allows update without reinstalling LocalMem)?
4. Per-project override mechanism — defer to V2 or include now?

## 7. Out of Scope (V1)

- Per-project AGENTS.md generation (V2).
- Auto-updating `~/.localmem/AGENTS.md` when LocalMem is upgraded — V1 leaves it to the user (or `localmem instructions reinstall`).
- Localization of instruction content.
- Telemetry on whether agents actually call the tools after reading the instructions.

## 8. Success Criteria

- After `localmem setup` on a fresh machine, opening any of {Claude Code, Codex, Cursor} and asking "what do you remember about me?" results in a `memory_search` or `memory_recent` call without prompting.
- Re-running `localmem setup` is a no-op for instruction files.
- A user with a pre-existing `~/.claude/CLAUDE.md` finds only a single appended import line, no other modifications.
