---
name: audit
description: Full security + performance audit of the Localmem codebase. Static-only sweep across Sources/ for MCP input validation, SQL injection, path traversal, shell injection, atomic-write hygiene, prompt-injection surfaces, GRDB query patterns, startup latency, async/await overhead. Produces a ranked markdown report with file:line references for every finding. Invoke when the user types /audit, asks to "audit the app", "do a security and performance review", "check for vulns", or "review the codebase for issues" — not for single-PR review (use built-in /review or /security-review for that).
---

# audit

Goal: produce a ranked, file:line-anchored markdown report of every security or performance concern in the Localmem codebase. Static review only — no profiling, no fuzzing, no dynamic analysis.

## Output shape

End the audit with a single markdown report. No prose chatter while sweeping — just produce the report at the end.

```
# Localmem Audit Report — <ISO date>

## Summary
Security:    H <n>  ·  M <n>  ·  L <n>
Performance: H <n>  ·  M <n>  ·  L <n>

## Security findings
### [SEV] Short title
**Location:** `path/to/file.swift:42-58`
**Risk:** one-sentence statement of what an attacker could do or what could leak.
**Cause:** the specific construct in the code that creates the risk.
**Recommendation:** the smallest change that closes it.

[repeat per finding, ordered HIGH → LOW]

## Performance findings
### [SEV] Short title
**Location:** `path/to/file.swift:42-58`
**Symptom:** the observable cost (extra I/O, per-request overhead, startup latency, allocation churn).
**Cause:** the specific construct.
**Recommendation:** the smallest change with the biggest payoff.

[repeat per finding, ordered HIGH → LOW]

## Audited but clean
- one-line summary per major surface that was checked and found OK
  (helps the user trust the review wasn't superficial)
```

Severity rubric:
- **HIGH** — exploitable now or measurable user-visible perf regression.
- **MED** — needs an unusual precondition but plausible; or perf cost that scales with usage.
- **LOW** — defense in depth / nice-to-have; cite but don't push hard.

## Steps

### 1. Map the surfaces (5 min, in your head — no output to the user)

Sources to review, by layer:

| Layer | Path | What lives here |
|---|---|---|
| Core data | `Sources/LocalmemCore/MemoryStore.swift`, `Migrations.swift`, `Memory.swift` | GRDB queries, FTS5 |
| Core infra | `Sources/LocalmemCore/Paths.swift`, `AgentsResource.swift`, `InstructionsInstaller.swift` | Filesystem, bundle resources |
| MCP server | `Sources/localmem-mcp/LocalmemMCP.swift`, `Tools/ToolRegistry.swift` | External input from agents |
| CLI | `Sources/localmem/Commands/*.swift`, `LocalmemCLI.swift`, `OutputFormatter.swift` | Argument parsing, terminal output |
| Setup | `Sources/localmem/Setup/Registrars/*.swift`, `ShellHelper.swift`, `JSONConfig.swift`, `TOMLConfig.swift`, `BinaryLocator.swift` | Writes to user's home, shells out to agent CLIs |

Skim each directory listing to confirm the file list above is current — new files since this skill was written should still be in scope.

### 2. Security sweep

