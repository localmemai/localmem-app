# Localmem — Agent Instructions Implementation Plan

**Status:** Draft / proposed
**Owner:** Vidit
**Last updated:** 2026-05-27

## 1. Problem

When a user installs Localmem via `localmem setup`, the MCP server is registered with their AI agents (Claude Code, Claude Desktop, Cursor, Codex, Antigravity). The agents can *discover* the three tools (`memory_recent`, `memory_search`, `memory_store`) via MCP, but they don't know:

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
| Antigravity | `~/.gemini/AGENTS.md` (cross-tool global), `~/.gemini/GEMINI.md` (Antigravity-only global), also project-level `./AGENTS.md`, `./GEMINI.md`, `.agent/rules/` |
| ~~Claude Desktop~~ | **Out of scope for V1** — no file-based instructions mechanism; only UI-only system prompts. See §8. |

**Decision:** Author the canonical guidance once in `AGENTS.md`, and bridge to Claude Code via either a symlink or an `@AGENTS.md` import in `CLAUDE.md`. This is the broadest single-source approach available.

## 3. Scope Decisions (need user input)

These need to be settled before implementation:

### 3.1 Install scope

**Decision: global only.** The import line goes into each agent's global instruction file (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.cursor/AGENTS.md`, `~/.gemini/AGENTS.md`).

**Rationale:** Localmem is a user-level tool — memory lives in `~/.localmem/` and is intentionally cross-project. Per-project guidance would either duplicate the global content (no benefit) or fragment it (worse UX). Per-project override is **not planned** (see §8).

### 3.2 Install trigger

| Option | UX | Notes |
|---|---|---|
| **A. Bundled into `localmem setup` (default-on)** | Single command writes MCP config *and* agent instructions | Simplest; matches user expectation — if they installed Localmem, they want to use it |
| **B. Separate subcommand** (`localmem instructions install`) | Two-step: register MCP, then opt in to instructions | Cleaner separation but extra friction; tools sit unused until step 2 |
| **C. Prompted during `setup`** | `setup` asks "install agent instructions? [Y/n]" | Adds a yes/no prompt to a flow the user already opted into |

**Recommendation:** **A (default-on)**, with a `--no-instructions` opt-out flag for users who want to manage their agent instruction files manually.

**Rationale:** `localmem setup` already mutates `~/.claude/`, `~/.codex/`, `~/.cursor/` etc. to register the MCP server. Appending a single import line in the same directory is consistent with what setup already does, and the change is:

- **Minimally invasive:** one line per agent, no content rewriting.
- **Idempotent:** re-run is a no-op (see §3.3).
- **Trivially reversible:** `localmem instructions remove` (Phase 4) deletes the line.
- **Visible:** `SetupReport` lists every file touched (Phase 3).

Without the instructions, the MCP tools sit registered-but-unused on first contact, which is a bad out-of-box experience and the most common failure mode for shipped MCP servers today.

### 3.3 Merge strategy for existing files

If `~/.claude/CLAUDE.md` already exists (very common for Claude Code users), we must not clobber it. Options:

- **Fenced block:** Insert a `<!-- Localmem:start -->` … `<!-- Localmem:end -->` block; replace contents inside on re-run.
- **Import directive:** Append a single line `@~/.localmem/AGENTS.md` and store the actual content in Localmem's own data dir.
- **Sidecar:** Write `~/.claude/localmem.md` and tell the user to add `@localmem.md`.

**Recommendation:** **Import directive** — store canonical content at `~/.localmem/AGENTS.md` (single source of truth), and inject one-line imports into each agent's instruction file. Idempotent re-runs become trivial (line either present or not). Falls back to fenced block for agents that don't support imports.

## 4. Content — Two Surfaces, Edited Deliberately

### 4.1 Two surfaces, different content

Localmem presents agent-facing content in two places, and they are **intentionally not the same**:

| Surface | Source in repo | Audience | Style |
|---|---|---|---|
| `~/.localmem/AGENTS.md` | `Sources/LocalmemCore/Resources/AGENTS.md` (bundled, copied verbatim) | Humans skimming + agents reading once per session as global context | Orientation: mental model of Localmem, cross-project rules, what goes in / what doesn't |
| MCP tool `description` fields | Hand-written multi-line string literals in `Sources/localmem-mcp/Tools/ToolRegistry.swift` | The LLM, every turn, when it inspects the tool catalog before deciding which tool to call | Dense, prescriptive: USE WHEN / DO NOT USE / ARG NOTES / EXAMPLE per tool |

**Why two surfaces, not one:**

