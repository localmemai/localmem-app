# Localmem UI Design

> Native macOS app for Localmem. Distributed via direct download, Homebrew cask, and (eventually) the Mac App Store. Built in SwiftUI, links `LocalmemCore` so the GUI, CLI, and MCP server all read/write the same SQLite database.

## 1. Design language

Apple-native. Lean on system primitives so the app feels at home next to Notes, Mail, and Reminders:

- **Window chrome.** Translucent unified toolbar (`NSWindow.titleVisibility = .hidden`), full-height sidebar, vibrancy materials.
- **Typography.** SF Pro across the board. Titles use `.title3.weight(.semibold)`; sidebar rows use `.body`; metadata uses `.footnote.foregroundStyle(.secondary)`.
- **Spacing.** 8pt grid. Sidebar rows 44pt tall. Editor padding 24pt.
- **Color.** Default to system accent + neutral grays. Source color dots (see §6) are the only saturated hues in the chrome. Dark mode is first-class — no custom palette.
- **Motion.** SwiftUI defaults only. Sheet for Add Memory, popover for status bar detail, sidebar for settings. No bespoke animations.

## 2. Window anatomy

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ⚙︎  Localmem                       [ 🔎 Search memories…        ]      [ + ] │  ← toolbar
├──────────────────────┬──────────────────────────────────────────────────────┤
│ ┌──────────────────┐ │                                                      │
│ │ 🔎 Search…       │ │   Coffee preference                                  │
│ └──────────────────┘ │   ─────────────────                                  │
│  Tags  [all ▾]       │   ● You · preference · 3 days ago · updated today    │
│                      │                                                      │
│ ● Coffee preference  │   Flat white with oat milk.                          │
│ ● Localmem casing    │                                                      │
│ ● Modern frameworks  │                                                      │
│ ◐ Activity log path  │                                                      │
│ ● Auth rewrite ctx   │   #preferences  #drinks                              │
│ ◑ Linear INGEST ref  │                                                      │
│                      │   ┌──────┐ ┌────────┐ ┌────────────┐                 │
│                      │   │ Edit │ │ Delete │ │ Audit trail│                 │
│                      │   └──────┘ └────────┘ └────────────┘                 │
│                      │                                                      │
├──────────────────────┴──────────────────────────────────────────────────────┤
│ ● Connected: claude-code, cursor    last access 2s ago    47 memories   ▴   │  ← status bar
└─────────────────────────────────────────────────────────────────────────────┘
```

Three panes, one toolbar, one status bar. The split view is resizable, persisted across launches.

## 3. First-run setup wizard

Triggered when `~/.localmem/db.sqlite` is missing or `MemoryStore` has zero rows AND no clients configured. Modal sheet, can't be dismissed except by Quit or Finish. Five steps, each with **Back / Continue**:

| # | Step | Content |
|---|------|---------|
| 1 | **Welcome** | App icon, "Persistent memory for your AI agents." One-paragraph pitch. "Get started" button. |
| 2 | **Choose data location** | Default `~/.localmem`. "Choose…" picker for a custom path. Inline note explaining the directory is user-level and not synced unless they put it in iCloud Drive themselves. |
| 3 | **Connect your agents** | Auto-detects installed clients: Claude Code, Claude Desktop, Cursor, Zed, Codex. Each row has a checkbox + status (`Detected`, `Not installed`, `Already configured`). Continue writes the MCP config for each ticked client. |
| 4 | **Test it works** | Writes one seed memory ("Hello from Localmem"). Live tail of activity rows — when the daemon reports a successful `memory_store` from the GUI itself, the step turns green. If no daemon connection in 5s, show a "Retry" button and a "Skip" link. |
| 5 | **You're set** | Summary: data location, configured clients, test result. "Open Localmem" closes the sheet. |

The wizard is **re-runnable** from Settings → General → "Re-run setup…". This is the user's stated escape hatch when something breaks.

## 4. Sidebar (left pane)

Width 240pt, min 200, max 360.

- **Search field** at the top. Live-filters as you type, calls `MemoryStore.search()` (FTS). Cmd-F focuses it.
- **Tag chips** below search, horizontally scrollable. `[all ▾]` is a multi-select dropdown — placeholder until filters land, but the chip row is already wired so adding filters later doesn't reshuffle the layout.
- **Memory list** — each row is just the title + a source dot (§6) + optional secondary line for type. No preview text — keep it tight like Notes' sidebar:

  ```
  ● Coffee preference
  ◐ Activity log path schema
  ● Modern frameworks preference
  ```

  - Untitled memories fall back to the first ~40 chars of `content`, italicized.
  - Right-click context menu: **Open**, **Edit**, **Duplicate**, **Copy ID**, **Delete**.
  - Multi-select with ⌘-click for bulk delete.

## 5. Detail pane (middle / main)

Selected memory fills this pane. If nothing's selected, show an empty state ("Select a memory or press ⌘N to create one").

Layout top to bottom:

1. **Title** — large, editable inline on double-click.
2. **Metadata strip** — single line, `.footnote`:
   `● Source · type · created relative · updated relative`
   Hover the timestamps to see absolute datetimes in a tooltip.
3. **Content** — full text, monospace optional via View menu, wrapping. Inline edit on click-to-focus; saves on blur or ⌘S.
4. **Tags** — chip row, `+` chip to add. Backspace removes the last chip.
5. **Action bar** at the bottom of the pane — `Edit`, `Delete`, `Audit trail`, and (placeholder, dimmed) `Access…`. `Delete` requires confirm.

### 5a. Audit trail

Clicking **Audit trail** slides a right inspector panel (320pt wide) over the detail pane:

```
┌────────────────────────────────┐
│ Audit trail — Coffee pref   ✕  │
├────────────────────────────────┤
│ TODAY                          │
│  ● claude-code · read · 9:14   │
│  ● .user · update · 9:02       │
│ YESTERDAY                      │
│  ● cursor · read · 18:33       │
│  ● claude-code · read · 14:01  │
│  …                             │
│                                │
│ [ Export CSV ]   [ Clear log ] │
└────────────────────────────────┘
```

Rows come from `ActivityStore` filtered by `memory_id`. Source dot reuses §6's color. **Clear log** is gated behind a confirm and only clears entries for this memory.

## 6. Source color coding

Each memory carries `source: String?` (already present on `Memory`). The dot color is derived deterministically:

| Source | Dot |
|---|---|
| `.user` (CLI or GUI by the human) | **Blue** — system accent |
| `claude-code`, `claude-desktop` | **Orange** |
| `cursor` | **Purple** |
| `chatgpt`, `codex` | **Green** |
| Any other client | **Gray** |
| Unknown / null | **Hollow gray ring** |

Mapping lives in a single `SourcePalette` enum in the GUI target. Unknown sources hash to one of three muted neutrals so power users with custom clients still see *some* differentiation. Hover the dot to see the literal source string.

The same dot color is reused in the audit trail rows and in the status bar's "connected clients" list — one visual language across the app.

## 7. Toolbar

```
[ ⚙︎ ]        [ 🔎 Search memories… ]                                    [ + ]
```

- **Left: ⚙︎ Settings** — opens the Settings window (§9). Not a popover; a real `Settings` scene (`SettingsLink` on macOS 14+).
- **Center: search field** — duplicates the sidebar search but global; useful when sidebar is collapsed. Cmd-F focuses whichever is visible.
- **Right: +** — opens the Add Memory sheet (§8). Cmd-N also works.

## 8. Add Memory sheet

Modal sheet, ~560pt × 480pt, dimmed background. Fields top to bottom:

```
┌───────────────────────────────────────────────────┐
│ New memory                                        │
├───────────────────────────────────────────────────┤
│ Title          [______________________________]   │
│ Type           [ preference ▾ ]                   │
│ Content                                           │
│  ┌─────────────────────────────────────────────┐  │
│  │                                             │  │
│  │                                             │  │
│  │                                             │  │
│  └─────────────────────────────────────────────┘  │
│ Tags           [+ add tag]  #drinks  #morning     │
│                                                   │
│ ▸ Access control                  (coming soon)   │
│                                                   │
│              [ Cancel ]      [ Save memory ]      │
└───────────────────────────────────────────────────┘
```

- `Save memory` is disabled until `content` is non-empty.
- Source is hard-coded to `.user` for GUI writes — same convention as the CLI.
- Access control disclosure group is rendered but disabled with a "coming soon" caption — reserves the layout for when per-memory ACLs ship.
- Esc cancels, Cmd-S saves.

## 9. Settings window

Standard macOS Settings scene with tabs:

| Tab | Contents |
|---|---|
| **General** | Launch at login · Show in menu bar · Theme (System / Light / Dark) · "Re-run setup wizard…" button |
| **Access control** | Two sections. **Per-source rules** — a table of `source → read/write` defaults (e.g. block `cursor` from reading `preference`s). **Per-memory overrides** — list of memories with custom ACLs, click to edit. Disabled until the feature lands; show a "Preview — not enforced yet" banner. |
| **Data** | DB path · open in Finder · disk usage · Export all (JSON) · Import · Vacuum DB |
| **Clients** | Same auto-detect grid from the wizard step 3, re-runnable. Per-client: status, last access, "Disconnect" / "Reconfigure" |
| **About** | Version, GitHub link, "Send feedback" mailto |

## 10. Status bar

Always visible, 28pt tall, system material:

```
● Connected: claude-code, cursor    last access 2s ago    47 memories    ▴
```

- **Leading dot.** Green = daemon healthy, yellow = degraded (e.g. one client failing handshake), red = daemon down.
- **Connected clients.** Comma-separated, capped at 3 with `+N` overflow. Each name uses its source color.
- **Last access.** Relative time, ticks every second.
- **Memory count.** Total rows.
- **Trailing ▴.** Click anywhere on the bar to open a popover with full status (§10a).

### 10a. Status popover

```
┌──────────────────────────────────────────────┐
│ Localmem status                              │
│ ● Daemon healthy · uptime 4h 12m             │
│ DB ~/.localmem/db.sqlite · 1.2 MB            │
│                                              │
│ Connected clients                            │
│  ● claude-code   last access 2s ago          │
│  ● cursor        last access 1m ago          │
│  ● chatgpt       last access 14m ago         │
│                                              │
│ Recent activity                              │
│  9:14  claude-code · read · Coffee pref      │
│  9:12  .user       · write · Auth rewrite    │
│  9:08  cursor      · search · "logging"      │
│  …                                           │
│                                              │
│ [ Restart daemon ]   [ Open logs ]           │
└──────────────────────────────────────────────┘
```

Recent activity is the last 10 `Activity` rows. "Restart daemon" only appears when status ≠ healthy.

## 11. Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New memory |
| ⌘F | Focus search |
| ⌘⌫ | Delete selected memory (with confirm) |
| ⌘S | Save inline edits |
| ⌘, | Settings |
| ⌘1 | Toggle sidebar |
| ⌘2 | Toggle audit inspector |

## 12. Empty / error states

- **No memories yet** (post-wizard, before any agent writes): centered illustration + "Ask any connected agent to remember something, or press ⌘N."
- **Daemon down.** Status dot red; a non-blocking banner appears above the detail pane with "Localmem daemon isn't running. [Restart]". The list stays usable (reads from the local DB directly).
- **DB locked / migration mid-flight.** Spinner overlay; auto-clears when `MemoryStore` reports ready.

## 13. Out of scope for v1 (designed-around, not built)

- Tag filter UI (the chip row is wired, the dropdown is a placeholder).
- Per-memory access control enforcement (UI surfaces exist, dimmed/labeled).
- iCloud sync / multi-device.
- Memory diff / version history beyond the audit log.

These are reserved layout-wise so adding them later is purely additive — no rework of the chrome.

## 14. Open questions

1. **Daemon ownership.** Should the GUI launch `localmem-mcp` itself (LaunchAgent on first run) or assume it's already configured by the wizard? Leaning toward the GUI managing a LaunchAgent so "quit the app, daemon stops" matches user expectation.
2. **Source-string normalization.** `SourcePalette` needs a canonical mapping. Worth a small `KnownClient` enum in `LocalmemCore` so CLI, MCP, and GUI agree.
3. **Audit log retention.** Currently unbounded — add a Data-tab setting ("Keep activity for: 30d / 90d / forever")?