Run these checks in order. For each, cite file:line for the OK cases too (so the report's "Audited but clean" section has substance).

#### 2.1 MCP input validation (`Tools/ToolRegistry.swift`)
- Every arg coming from `arguments` is type-checked before use? (`stringValue`, `intValue`, `arrayValue`).
- Bounded where the schema declares bounds? (e.g. `limit` capped at 50.)
- Unknown enum values rejected with `MCPError.invalidParams`, not silently defaulted?
- Required args fail fast with a clear message?
- `content` length-bounded? (If not — flag it. Unbounded user content can blow up the SQLite row size.)

#### 2.2 SQL injection (`MemoryStore.swift`, `Migrations.swift`)
- Every query uses GRDB's parameter binding (`?`, named params, or `Record` types), never string interpolation of user input.
- Pay specific attention to FTS5 MATCH queries — the query string is bound, but the query *grammar* is user-supplied. Special FTS5 operators (`AND`, `OR`, `NEAR`, `*`, column filters) could be exploited to scan more rows than expected. Either escape or document the surface.
- ORDER BY / LIMIT clauses come from constants, not from user input.

#### 2.3 Path traversal & file-system writes (`InstructionsInstaller.swift`, `Paths.swift`, registrars)
- All paths are constructed from `FileManager.default.homeDirectoryForCurrentUser` (or test-injected `homeDir`), then `.appendingPathComponent(<constant>)`. No user-supplied path components.
- `injectImportLine(into:)` — `target.relativePath` is a static constant from `defaultTargets`. Confirm no public API takes a user-supplied relativePath. If it does, flag the traversal risk.
- File writes use `.atomically: true` so partial-write corruption is impossible.
- File mode on writes is whatever `FileManager` defaults to (mode 644). If anything writes secrets, mode should be 600 — check.

#### 2.4 Shell injection (`Setup/ShellHelper.swift`, all registrars)
- `ShellHelper.run(...)` and `runOrThrow(...)` must pass args as an array (`[String]`), never compose a single command string with interpolation.
- `binaryPath` is sourced from `BinaryLocator` (trusted), not from user input. Trace the call chain and confirm.
- Specifically check `Registrars/ClaudeCodeRegistrar.swift`, `CodexRegistrar.swift` where `claude mcp add` / `codex mcp add` are invoked with `binaryPath` — args array, not concatenated.

#### 2.5 Config-file rewrite hygiene (`JSONConfig.swift`, `TOMLConfig.swift`)
- Atomic writes (write to tmp, rename) — partial corruption impossible.
- Existing keys preserved (the registrar pattern reads, mutates, writes the whole tree).
- No logging of file contents to stderr — config files may contain unrelated MCP servers with credentials.
- Concurrent invocations don't race (probably out of scope for a single-user CLI, but check if anything claims to be safe under concurrency).

#### 2.6 Prompt-injection surfaces
- `~/.localmem/AGENTS.md` is loaded into every agent's context via the `@` import line. Contents come from the bundled `AGENTS.md` shipped in the binary. **Confirm there is no code path that writes memory content into this file** — if memory content can ever reach it, an attacker who can write to memory has prompt-injection of every future session.
- Tool response payloads (`memory_search`, `memory_recent`) return memory content to the agent. The agent treats tool output as content, not instructions, but a sophisticated attacker who controls memory content could try to inject instructions disguised as memories. Flag this as a known design surface, not a bug — the mitigation is the same as for any RAG system (clear delineation in the response format).

#### 2.7 Logging discipline (`LocalmemMCP.swift`)
- The MCP server uses stdout for the protocol. Confirm nothing logs to stdout — only stderr (the existing `log(_:)` helper does this; verify no `print(...)` calls slipped in).

### 3. Performance sweep

#### 3.1 GRDB query patterns (`MemoryStore.swift`)
- `recent(limit:)` — does it have a `created_at DESC` index? If it does a sequential scan + sort, that's a HIGH for any non-trivial memory count.
- `search(query:)` — FTS5 should be index-backed. If there's a `LIKE %query%` fallback anywhere, flag it.
- `add(...)` — single INSERT or wrapped in a transaction? If it does multiple writes (memory + tags + FTS), transaction is required for both perf and consistency.
- `get(id:)` — primary-key lookup, should be O(1). Confirm.

#### 3.2 Async/await overhead
- The MCP handlers are `async`. The underlying GRDB calls — are they actually async or wrapped in `await Task.detached { sync work }`? Sync work on the actor's executor is fine; sync work in a detached Task is wasted scheduling.
- `SetupCommand.runStreaming` uses `Task.detached { r.register(...) }` to free the spinner — correct use of detached.

#### 3.3 Startup cost
- `localmem-mcp` cold path (`LocalmemMCP.main`): every line of work here happens before the first request can be served. Anything that can be lazy should be.
- `localmem` CLI cold path: ArgumentParser introspection runs every invocation. Heavy work in command `run()` is fine; heavy work in static `configuration` properties bloats every CLI call, including `--help`.

#### 3.4 File I/O patterns
- `InstructionsInstaller.installAll()` reads + writes up to 4 files sequentially. Concurrency wouldn't help (each is <1 KB), but check that we read each file exactly once.
- Bundle resource loading: `AgentsResource.read()` reads the bundled file on each call. If it's called multiple times per `setup`, memoize once. Check.

#### 3.5 Allocation hot paths
- `OutputFormatter` and the spinner loop — string concatenation in tight loops. Usually fine for terminal output, but flag if you see `+=` inside a tight loop with large strings.

### 4. Write the report

Produce the report in the exact shape from "Output shape" above. Order findings HIGH → LOW within each section. Every finding gets a file:line reference, even LOW ones. The "Audited but clean" section at the bottom should name every numbered subsection from §2 and §3 that was checked and found OK.

## Guardrails

- **No fixes, only findings.** Do not edit code as part of the audit. The user reviews the report first and decides what to act on.
- **No stylistic complaints.** Naming, comments, file layout — out of scope. Security and performance only.
- **No missing-test findings.** That's `/verify-tests`. Confirm test coverage exists for the *risky* paths you identify, but don't generate a coverage report.
- **No "consider adding X" without a concrete risk.** Every recommendation must close a named risk, not satisfy a generic best practice.
- **Respect the project conventions in CLAUDE.md / docs:** no over-engineering, no premature abstractions, no defensive validation for cases that can't happen. If a "fix" would introduce one of these, downgrade the severity or drop the finding.
- **Be specific.** "Unbounded user input" is not actionable; "memory_store accepts `content` of unlimited length; SQLite max blob is 1 GB, but a 100 MB write will block the server for ~2s on disk" is.

## When NOT to invoke

- Reviewing a single PR or branch diff — use the built-in `/review` or `/security-review` instead.
- The user asked to FIX something, not audit it.
- The user is in the middle of implementing a feature and hasn't asked.
- Doc-only changes (`docs/`, `*.md`).