- **Different audiences.** AGENTS.md is read once per session as broad orientation. MCP descriptions are reloaded every turn as the LLM picks a tool. They optimize for different things.
- **Different formats.** AGENTS.md is a markdown document the user might open. MCP descriptions are flat strings inside a JSON tool catalog, evaluated in milliseconds during tool selection.
- **No real drift risk.** Both surfaces are edited by the same engineer, in the same PR, when call-time behavior of a tool changes. A parsed "single source of truth" would prevent a class of bug that doesn't really exist, at the cost of forcing both surfaces into one shape and adding ~200 LOC of parser + tests. An earlier revision of this plan committed to that model; reverted.

### 4.2 Pipeline

**AGENTS.md installer path:**
1. `Sources/LocalmemCore/Resources/AGENTS.md` is bundled as a Swift Package resource (`.process("Resources")` on the LocalmemCore target).
2. `AgentsResource.read()` returns it as a `String`.
3. `InstructionsInstaller.installCanonicalFile()` writes it verbatim to `~/.localmem/AGENTS.md` on every `localmem setup` (overwrite — see §7).
4. `injectImportLine(into:)` appends a single `@~/.localmem/AGENTS.md <!-- localmem -->` line to each agent's instruction file. Idempotent — see Phase 2 table.

**MCP descriptions path:**
1. `ToolRegistry.toolDescriptors` returns `[Tool]` with hand-written multi-line `description:` strings.
2. The MCP server returns them in response to `tools/list`.
3. Updates are normal Swift edits, picked up at the next build.

### 4.3 Authoring guidance

- **AGENTS.md**: keep under ~150 lines. Cover orientation, the user-vs-project distinction, what goes in / what doesn't. Do NOT duplicate per-tool call-time guidance — the MCP descriptions are where that lives.
- **MCP descriptions**: each tool gets a multi-line description structured as USE WHEN / DO NOT USE / ARGS / EXAMPLE. These are loaded into LLM context every turn, so they should be detailed enough to drive correct call-site decisions without consulting any external doc.

## 5. Phased Implementation

### Phase 1 — Author both surfaces (no code beyond bundling)
- Write `Sources/LocalmemCore/Resources/AGENTS.md` — the human-orientation file (see §4.3 authoring guidance).
- Bundle it as a Swift Package resource in `Package.swift` (`.process("Resources")` on the LocalmemCore target).
- Write the per-tool MCP descriptions as multi-line string literals in `Sources/localmem-mcp/Tools/ToolRegistry.swift` — USE WHEN / DO NOT USE / ARGS / EXAMPLE per tool.
- Review with a real Claude Code / Codex session to confirm the agent actually uses the tools correctly after reading both surfaces. Iterate copy on either surface independently.

### Phase 2 — Installer logic + MCP descriptions
- New file: `Sources/LocalmemCore/AgentsResource.swift` — thin accessor that exposes the bundled `AGENTS.md` as a `String` (via `Bundle.module`).
- New file: `Sources/LocalmemCore/InstructionsInstaller.swift` — takes the bundled content as a `String` and writes it / injects import lines.
- Installer responsibilities:
  - Copy bundled `AGENTS.md` verbatim to `~/.localmem/AGENTS.md` on every run (unconditional overwrite — see §7).
  - For each registered agent, apply the per-agent injection strategy from the table below.
  - Idempotent: re-running does nothing if the import line is already present (anchored on the `<!-- localmem -->` tag).
- MCP server: descriptions are authored directly in `ToolRegistry.swift` as multi-line string literals; no parser, no shared template.
- Mirror the existing `Registrars/` pattern — one strategy per agent.

**Per-agent injection targets:**

