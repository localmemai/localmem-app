---
name: code-quality
description: Audit Localmem's Swift sources for dead code, duplication, over-engineered solutions to simple problems, code smells, and tech debt. Fix the obvious wins inline; report the rest as a prioritized list. Invoke when the user types /code-quality, asks to "review code quality", "find dead code", "find duplication", "find code smells", or "list tech debt".
---

# code-quality

Goal: produce a trustworthy, prioritized read on the codebase's quality — and silently delete/clean up the things that are unambiguously wrong on the way.

Scope: all of `Sources/` (localmem, localmem-mcp, LocalmemCore) by default. If the user names a path, narrow to it.

## Steps

1. **Confirm the tree is clean.** Run `git status --short`. If there are uncommitted changes, ask whether to include them in scope or stash first — auto-fixes must not get tangled with the user's in-progress work.

2. **Build a file inventory.** List every Swift file under `Sources/` and note declared public/internal symbols per file (a quick `grep -nE '^(public |internal |func |class |struct |enum |protocol |extension )'` pass is enough). This becomes the working set for the passes below.

3. **Run the passes in this order.** Each pass produces findings; categorize each finding by severity (see Severity below).

   1. **Dead code.** Symbols (types, funcs, properties, files) with zero references outside their own declaration. Check via `grep -rn "<symbol>" Sources/ Tests/`. Watch for:
      - Whole files never imported.
      - `private`/`fileprivate` helpers with no in-file callers.
      - Public API that nothing inside the package consumes — flag but do not delete (may be intentional SDK surface).
      - `// TODO`/`// FIXME`/`#if false` blocks that have rotted.

   2. **Duplication.** Near-identical blocks (>~8 lines) across files, or the same string/number literal repeated in ways that imply a missing constant. `grep` for distinctive tokens to confirm. Distinguish *true* duplication (one source of truth needed) from *parallel-but-different* code (two things that happen to look alike — leave alone).

   3. **Over-engineering for simple problems.** Look for:
      - Protocols with one conformer and one caller.
      - Generic wrappers around a single concrete type.
      - Multi-layer abstractions where a free function would do.
      - Configuration / DI machinery that exists to make one call site testable.
      - `Result<T, Error>` returns where the function never actually fails.

   4. **Code smells.** Long functions (>~60 lines of real logic), deeply nested control flow (>3 levels), god types (one type owning unrelated concerns), feature envy (a method that only touches another type's data), boolean parameters that select between two code paths, primitive obsession (raw strings for IDs/paths where a typed wrapper exists nearby).

   5. **Tech debt markers.** `TODO`/`FIXME`/`HACK`/`XXX` comments, `fatalError("unimplemented")`, force-unwraps in non-test code, `@available(*, deprecated)` callers still using deprecated paths, version-pinned workarounds whose linked issue is closed.

4. **Fix the obvious wins inline.** Apply edits *only* for findings that are:
   - **Unambiguous** — no judgment call. Dead `private` helper with no callers in its file. Unused import. A literal duplicated in 3+ places with no semantic difference.
   - **Local** — change is contained to one file or to a tight cluster the user can review in one diff.
   - **Behavior-preserving** — no public API change, no semantic shift.

   After each cluster of fixes, run `swift build` to confirm the tree still compiles. If a fix breaks the build, revert it and demote the finding to the report instead.

   Do **not** auto-fix: anything touching public API, anything that changes module boundaries, anything requiring a judgment about intent, or duplication that might be parallel-but-different.

5. **Run the test suite once at the end.** `swift test`. If anything went red that was green before, the auto-fixes are suspect — revert the most recent batch and re-run until green.

6. **Report.** Output a single structured summary:

   ```
   ## Auto-fixed
   - <file:line> — <one-line description of what was removed/cleaned>

   ## Findings (action required)
   ### High — bugs hiding or actively misleading
   - <file:line> — <issue> — <suggested fix>
   ### Medium — meaningful debt or smell
   - …
   ### Low — nits, style, future cleanup
   - …
   ```

   For each finding, link with `file.swift:line` markdown links so the user can jump straight to it.

## Severity rubric

- **High**: force-unwraps that can crash, dead error paths that hide bugs, duplication where the copies have already drifted, `fatalError` in reachable code.
- **Medium**: real over-engineering, long/god functions, meaningful duplication that hasn't drifted yet, stale TODOs older than ~6 months.
- **Low**: nit-level smells, single-use helpers that could be inlined, naming inconsistencies.

If everything is Low, say so — don't manufacture severity.

## Guardrails

- **Don't refactor toward a "cleaner" architecture.** This skill removes waste; it does not redesign. If a finding requires rethinking module boundaries, it goes in the report, not the diff.
- **Don't delete code you don't fully understand.** "I can't find a caller" is not the same as "there is no caller" — reflection, string-based lookup, MCP tool dispatch, and `#selector`-style indirection all defeat grep. When in doubt, report it.
- **Don't expand scope.** A messy neighbor of a fixed function stays messy unless it's in the user's scope.
- **Don't churn formatting.** Whitespace-only or import-reordering changes are noise; skip them.
- **Don't invent tech debt.** If the code is fine, the report should say so. A short "nothing material found in X" beats a padded list.

## When NOT to invoke

- The user is mid-feature and hasn't asked for a review.
- The diff is doc-only or config-only.
- The user explicitly says "just ship it" / "don't clean up".
