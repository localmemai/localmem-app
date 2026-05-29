---
name: verify-tests
description: Run `swift test` for Localmem, fix any failures, and audit coverage across the ENTIRE codebase (not just session-touched files), adding tests wherever coverage is missing. Invoke when the user types /verify-tests, asks to "verify tests" / "check coverage" / "make sure tests pass", or before wrapping a feature when test-worthiness is non-obvious.
---

# verify-tests

Goal: leave the working tree with `swift test` passing AND with tests covering every Source file in the repo that has logic worth testing.

## Steps

1. **Inventory every Source file.** Run `find Sources -type f -name "*.swift"`. These are the targets for coverage review — not just session changes, the whole repo.

2. **Run the test suite.**
   ```bash
   swift test --enable-code-coverage
   ```
   - If the build fails, the failure is upstream of testing — fix the compile error first, then re-run.
   - If tests fail, fix them. Prefer fixing the code under test over weakening assertions; only relax a test if the spec genuinely changed.

3. **Audit coverage across the entire codebase.** For every Source file:
   - Check whether a corresponding test target exists under `Tests/LocalmemCoreTests/` (or a sibling test target).
   - For every public type/function with logic, confirm there is at least one test exercising the happy path AND one for any error/edge branch the code explicitly handles.
   - Use the `--enable-code-coverage` report to find untested lines/branches in files that *do* have tests, not just files with no test file at all.
   - If gaps exist, add tests. Mirror the style of the nearest existing test file — same framework (Swift Testing's `@Test` macros vs XCTest), same helper patterns, same naming.

4. **Re-run `swift test`** after adding tests. Don't report done until it's green.

5. **Report briefly:** which files had coverage gaps, what tests were added, and the final pass/fail.

## Guardrails

- **Scope is the whole repo, not just session changes.** Every Source file with logic is in scope.
- **Don't mock LocalmemCore's database layer (GRDB) unless the existing tests do.** If the existing test file uses an on-disk temp database, follow that pattern.
- **Don't add a new test framework.** Use whatever the closest existing test file uses.
- **If a file genuinely doesn't need tests** (e.g. a thin CLI wiring shim with no logic, a pure data struct, generated code), say so explicitly in the report rather than padding with low-value tests.

## When NOT to invoke

- The user is mid-investigation and hasn't asked to verify yet.
- The user explicitly says "skip tests" or "don't run tests."