| Agent | Target file | Mechanism | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` | Append `@~/.localmem/AGENTS.md` import line | Create file if missing |
| Codex CLI | `~/.codex/AGENTS.md` | Append `@~/.localmem/AGENTS.md` import line | Create file if missing |
| Cursor | `~/.cursor/AGENTS.md` | Append `@~/.localmem/AGENTS.md` import line | Create file if missing |
| Antigravity | `~/.gemini/AGENTS.md` | Append `@~/.localmem/AGENTS.md` import line | Shared with Gemini CLI — see note below |

**Antigravity / Gemini CLI shared file note:** `~/.gemini/AGENTS.md` is shared between Antigravity and Gemini CLI (per [gemini-cli issue #16058](https://github.com/google-gemini/gemini-cli/issues/16058)). Writing to it covers both tools simultaneously — good for coverage, but the import line will show up in both. Intended.

### Phase 3 — Wire into setup
- Default behavior in `SetupCommand.swift`: install instructions for every agent that was successfully registered.
- Add a `--no-instructions` flag for users who want to manage their agent instruction files manually.
- Extend `SetupReport.swift` to list every instruction file touched (path + action: created / import-line added / already present).

### Phase 4 — Uninstall / status
- `localmem instructions status` — show which agents have the import line.
- `localmem instructions remove` — remove the import line, leave `~/.localmem/AGENTS.md` in place.
- Hook into existing `StatusCommand` output.

### Phase 5 — Docs
- Update `Localmem_Setup_Build_Guide.md` with the new flow.
- Add a short `docs/AgentInstructions.md` explaining the AGENTS.md strategy for end users.

## 6. Test Coverage Requirements

Every phase ships with its own tests. Use Swift Testing (already in the suite — see existing `Tests/localmemTests/`). **A phase is not complete until the tests below are green.** No new code merges without coverage for the categories listed for its phase.

### 6.1 Bundled-resource smoke test (Phase 1 / §4)
- **Resource present:** `AgentsResource.read()` returns a non-empty string and contains the product name. Catches the regression where the resource isn't bundled (`.process("Resources")` missing or filename mismatched).
- **Installer convenience init works:** `InstructionsInstaller()` (no-arg) loads the bundled content without throwing.

### 6.2 InstructionsInstaller (Phase 2)
- **Fresh install:** target file does not exist → file is created with only the import line.
- **Existing file, no localmem line:** import line appended; original content preserved byte-for-byte.
- **Existing file, localmem line already present:** no change (idempotency — must be safe to run on every `localmem setup`).
- **Unconditional overwrite of `~/.localmem/AGENTS.md`:** an existing file with user edits is fully replaced by bundled content on every run (the managed-file contract from §7).
- **Per-agent matrix:** one test per agent (Claude Code, Codex, Cursor, Antigravity) confirming the correct path and import syntax from the table in Phase 2.
- **Filesystem isolation:** use a tmp dir + dependency-injected paths. Tests must never touch the real `~/.claude/`, `~/.codex/`, etc.

### 6.3 SetupCommand integration (Phase 3)
- **Default behavior:** instructions installed for every registered agent; `SetupReport` lists every file touched with its action (created / import-line added / already present).
- **`--no-instructions` flag:** instruction files untouched; `SetupReport` reflects the skip.
- **Partial failure:** if injection fails for one agent (e.g. unwritable directory), the others still complete and the failure is surfaced in the report — `setup` does not abort.

### 6.4 Uninstall / status (Phase 4)
- **`instructions remove`:** removes only the import line; surrounding user content unchanged.
- **`instructions status`:** correctly reports per-agent presence/absence, including the edge case where the import line was hand-removed by the user.

### 6.5 Explicitly NOT in test scope
- That Claude Code / Codex / Cursor / Antigravity actually load and respect the file at runtime — that's the agent's job, validated manually in Phase 1's iteration loop.
- That the MCP protocol delivers tool descriptions correctly to clients — covered by the existing MCP server tests.

## 7. Upgrade Behavior

`~/.localmem/AGENTS.md` is a **managed file** owned by Localmem. Every `localmem setup` (including reruns after a binary upgrade) unconditionally overwrites it with the version shipped in the current binary.

- **Path is stable** → import lines (`@~/.localmem/AGENTS.md`) in every agent's config keep working across upgrades with no further action.
- **No version stamp / no diff prompts** → simpler mental model, no state to track across N agents.
- **Managed-file header** at the top of the file makes the contract explicit:
  ```
  <!-- Managed by localmem. This file is overwritten on every `localmem setup`. -->
  <!-- To add your own guidance, edit your agent's own instruction file (CLAUDE.md, AGENTS.md) — -->
  <!-- the import line keeps this file's content in scope alongside your customizations. -->
  ```
- Users who want to customize guidance add their own content to `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, etc. *after* the import line. Their content is never touched by localmem.

## 8. Out of Scope

- **Per-project AGENTS.md generation. Not planned.** Localmem is user-level by design (§3.1). Per-project guidance would duplicate or fragment the global content with no clear benefit.
- **Claude Desktop instruction injection.** No file-based mechanism exists (only UI-only system prompts via Profile preferences and per-Project settings). Claude Desktop will still get the MCP tool descriptions (those are baked into the binary, §4.2), but no AGENTS.md-equivalent reaches it. Revisit if Anthropic ships a file-based custom-instructions feature for the desktop app.
- Localization of instruction content.
- Telemetry on whether agents actually call the tools after reading the instructions.

## 9. Success Criteria

- After `localmem setup` on a fresh machine, opening any of {Claude Code, Codex, Cursor} and asking "what do you remember about me?" results in a `memory_search` or `memory_recent` call without prompting.
- Re-running `localmem setup` is a no-op for instruction files.
- A user with a pre-existing `~/.claude/CLAUDE.md` finds only a single appended import line, no other modifications.
