# Obsidian Connector — Deliberate Note Import (Design)

Status: **Designed, not yet built** · 2026-07-12 · Scope: LocalmemCore + app

> Implement **after** the two-pass extraction work
> ([Extraction_Quality_Design.md](Extraction_Quality_Design.md)) lands —
> notes are the content type the current prompt handles worst, and card-level
> detection will drive real usage on day one. The implemented file connector
> this builds on is specified in
> [Technical_Design.md §10](Technical_Design.md#10-file-connector).

## Why Obsidian next, and why it isn't "folders again"

Folder import was cut from the file connector because a raw filesystem walk
doesn't understand what it walks. An Obsidian vault is self-describing, which
removes every objection:

- `.obsidian/` marks a vault root; `~/Library/Application Support/obsidian/obsidian.json`
  lists every vault on the Mac (plus the iCloud location
  `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/`) — vaults are
  **auto-detected**, no folder picker guessing.
- Ignore rules come from the vault itself (`.obsidian/`, `.trash/`, the
  configured attachments/templates folders), not heuristics.
- Notes are `.md` only and personal by nature — the highest-signal content for
  a personal memory store.

Apple Notes (no filesystem; AppleScript / protected SQLite, TCC prompts) and
Notion (OAuth + cloud API) are each a multiple of the effort and stay
**coming soon**.

## Decisions (settled)

| Decision | Choice |
|---|---|
| Source granularity | **One source per note** — identical to the Files connector. The user picks individual notes; no vault-level source, no implicit whole-vault import. |
| Engine / schema impact | **None.** Created sources use the existing pipeline untouched, with `connector = 'obsidian'` (column already exists) for grouping and badging. |
| Card detection | Passive and cheap: read `obsidian.json`, count `*.md` per vault (async, cached). The card advertises **Detected · n vaults · n notes** before any click. |
| Selection UI | A **note-picker sheet** (Localmem's own, not `NSOpenPanel`): checkbox tree per vault, ignore rules pre-applied, folder rows tri-state for bulk-ticking, filter box, already-imported notes shown ✓/disabled. "Add more notes" reopens the same sheet. |
| Sync | None — same gesture-driven model. Per-note Reprocess uses the existing hash short-circuit. |
| Markdown normalization | Generic `.md` hygiene (strip YAML frontmatter, flatten `[[wikilink\|alias]]`, drop `%%comments%%`) lives in `FileReader`'s markdown path so plain `.md` files benefit too. Only the frontmatter-**tags** carry-over (into extracted facts' tags) is Obsidian-aware. |

## Card states

```
┌─────────────────────────────┐  ┌─────────────────────────────┐  ┌─────────────────────────────┐
│ 📓 Obsidian                 │  │ 📓 Obsidian                 │  │ 📓 Obsidian                 │
│    [Detected]               │  │    [Not detected]           │  │    [Connected]              │
│ 2 vaults · 214 notes found  │  │ Install Obsidian, or point  │  │ 31 notes · 92 facts         │
│                             │  │ Localmem at a vault folder. │  │                             │
│ [＋ Import notes…]          │  │ [Choose vault folder…]      │  │ [＋ Import…]  [⚙ Manage]   │
└─────────────────────────────┘  └─────────────────────────────┘  └─────────────────────────────┘
```

The manual fallback validates that the picked folder contains `.obsidian/`.

## Note picker (the one new surface)

Backend choice is shared with Files; the picker replaces the open panel:

```
┌──────────────────────────────────────────────────┐
│ Import from Obsidian              🔎 filter…     │
│ ▾ 📓 Personal (142 notes)                        │
│   ▾ ◪ 📁 journal            (12 of 38 selected)  │
│       ☑ 2026-07-10.md                            │
│       ☐ 2026-07-09.md                            │
│   ▸ ☑ 📁 people                                  │
│     ☑ goals.md                                   │
│     ✓ health.md              already imported    │
│ ▸ 📓 Work (72 notes)                             │
│ .obsidian, .trash, attachments hidden            │
│ [Cancel]                    [Import 31 notes]    │
└──────────────────────────────────────────────────┘
```

Ticking a folder is bulk selection, but still an explicit selection — the
deliberate-curation principle carries over unchanged, and it bounds volume
(and agent-backend cost) without any new guardrails.

## Detail view

Imported notes appear in the same split-pane view, grouped under a vault
header row in the left pane (derived by walking up from the note's path to the
`.obsidian` root — not stored). Per-note status, Reprocess, and Remove work
exactly as for files.

## New components (work breakdown)

1. **`ObsidianVaults`** (core) — vault discovery from `obsidian.json` + iCloud
   path; note enumeration with vault ignore rules; note counts for the card.
2. **Markdown normalization** (core, `FileReader`) — frontmatter strip,
   wikilink flattening, comment removal; frontmatter `tags` surfaced to the
   extraction context.
3. **Note-picker sheet + card detection states** (app).
4. **`connector` badging/grouping** in the detail view's left pane (app).
5. **Tests** — vault fixture (`.obsidian/`, `.trash/`, frontmatter notes),
   normalization, picker exclusion of ignored dirs, already-imported marking,
   per-note incremental reprocess.
