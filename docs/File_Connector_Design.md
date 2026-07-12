# File Connector — Import Memories from Files (Design, v2)

Status: **Accepted** · Revised 2026-07-11 · Scope: LocalmemCore + app · Platform: **macOS 26+**

> Supersedes the v1 proposal (branch `docs/file-connector-design`). v1 was
> designed around *folder sources kept in sync* (FSEvents watching, launch
> scans, replace-all reconciliation) plus a *blocking approve-before-save
> wizard*. Both were revised after implementation: sync fights deliberate
> curation, and the modal wizard/manage stack made routine tasks 3–4 dialogs
> deep. v2 is **deliberate multi-file import, non-blocking, no approval gate**
> — extraction quality is carried by the pipeline, not by a review modal.

## Goal

Let a user deliberately pick **files** (Text, Markdown, PDF), have Localmem
extract the durable facts/preferences/decisions from them **in the
background**, and store them as memories immediately — managed afterwards from
a split-pane detail view (per-file status, memories, reprocess/disable/remove).

Extraction stays **local-first**: Apple's on-device model when available,
otherwise a CLI-capable configured agent (Claude Code, Codex). Localmem never
runs its own model or holds an API key.

## Decisions (settled, v2)

| Decision | Choice | Changed from v1? |
|---|---|---|
| Selection model | **Multi-file selection only** — `NSOpenPanel` with `allowsMultipleSelection = true`, `canChooseDirectories = false`. One source per selected file. | **Yes** — v1 had folder-or-single-file sources |
| Folder sources / recursion | **None.** No folder walk, no hygiene filters, no per-source file cap, no missing-file sweep. "Import my whole vault" is a future structured connector's job (Obsidian, Apple Notes). | **Yes** |
| Sync / watching | **None.** No FSEvents, no launch scan, no auto-process. New files are never picked up implicitly; the user adds files deliberately. | **Yes** — v1 planned FSEvents + scans |
| Approval gate | **None.** Extracted memories are stored as they land. Curation happens after import, in the detail view (delete per memory / per file). | **Yes** — replaces the review-approve wizard step |
| Blocking behavior | **Non-blocking.** Picking files transitions immediately to the connector detail view; extraction runs in the background with live per-file status. The user can navigate away; a run can be stopped. | **Yes** — v1 wizard held a modal open through extraction |
| Navigation | **One catalog page + one in-window detail view.** No stacked sheets. The only system dialogs left: the open panel and destructive-action confirms. | **Yes** — replaces the Manage → Landing → Review sheet stack |
| Extraction backend ladder | Apple Foundation Models (on-device) → CLI-capable configured agent → unavailable. Never silent fallback from on-device to agent. | No |
| Localmem calling an LLM/API directly | Never. | No |
| Agent driving | Headless CLI only (Claude Code, Codex); GUI-only agents are never a backend. | No |
| File types | `.txt`, `.md`, `.markdown`, `.text`, `.pdf` (PDFKit text layer; no OCR). | No |
| Reconciliation | Replace-all **per file** on reprocess (a source *is* one file). | Simplified |
| Per-file actions | **Reprocess** and **Remove** only. No Disable/Disconnect (nothing runs without a gesture, so there is nothing to pause; *Remove & keep memories* covers the rest) and no bulk "Reprocess all" (rare need; on the agent backend one click could re-run every file through the user's plan). | **Yes** — v1 had Disconnect/Reconnect + full-source reprocess |
| Where it runs | Engine in `LocalmemCore`; orchestration + UI in the app. MCP not involved. | No |

## Non-goals (v2)

- **No folder import / recursion.** Deliberate per-file selection only.
- **No watching or auto-sync.** Nothing is processed without an explicit user
  gesture (add files, reprocess).
- **No approval/review gate.** Deferred indefinitely; if it returns it will be
  as post-import curation (`reviewState`), never a blocking modal.
- **No OCR, no Office formats, no cloud sync, no Localmem-operated model.**

---

## UI

### 1 · Connectors catalog (unchanged page, single level)

Grid of connector cards. The available card (Files) shows **Import…** and
**Manage** once anything is connected; coming-soon cards (Apple Notes,
Obsidian, Notion) advertise the roadmap.

```
┌───────────────────────────────────────────────────────────────┐
│ Connectors                                                    │
│ ┌─────────────────────────┐  ┌─────────────────────────┐      │
│ │ 📁 Files      [Available]│  │ 📝 Apple Notes          │      │
│ │ 5 files · 51 facts       │  │    [Coming soon]        │      │
│ │ [＋ Import…] [⚙ Manage] │  └─────────────────────────┘      │
│ └─────────────────────────┘  … Obsidian · Notion …            │
└───────────────────────────────────────────────────────────────┘
```

- **Import…** → backend choice (only when more than one backend is available;
  skipped otherwise) → multi-file open panel → **transition straight into the
  detail view (② below)** where extraction is already running.
- **Manage** → the same detail view.

### 2 · Connector detail view — split pane, in-window, non-blocking

One view serves both "just imported" and "managing later". Left: flat file
list, VS Code-explorer style, one row per source file with live status and
fact count. Right: detail for the selected file.

```
┌───────────────────────────────────────────────────────────────────────┐
│ ‹ Connectors     📁 Files                          ⟳ Processing 2/5…  │
├──────────────────────────────┬────────────────────────────────────────┤
│ FILES                        │  📄 Resume.pdf                         │
│  ✓ Resume.pdf            4   │  ~/Documents/Resume.pdf                │
│  ✓ Offer-letter.pdf      3   │                                        │
│  ⟳ Insurance.pdf         …   │  Status          ✓ Processed           │
│  ○ notes.md                  │  Last processed  2 min ago             │
│  ⚠ scan.pdf       no text    │  Backend         On-device             │
│                              │  Memories        4                     │
│                              │                                        │
│                              │  Memories from this file               │
│                              │  ┌───────────────────────────────────┐ │
│                              │  │ [Fact] Mechanical engineer …   🗑 │ │
│                              │  │ [Pref] Prefers remote work …   🗑 │ │
│                              │  └───────────────────────────────────┘ │
│──────────────────────────────│                                        │
│ [＋ Add files…]              │  [⟳ Reprocess]           [🗑 Remove]   │
└──────────────────────────────┴────────────────────────────────────────┘
```

- **Status icons:** `○ pending · ⟳ processing · ✓ processed · ⚠ skipped/failed
  (reason inline)`.
- **Live progress:** header shows the running count; rows tick `○ → ⟳ → ✓` as
  the run proceeds. A mid-processing selection shows a progress bar and a
  working **Stop** in the right pane. Nothing blocks navigation.
- **[＋ Add files…]** (left, bottom) reopens the multi-file panel and appends
  to the current run — adding more files later is the same gesture as the
  first import.
- **Right-pane actions** (per selected file — exactly two):
  - **Reprocess** — re-extract this file now (replace-all for this file). It
    is the retry for `failed`/`skipped`, the refresh after editing the file,
    and the re-extract after a prompt/backend improvement.
  - **Remove** — delete the source; confirm dialog offers *keep memories* /
    *delete its memories too*. *Remove & keep memories* is also the "stop
    tracking this file" gesture — no separate Disable state exists, because
    nothing runs without a user gesture, so there is nothing to pause.
- **No bulk "Reprocess all".** The rare legitimate case (prompt/backend
  improved) doesn't justify a button that can re-run every file through the
  user's agent plan in one click; see the version-stamp idea in Open
  questions. `Stop` appears in the toolbar while a run is in flight.
- **Memories list** (right pane) shows this file's imported memories with
  per-memory delete — this is the post-import curation surface that replaces
  the approval gate.

### Modality budget

The entire feature uses: the **NSOpenPanel**, an optional one-shot **backend
choice** popover/sheet, and **destructive confirms**. No wizard, no review
sheet, no stacked sheets. Deleted: `ConnectorWizardView`'s step machine,
`SourceReviewSheet`, `ConnectorManageView` (sheet), `SourceLandingView`
(sheet). `FactReviewList` is retired with the approval gate.

---

## Data model

The v1 tables survive with narrowed semantics. Schema changes go inside the
existing `v1_initial` block (pre-release rule; dev DB is recreated).

```sql
CREATE TABLE sources (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL,                 -- file base name
    connector    TEXT NOT NULL DEFAULT 'files',
    path         TEXT NOT NULL,                 -- absolute file path
    bookmark     BLOB,                          -- security-scoped bookmark
    backend      TEXT NOT NULL,                 -- 'apple' | 'agent:<agentID>'
    last_run_at  TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
-- source_files / source_memories keep their v1 shape (a file source has one
-- row today; the one-source-many-items shape is kept for future structured
-- connectors like Apple Notes).
```

Model / API deltas from the implemented v1 code:

| Item | Change |
|---|---|
| `ImportSource.Kind` | **Removed** — everything is a file. `kind` column dropped; `FileReader.enumerate`'s folder branch and the panel's `isDirectory` check go with it. |
| `autoProcess` | **Removed** (dead — sync is a non-goal). |
| `Status` / `status` column | **Removed entirely.** `disconnected` (and its would-be successor `disabled`) had no job left: nothing runs without a gesture, so there is nothing to pause, and *Remove & keep memories* covers "stop tracking." Per-file processing state lives in `source_files.status` only. |
| `maxFilesPerSource` | Repurposed as a per-*import-batch* sanity cap (panel selection size), not a folder-walk guard. |
| Missing-file sweep | `removeMissingFileStates` batch sweep removed; a source whose file is gone shows status *file missing* with **Remove** / **Relocate** actions instead of silent deletion. |
| `ExtractionEngine.preview` / `commit` | Collapsed back into a single `run(source:)` per file (no dry-run split; nothing awaits approval). `PreviewFact` / `ExtractionPreview` retired. |
| Concurrency | Per-file tasks (2 at a time, as v1 limits) feeding live per-row status; a run is cancellable. |

Provenance is unchanged: imported memories get `source = "import"`, linked via
`source_memories`, default-open access (`excludedAgents = []`).

---

## Extraction quality (now the load-bearing wall)

With no approval gate, **precision is the product**. Prioritized workstream:

1. **Prompt rewrite** *(both backends)* — remove the "extract EACH table item"
   instruction (over-extraction engine; a statement or task list must not
   become 200 line-item memories). Records are extracted only when
   identity-durable (degrees, certifications, ownership) — never transactional
   rows. Add **two few-shot examples** (one good extraction, one
   "nothing worth keeping → `[]`") — small models follow examples far better
   than rules. Add a **third-party-document guard**: extract only what
   plausibly describes the document's owner; skip documents about other
   people.
2. **Golden-set eval harness** *(build with #1)* — 5–8 fixture docs (notes,
   resume, statement, meeting notes, boilerplate-heavy scan) with expected
   memories; a test/CLI harness runs a backend over them and scores
   kept/missed/junk so every prompt change has a number. No more tuning by
   vibes.
3. **Guided generation for the Apple backend** — `@Generable`/`@Guide` typed
   output instead of parse-JSON-from-prose; constrained decoding eliminates
   malformed output and measurably improves small-model content quality.
   `FactParsing` remains for the agent CLI path only.
4. **Chunking** — the on-device model's context is ~4K tokens; today whole
   files (≤1 MB) go in one prompt, so on-device only works for short notes.
   Split on heading/paragraph boundaries, sized per backend (small for Apple,
   large for agents), slight overlap; the existing within-file dedup absorbs
   overlap duplicates.
5. **Vault-level dedup on import** — before insert, check normalized content
   against existing memories (FTS exact-normalized first; near-dup later) so
   the same fact from `resume.md` and `linkedin-export.md` is stored once.
6. *(later)* **Second-pass self-critique** on the agent backend: "here are the
   candidate memories + source — keep only durable, useful ones; merge
   duplicates."

The deterministic `BoilerplateFilter` stays as the final safety net on every
backend (high-precision by design — it only rejects unmistakable junk).

## Limits & error handling

Carried over from v1 unchanged, minus the folder-specific rows:

| Limit | Default | On exceed |
|---|---|---|
| Max file size (pre-read gate) | 20 MB | `skipped` / `too_large` — never read or sent to a backend |
| Max extracted text per file | ~1 MB (chunked per backend) | `partial` / `truncated_size` |
| Max facts stored per file | 200 | `partial` / `capped_facts` |
| Per-file extraction timeout | 180 s | `failed` / `timeout` (retriable) |
| Concurrency | 2 files at a time | — |
| Supported types | txt, md, markdown, text, pdf | filtered in the open panel; `skipped` / `unsupported` as backstop |

Nothing fails silently: every file ends a run with a `status` + plain-language
reason shown inline in the file list and the right pane, with per-file
**Reprocess** as the retry. Backend rules unchanged: on-device unavailable
mid-run → pause remaining files, never silently fall back to an agent; agent
CLI runs with the existing timeout + bounded output via `ProcessRunner`.

## Work breakdown

1. **Model cleanup:** drop `Kind`, `autoProcess`, and `Status`/`status`,
   remove folder enumeration + missing-file sweep, collapse
   `preview`/`commit` into cancellable per-file `run`.
2. **Import entry:** multi-file panel (`allowsMultipleSelection`, files only,
   type-filtered), one source per file, batch handed to the engine,
   backend choice only when >1 backend is available.
3. **Detail view:** in-window split pane (file list + per-file detail),
   live row status, header progress + Stop, `Add files…`, per-file
   Reprocess / Remove, per-memory delete.
4. **Delete the modal stack:** wizard step machine, review sheet, manage
   sheet, landing sheet, `FactReviewList`.
5. **Quality #1–2:** prompt rewrite + golden-set eval harness (same PR).
6. **Quality #3–4:** guided generation (Apple), chunking.
7. **Quality #5:** vault-level dedup on import.
8. **Tests:** engine run/cancel semantics, replace-all per file,
   missing-file status, limits & reason codes (carried from v1), eval-harness
   fixtures, dedup.

## Open questions

1. **Backend choice memory** — remember the last chosen backend per import, or
   ask each time when both are available? (Leaning: remember, changeable from
   the detail view.)
2. **Relocate action** — for a *file missing* source, offer re-pick of the
   moved file (bookmark may already resolve renames/moves; verify before
   building UI).
3. **Cross-source duplicate UX** — when vault-level dedup hits, silently skip,
   or link the existing memory to the second source too (`source_memories` is
   keyed on `memory_id`, so linking to two sources needs a PK change)?
4. **Stop semantics** — Stop mid-run leaves remaining files `pending`; should
   pending files auto-resume on next app launch or wait for an explicit
   Reprocess? (Leaning: explicit — consistent with "nothing happens without a
   gesture.")
5. **Stale-extraction badging** — stamp each `source_files` row with an
   extractor/prompt version; after a quality improvement, badge stale rows
   ("extracted with an older version — Reprocess?"). This is the targeted,
   consented replacement for the bulk "Reprocess all" button that was cut.
