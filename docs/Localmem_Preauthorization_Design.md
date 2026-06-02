# Localmem — Per-Client Tool Pre-Authorization Design

**Status:** Draft / proposed
**Owner:** Vidit
**Last updated:** 2026-05-29

## 1. Problem

`localmem setup` registers the Localmem MCP server with five clients today:

```
ClaudeDesktopRegistrar
AntigravityRegistrar
CursorRegistrar
CodexRegistrar
ClaudeCodeRegistrar
```

(See [SetupCommand.swift:19-25](../Sources/localmem/Commands/SetupCommand.swift#L19-L25).)

Registration only tells the client *that* the server exists. Every client then gates each tool call behind its own approval prompt. The result: users approve `memory_recent`, `memory_search`, and `memory_store` once per session, every session, in every client. The friction kills the "ambient memory" UX we're shipping for.

We want `localmem setup` to **also** flip the client's pre-authorization switch for Localmem's tools, so the model can call them without prompting — without weakening the safety story for any *other* MCP server the user has installed.

## 2. Landscape — How each client expresses pre-authorization

Researched May 2026. Every client has *some* mechanism, but the schemas are wildly inconsistent and one (Antigravity) only supports server-wide trust, not per-tool. Cursor has known reliability bugs.

| Client | Config file | Mechanism | Granularity | Notes |
|---|---|---|---|---|
| **Claude Code** | `~/.claude/settings.json` | `permissions.allow: ["mcp__localmem__*"]` | Per-tool, wildcard supported | Separate file from `~/.claude.json` where the *server* is registered. User scope applies globally. Wildcards have known bug reports — fall back to explicit per-tool list if flaky. |
| **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json` | Per-server `autoapprove: ["memory_recent", ...]` array | Per-tool, no wildcard | Community-documented, not in official Anthropic docs. Lives inline inside the existing `mcpServers.localmem` block — same file we already edit. |
| **Cursor** | `~/.cursor/permissions.json` | `mcpAllowlist: ["localmem:*"]` | Per-tool, wildcard supported (`server:tool` / `server:*`) | **Separate file** from `~/.cursor/mcp.json`. When this file exists with `mcpAllowlist`, it *fully replaces* the in-app allowlist UI for MCP. Multiple bug reports (forum, GitHub) about allowlist not being honored — flag as best-effort. |
| **Codex** | `~/.codex/config.toml` | Per-server `default_tools_approval_mode = "auto"` (and optional per-tool override) | Per-server *or* per-tool | Lives inside the existing `[mcp_servers.localmem]` table we already write. `"auto"` runs without prompt; tools still respect the global sandbox. |
| **Antigravity / Gemini** | `~/.gemini/config/mcp_config.json` (also `~/.gemini/antigravity/`) | Per-server `"trust": true` (full bypass) or `"includeTools": [...]` (allowlist) | **Server-wide only** for auto-approve | `alwaysAllow: [...]` per-tool is *not* honored as of March 2026 forum testing. `trust: true` trusts the *whole server*, which is acceptable for us because we own every tool on it. |

### 2.1 Key schema observations

- **Two clients (Claude Code, Cursor) split the permission file from the registration file.** We need to write two separate JSON files for those.
- **Two clients (Claude Desktop, Codex) keep permission alongside registration.** Single-file edit; we just add fields.
- **One client (Antigravity) only supports server-wide trust.** Per-tool allowlists are documented but broken. We accept `trust: true` for Localmem.
- **Wildcards exist on Claude Code and Cursor**, but reliability is uneven. We will write **explicit per-tool entries** plus the wildcard, so we degrade to "still works" if the wildcard is buggy.

## 3. Proposal

### 3.1 Tool inventory — source of truth

Today Localmem ships three MCP tools (from [ToolRegistry.swift](../Sources/localmem-mcp/Tools/ToolRegistry.swift)):

- `memory_recent`
- `memory_search`
- `memory_store`

We should pre-authorize *only* these. When `memory_delete` lands (currently deferred per b838742), we will need to deliberately decide whether to add it to the allowlist — destructive tools should stay gated by default. To avoid the trap of silently auto-approving a new destructive tool the day it ships, the allowlist must be **enumerated**, not "every tool on this server":

- Claude Code: `mcp__localmem__memory_recent`, `mcp__localmem__memory_search`, `mcp__localmem__memory_store` — *not* `mcp__localmem__*`.
- Claude Desktop: `autoapprove: ["memory_recent", "memory_search", "memory_store"]`.
- Cursor: `localmem:memory_recent`, `localmem:memory_search`, `localmem:memory_store` — *not* `localmem:*`.
- Codex: per-tool `approval_mode = "auto"` on each of the three tools, *not* `default_tools_approval_mode = "auto"`.
- Antigravity: `trust: true` is unavoidable (no working per-tool gate). We accept the leak: when `memory_delete` ships, Antigravity users will get it auto-approved unless we add an `excludeTools` entry the same release.

The list lives in one place — `LocalmemCore` exposes `Localmem.preauthorizedToolNames: [String]` — and every registrar reads from it. New tools default to *not* in the list.

### 3.2 Extend `ClientRegistrar`

Add one optional method:

```swift
protocol ClientRegistrar {
    // ...existing API...

    /// Pre-authorize Localmem's tools so the client doesn't prompt
    /// on every session. Returns nil if the client doesn't expose a
    /// pre-authorization mechanism. Default: nil (no-op).
    func preauthorize(tools: [String]) throws -> PreauthorizationOutcome?
}

enum PreauthorizationOutcome: Sendable {
    case authorized(via: Strategy)      // wrote new authorization
    case alreadyAuthorized(via: Strategy)
    case updated(via: Strategy)          // existing list was different; reconciled
    case unsupported                     // client has no pre-auth mechanism
    case skipped(reason: String)         // e.g. file locked, permissions error we don't want to crash on

    enum Strategy: Sendable { case cli, configFile }
}
```

Default implementation in the protocol extension returns `.unsupported`. Each registrar overrides as appropriate.

### 3.3 Per-registrar implementations

#### ClaudeCodeRegistrar
- **Target file**: `~/.claude/settings.json` (separate from `~/.claude.json` registration file).
- **Write**: `permissions.allow` (array of strings). Append each `mcp__localmem__<tool>` entry that isn't already present. Preserve every existing entry untouched.
- **CLI fallback**: `claude` CLI does not currently expose an "add permission" subcommand — file edit only.
- **Idempotency**: if all three entries already present, return `.alreadyAuthorized`. If a subset is present, add the missing ones and return `.updated`.

#### ClaudeDesktopRegistrar
- **Target file**: same `claude_desktop_config.json` we already edit.
- **Write**: inside `mcpServers.localmem`, add `"autoapprove": ["memory_recent", "memory_search", "memory_store"]` (next to the existing `command` key).
- **Idempotency**: union-merge with any existing `autoapprove` array (don't blow away custom entries the user may have added).
- **Risk note**: this is the community pattern, not officially documented. We should add a comment in code and a footnote in the setup output so users know what we wrote.

#### CursorRegistrar
- **Target file**: `~/.cursor/permissions.json` (separate from `~/.cursor/mcp.json` registration file).
- **Write**: `mcpAllowlist: [...]` with explicit `localmem:memory_recent`, `localmem:memory_search`, `localmem:memory_store` entries.
- **Caveat**: docs note that *if `mcpAllowlist` is present*, the in-app UI becomes read-only for MCP. We must NOT clobber an existing `mcpAllowlist` — we union-merge.
- **Reliability**: flag in setup output that Cursor's allowlist has known intermittent bugs; if user still sees prompts, they may need to restart Cursor or check `permissions.json` was written. Don't auto-fail.

#### CodexRegistrar
- **Target file**: same `~/.codex/config.toml` we already edit.
- **Write**: for each tool, add a `[mcp_servers.localmem.tools.<tool>]` sub-table with `approval_mode = "auto"`. *Do not* set `default_tools_approval_mode` — keeps future tools gated.
- **CLI fallback**: `codex mcp` subcommands do not currently expose per-tool approval mode — file edit only.
- **Idempotency**: if a sub-table already has `approval_mode = "auto"`, skip; otherwise set it.

#### AntigravityRegistrar
- **Target file**: same `~/.gemini/config/mcp_config.json` we already edit.
- **Write**: inside `mcpServers.localmem`, set `"trust": true`.
- **Compromise**: this trusts the *entire* server, including any future tools. Acceptable for V1 (we ship only 3 read/write-but-not-destructive tools). When `memory_delete` lands, we must either:
  - Add `"excludeTools": ["memory_delete"]` in the same release that ships the tool, or
  - Downgrade Antigravity to `"trust": false` and accept the prompts.
- **Decision deferred** — flag a `// TODO: revisit when memory_delete ships` linked to the open work item.

### 3.4 SetupCommand wiring

In [SetupCommand.swift](../Sources/localmem/Commands/SetupCommand.swift):

1. After the existing `registrar.register(binaryPath:)` succeeds (i.e. for any outcome other than `.skipped` or thrown error), call `registrar.preauthorize(tools: Localmem.preauthorizedToolNames)`.
2. The result becomes a second column in the setup output, e.g.:
   ```
   ✓ Claude Code         registered (CLI)        auto-approved (3 tools)
   ✓ Cursor              registered (file)       auto-approved (3 tools, best-effort)
   ✓ Antigravity         registered (file)       trusted (server-wide)
   ✓ Claude Desktop      registered (file)       auto-approved (3 tools)
   ✓ Codex               registered (file)       auto-approved (3 tools)
   ```
3. Pre-authorization failures are **non-fatal**: log the reason, keep the registration. The tool still works, the user just gets the prompt every session.

### 3.5 Opt-out

Add a flag to `localmem setup`:

```
--no-preauthorize    Register the server but do not pre-approve its tools.
```

Default: pre-authorization is **on**. The whole point of this work is to remove friction; an opt-in flag would never get flipped.

We also need to think about `localmem status` — it should report the pre-authorization state per client, the same way it currently reports registration. Add a third state per client: `auto-approved | prompts-each-call | unsupported`.

## 4. Safety considerations

This change weakens the human-in-the-loop guardrail. Mitigations baked into the design:

1. **Enumerated tool list, not wildcards** (except Antigravity, where we have no choice). New tools — including any future destructive ones — default to *not* auto-approved.
2. **Per-client, per-tool, not blanket "trust this server"** wherever the schema supports it (Claude Code, Claude Desktop, Cursor, Codex). Only Antigravity gets server-wide trust because that's all its config understands.
3. **Opt-out flag** for users who want to keep prompts.
4. **`localmem status` surfaces the auto-approve state** so users can see what we did, audit it, and undo it.
5. **Pre-auth runs only against `mcpServers.localmem`** — we never touch other servers' entries. Setting *any* other server to trusted would be a serious silent footgun.
6. **No CLI flags or env-var elevation** — auto-approve only applies to Localmem's three named tools. A malicious file with a forged `mcp__localmem__exec_bash` would not match because that tool doesn't exist.

The remaining risk is that someone replaces the Localmem binary with a malicious one and now has the same three pre-approved tool names. That risk is **already** present today (the registrar puts the binary path in the config and the client trusts it on launch). Pre-authorization doesn't make it worse — it only removes the per-session click that the user was rubber-stamping anyway.

## 5. Edge cases

- **User has hand-edited their `permissions.allow` / `mcpAllowlist` / `autoapprove`**: union-merge, preserve every existing entry. Never clobber.
- **User runs `localmem setup` twice**: idempotent — `.alreadyAuthorized` for every client where we already wrote the entries.
- **User uninstalls Localmem**: we should leave the allowlist entries in place (they reference a now-missing binary so the client will just fail to load the server). Or add a `localmem uninstall` command that cleans up both registration and pre-auth. Out of scope for this design; track separately.
- **Client config file doesn't exist yet**: same as registration — create it with the right shape. The existing `JSONConfig.update(at:)` and `TOMLConfig.update(at:)` helpers handle this; we reuse them.
- **Config file is locked / unwritable**: return `.skipped(reason:)`, surface in setup output, don't crash. User is no worse off than today.
- **Wildcards-don't-work case (Claude Code, Cursor)**: we always write explicit per-tool entries, so the wildcard bug never bites us. We can drop the wildcards entirely from the design — they're noise.
- **`mcp_config.json` lives in a different folder on some Antigravity versions** (`~/.gemini/config/` vs `~/.gemini/antigravity/`): use the same path the registrar already uses; do not introduce a second path.

## 6. Testing

Test target: `LocalmemTests` (the new one in the in-progress diff).

Cases per registrar:

1. **Greenfield** — config file doesn't exist; pre-auth writes a valid file with the right keys.
2. **Idempotent** — pre-auth twice in a row; second run returns `.alreadyAuthorized`.
3. **Preserves other entries** — config has `mcpServers.other-server` with its own `autoapprove`; pre-auth leaves it untouched.
4. **Union-merge** — `mcpAllowlist` / `permissions.allow` already has unrelated entries; pre-auth adds Localmem entries without removing the others.
5. **Subset-already-present** — two of three tools authorized; pre-auth adds the third and returns `.updated`.
6. **Opt-out** — `--no-preauthorize` skips the call entirely; existing config is not touched.

Antigravity needs one extra test: a `mcpServers.localmem.includeTools` array set by the user is preserved (not replaced by `trust: true`).

## 7. Rollout

1. Land `Localmem.preauthorizedToolNames` and the `ClientRegistrar.preauthorize` API in `LocalmemCore` + `localmem` package (default no-op).
2. Implement per-registrar overrides one at a time, each with tests.
3. Wire into `SetupCommand` behind a feature flag (`--preauthorize` defaults off) for the first release so users can opt in and report breakage.
4. Flip the default to on once each registrar has had a real-world session of validation.
5. Update `localmem status` to report pre-auth state.
6. Update `AGENTS.md` to mention that tools will run without prompts after `localmem setup`.

## 8. Resolved questions

- **Proactive deny entry for `mcp__localmem__memory_delete`** — not needed. Re-running `localmem setup` after upgrading is the supported path; we don't pre-write deny rules for tools that don't exist yet.
- **`localmem status --fix` mode** — not needed. If a user wants to refresh pre-auth state, they re-run `localmem setup`. Single entry point, no second code path to maintain.
- **Antigravity `trust: true` policy revisit** — not yet. Re-evaluate when `memory_delete` actually ships, not preemptively.
