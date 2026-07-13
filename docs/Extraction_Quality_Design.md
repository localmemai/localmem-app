# Extraction Quality — Two-Pass Extract → Verify (Design)

Status: **Implemented** (core pipeline, agent backends, counts + UI, eval
harness · 2026-07-13; remaining: on-device guided generation + chunking,
vault-level dedup) · Accepted 2026-07-12 · Scope: LocalmemCore + app · Extends the
file connector ([Technical_Design.md §10](Technical_Design.md#10-file-connector))

## Problem

Connector imports store memories **directly** — there is no approval gate
(removed by design; see the connector section). That makes extraction precision
the product: every junk fact lands in the vault, is visible to agents over
MCP, and erodes trust in the whole store.

Single-prompt extraction has not gotten there. Two prompt-tightening rounds
and a deterministic boilerplate filter later, over-extraction is still the top
quality issue — because a single prompt is asked to do two opposing jobs.
Extraction is a *generate* task (rewarded for producing output → over-
extracts); judgment is a *reject* task. Models are consistently better at
judging a candidate against criteria than at not generating it in the first
place. So: split the jobs.

## Architecture

```
read → normalize → (chunk, per backend)
  ↓
PASS 1 — EXTRACT            liberal by design; recall is its only job
  ↓
deterministic filters        BoilerplateFilter + within-file dedup
                             (free, run BEFORE any second LLM call)
  ↓
PASS 2 — VERIFY              one batched call per file (per chunk on-device):
                             source text + ALL surviving candidates →
                             per-candidate verdict: keep | revise | drop
                             (+ merge groups, + one-line reason each)
  ↓
vault-level dedup            deterministic, against existing memories
  ↓
store                        memories become visible to the user and agents
```

Nothing reaches the vault without passing verification. The user sees the
result plus a transparency line ("14 extracted → 8 kept").

### Two load-bearing rules

1. **The verifier sees the source text, not just the candidates.** Without the
   source it can only judge *form* (well-shaped sentence?), never *truth*
   (grounded in the document? about the owner? faithfully stated?). Grounding
   is the hallucination check the pipeline currently lacks.
2. **Verify the set, not fact-by-fact.** One batched call per file: one extra
   backend invocation instead of N, and set-level judgment enables what
   per-fact checks cannot — merging near-duplicates, recognizing "these 12
   facts are rows of one table," keeping a sensible per-document budget.

## Pass 1 — Extract (liberal)

The extractor prompt is **rewritten and simplified**. With a verifier behind
it, it no longer needs the contradictory "be selective / extract EACH item"
tension — it leans generous (recall), and precision is Pass 2's job.

- Keep: the memory shape rules (title as noun phrase, one self-contained
  third-person sentence, the five types), the JSON-array output contract.
- Add: **two few-shot examples** — one good extraction from a notes snippet,
  one "nothing worth remembering → `[]`". Small models follow examples far
  better than rules.
- Drop: the "extract EACH meaningful item" table instruction and most of the
  negative rules (boilerplate lists) — the deterministic filter and the
  verifier own those now.

## Pass 2 — Verify (strict curator)

Input: the source text (or chunk) + the surviving candidates, numbered.
Persona: *a strict curator of a personal memory store deciding what deserves
to be remembered for years.*

Per candidate, hard gates — **drop unless all pass**:

| Gate | Question |
|---|---|
| Grounded | Directly supported by the text, no embellishment or inference beyond it? |
| Durable | Still useful in six months, without the document in hand? |
| About the owner | About the vault owner — not a third party the document mentions? |
| Atomic & self-contained | Exactly one fact, understandable standalone? |
| Non-transactional | Not a line item, log entry, running balance, or document metadata? |

Verdicts:

- `keep` — store as-is.
- `revise` — the fact is true and worth keeping but badly shaped (title,
  type, phrasing); the verifier returns the repaired fact. **This is what
  stops verification from tanking recall** — a good fact with a bad title is
  fixed, not lost.
- `drop` — with a one-line `reason`.

The verifier may also emit **merge groups** (indices that state the same
fact) — the kept member absorbs the best phrasing.

Output contract (parsed with the same tolerant `FactParsing` approach):

```json
[
  {"index": 0, "verdict": "keep"},
  {"index": 1, "verdict": "revise", "title": "…", "content": "…", "type": "fact", "tags": ["…"], "reason": "title was a label"},
  {"index": 2, "verdict": "drop", "reason": "table row / transactional"},
  {"index": 3, "verdict": "drop", "reason": "about the counterparty, not the owner"}
]
```

Reasons are logged (debug log, not the DB) — free tuning data for both
prompts and the eval harness.

## Decisions (settled)

| Decision | Choice | Why |
|---|---|---|
| Who verifies | **Same backend as extraction — permanent** | Self-verification still helps (task framing decorrelates errors). Cross-backend verification was considered and rejected (2026-07-13): not worth the coupling. |
| Verification is optional? | **No — always on, no setting** | Skipping it silently reintroduces the junk problem the pass exists to kill. The on-device backend (cheapest to run) is also the most junk-prone — the worst candidate for an opt-out. |
| Verifier fails / times out / bad output | **File → `failed`, retriable** | Never store unverified facts. Reason codes `verify_timeout`, `verify_error`, `verify_invalid_output`; per-file Reprocess is the retry, exactly as today. |
| Agent-backend cost (2 calls/file) | **Accepted** | The verify prompt is small (source + candidates + rubric — no extraction instructions). File count is user-curated by the deliberate-selection model, which bounds total cost. |
| Transparency | **"N extracted → M kept" in the detail pane** | Trust feature; also surfaces an over-aggressive verifier immediately. Counts persist in `source_files` (new nullable `extracted_count` / `kept_count` columns, added in a **new migration** — post-v4 lesson: never edit an applied migration in place). |
| Empty results | `[]` after verification is a **valid processed outcome** ("nothing worth remembering"), not a failure. | Matches the extractor contract; avoids retry loops on genuinely memory-free documents. |

## Backend specifics

- **Apple on-device:** both passes use **guided generation** (`@Generable`
  types for the fact array and the verdict array) — constrained decoding
  removes malformed-output failures and improves small-model quality. The
  ~4K-token context means both passes run **per chunk** (chunk text + that
  chunk's candidates); within-file dedup then collapses overlap duplicates
  across chunks.
- **Agent CLI (Claude Code / Codex):** two locked-down text→text invocations
  per file (the existing injection hardening — tools and MCP stripped —
  applies to both). Whole-file verification (no chunking needed at agent
  context sizes). Timeout per pass = the existing `extractionTimeout`.

## Eval harness (built first — non-negotiable)

Two prompts means two things to tune; without measurement, tuning is vibes.

- **Golden set:** 6–8 fixture documents under `Tests/…/Fixtures/extraction/` —
  personal notes, a resume, a bank statement (all-transactional → expect
  near-`[]`), meeting notes, a registration-card-style form, a third-party
  document (someone else's resume → expect `[]`), a boilerplate-heavy scan.
  Each with an expected-memories YAML/JSON (content phrased canonically,
  matching by normalized similarity, not string equality).
- **Metrics per run:** junk-kept rate (precision), good-lost rate (recall),
  duplicate rate. Reported for extract-only vs extract+verify so the
  verifier's contribution is always visible.
- **Where it runs:** a test target (mock-free, hitting a real backend) is too
  slow/flaky for CI — so it's a **manual CLI/dev harness** (`localmem`-side
  hidden command or a small script) run when prompts change; deterministic
  pipeline pieces (filters, parsing, dedup) stay in the normal test suite.

## Engine integration

`ExtractionEngine.process` gains no new public API — the two passes live
inside it:

```
extract(text) → clean() → verify(text, candidates) → apply verdicts
→ vault dedup → replaceMemories(…) → state(status, extracted_count, kept_count)
```

`FactExtractor` stays the Pass-1 protocol; a sibling `FactVerifier` protocol
mirrors it (`verify(candidates:against:context:) → [Verdict]`), with Apple
and agent-CLI implementations selected by the same backend ladder.

## Work breakdown

1. **Eval harness** — fixtures, expected sets, scoring script, extract-only
   baseline numbers recorded.
2. **`FactVerifier` protocol + verdict parsing** (core) with agent-CLI
   implementation; wire into `process` with the fail-the-file semantics and
   new reason codes.
3. **Prompt pair** — liberal extractor rewrite + strict verifier, tuned
   together against the harness (target: junk-kept ↓ hard, good-lost roughly
   flat vs baseline).
4. **On-device implementations** — guided generation for both passes;
   per-chunk verification; chunking itself if not yet landed.
5. **Counts + UI** — migration for `extracted_count`/`kept_count`,
   "N extracted → M kept" in the detail pane.
6. **Vault-level dedup** (already on the connector roadmap; runs after
   verification).

## Open questions — resolved 2026-07-13

1. **Cross-backend verification** — **No.** Keep it simple: the same backend
   extracts and verifies, permanently — not just v1. The task-framing split
   (generate vs judge) is the whole mechanism.
2. **Per-document budget** — **Yes.** The verifier prompt carries a soft cap
   ("a typical document yields 3–10 memories; a dense document may justify
   more, but every extra one must clear the gates").
3. **Persisting drop reasons** — **No.** Debug-log only; never in the DB.
4. **Revise-verdict trust** — **Trusted.** No grounding re-check pass.

### Implementation simplifications (settled during build)

- **Merge groups are dropped from the v1 contract.** The verdict set is
  exactly `keep | revise | drop`; the verifier is instructed to `drop` a
  near-duplicate with a reason naming the kept candidate. Within-file and
  vault-level dedup carry the deterministic side.
- **Partial/invalid verdict output fails the file.** If the verdict array
  misses a candidate index, repeats one, or references one out of range, the
  file records `verify_invalid_output` (retriable). No silent per-candidate
  fallback.
- **"N extracted" is the raw Pass-1 count** (before deterministic filters),
  so the transparency line reflects everything the extractor proposed.
