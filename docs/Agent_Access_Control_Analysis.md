# Design: Folders, Visibility, and Agent Access

Every memory lives in exactly one folder. The folder decides which agents can
read it. Everything defaults open, so the feature is invisible until someone
wants it.

This supersedes the earlier options comparison (manual denylists vs. visual-only
spaces vs. `cwd` routing vs. no access control). That draft rated the existing
per-memory denylist as "high security" and recommended directory routing on
privacy grounds; neither claim survives the fact that agent identity is
self-reported — see [Limits](#limits) below.

---

## Two problems, one mechanism

| | Problem | Solved by |
| :--- | :--- | :--- |
| **Organisation** | A flat vault is unreviewable. One document import yields hundreds of memories; one agent session yields dozens. | Every memory lives in exactly one folder. |
| **Sensitivity** | Some memories should only be readable by agents the user trusts. | The folder carries a sensitive flag; agents carry a status. |

These share a mechanism because the folder is the unit the user already has to
think about for organisation. A second, independent classification axis would be
a second thing to maintain, and the previous design failed exactly there: the
per-memory denylist costs one decision per memory per agent, a cost that grows
with the product's own success.

---

## The model

### Folders

* A memory is **always** in exactly one folder. There is no unfiled state.
* Folders are **flat**. No nesting, no sub-hierarchy.
* Every vault has a **default folder** (`Inbox`). It is permanently *not
  sensitive*, cannot be renamed or deleted, and guarantees a safe home always
  exists — a user cannot accidentally hide their entire vault.
* Every other folder is **not sensitive** (default) or **sensitive**.
* Selecting a folder in the sidebar opens its settings in the right pane.

Because visibility is a property of the folder, a memory carries no visibility
state of its own. Moving a memory between folders *is* how it gets reclassified,
and moving a selection is how you reclassify in bulk. There is no per-memory
override, and therefore no inherited-versus-explicit distinction to reconcile.

### Agents

* Every agent has a status: **all** (default) or **non-sensitive only**.
* New agents **always** arrive as *all*, regardless of what the vault already
  contains. The reverse default produces a worse failure: a newly installed tool
  that silently retrieves nothing, with no visible cause.
* Nobody is prompted at setup. The status exists with a safe default; advanced
  users change it in the agent list.

### The access rule

An agent with status **all** reads everything. An agent with status
**non-sensitive only** reads every folder except those marked sensitive. That is
the entire rule.

---

## How memories reach a folder

| Origin | Folder | Sensitivity |
| :--- | :--- | :--- |
| **Agent, in a project** | The project's folder, keyed on git root. Created on first write if absent. | Not sensitive |
| **Agent, no project** (e.g. a desktop chat) | `Inbox` | Not sensitive |
| **Document import** | New folder named after the source, pre-filled and editable in the import dialog | User's choice, defaulting open |
| **Companion app** | The connector's folder, selectable at connect time | User's choice, defaulting open |
| **Manual entry (app/CLI)** | User picks; defaults to `Inbox` | Follows the folder |

Nothing here prompts, blocks, or infers sensitivity from content.

**Project folders are keyed on the git root path, not the repository name** —
otherwise `~/work/acme/api` and `~/personal/api` collapse into one folder with
mixed sensitivity. The short name is displayed, disambiguated only on collision.

---

## Why this is a no-op for most users

Every default requires no action: all folders start not sensitive, all agents
start with full access, auto-created folders need no decision, and there is no
prompt at setup, at import, at connect, or at agent write time.

A user who never opens folder settings sees a sidebar that is better organised
than today's flat list, and nothing else. Every agent still reads every memory.
The sensitivity feature is invisible until someone marks a folder — at which
point it applies to that folder and nothing else.

Advanced users never work memory-by-memory either. They mark a *folder*, and
every memory in it — present and future — follows.

---

## What this removes

The per-memory agent denylist goes away entirely. It is the friction this design
exists to eliminate, and keeping it alongside folders would ship two competing
ways to control access.

Half-measures are worse than either extreme here: removing only the UI while
keeping the predicate would leave surviving exclusions as invisible filters with
no way to inspect or clear them. "Why can't this agent see this memory?" would
have no answer anywhere in the product.

**Deleted:** `memory_agent_exclusions` and its filter fragments in
`MemoryStore`; `setExclusion`, `clearExclusions`, and the bulk insert;
`Memory.excludedAgents`; the app's per-memory agent editor and its
`preservedExclusions` machinery; the blocked-vs-not-found branch in
`handleUpdate`; the associated tests.

**Re-pointed, not deleted:** `blockedSearchCount` / `blockedRecentCount`, the
`withheld:` result field, and the `access_filtered` activity row. A restricted
agent should still be told that results were held back — only the predicate
changes, from "excluded for this agent" to "folder is sensitive and this agent is
restricted."

**Kept:** `KnownAgents`, repurposed from populating exclusion checkboxes to
backing the agent status list.

Exclusions are only ever *created* from the app UI — there is no CLI command, and
`memory_store` never exposed them over MCP. No agent-facing contract breaks, and
the removal is contained to `LocalmemCore`, the app, and tests. Do it in the same
release as folders, so there is never a build where access control is
half-present.

---

## Migration

There are one or two existing vaults. The migration is sized accordingly.

1. Create `Inbox` at a fixed, well-known UUID.
2. One folder per distinct **parent directory** of sources that have linked
   memories, named after the leaf directory.
3. Everything else goes to `Inbox`.
4. Every folder not sensitive; every agent *all*.
5. `DROP TABLE memory_agent_exclusions` — no conversion.

Single transaction, forward-only. Historical `access_revoke` / `access_grant`
rows stay in `activity`: this drops the mechanism, not the record of how it was
used.

**Grouping by parent directory, not by source file**, is what keeps folder counts
sane. `sources` holds one row per file, so per-file folders would turn a 60-file
import into 60 folders. On the reference vault (106 memories, 11 sources) the
result is four folders plus `Inbox`.

**Every folder is created not sensitive**, including folders that plainly hold
private documents. Marking them during migration would make agents stop seeing
memories they could read the day before. The user decides afterwards, prompted
once by a post-upgrade dialog that reports what happened, states plainly that
nothing about access has changed, and offers a single door into folder settings.
Suppress that dialog when migration created no folders.

Dropping exclusions outright does grant access that was previously denied — on
the reference vault, one memory becomes readable by `antigravity-client`. At this
scale that is a known, accepted trade for deleting the mechanism cleanly. It
would not be at a thousand vaults.

### What migration cannot do

**Projects are unrecoverable.** The `source` column holds the writing agent
(`claude-code`, `codex`), not a path, and `activity` records `actor_id` with no
working directory. No existing memory can be assigned to a project folder; those
rows stay in `Inbox`, and only new writes get filed by project. Nothing needs to
be built for this — it simply cannot be done.

### Use a fixed UUID for `Inbox`

Not a generated one. It lets `folder_id` carry a SQL `DEFAULT`, which matters
because the registrars write absolute binary paths: a user can upgrade the app
while a stale `localmem-mcp` binary stays registered. With a constant default, an
old writer that knows nothing about folders still produces valid rows that land
in `Inbox` instead of violating a NOT NULL constraint.

---

## Relationship to §4 and the cut routing feature

[Issue #24](https://github.com/localmemai/localmem-app/issues/24) and
[§4 of the v2 roadmap](v2_Roadmap_Proposal.md) originally carried this
constraint:

> Grouping is display-only; it never scopes what an agent retrieves.

**This design amends it:**

> Grouping never scopes retrieval **by default**. It scopes retrieval only where
> the user has explicitly marked a folder sensitive *and* explicitly restricted
> an agent. Both are deliberate acts; either alone changes nothing.

§7's cut of `cwd` → Space routing still stands and does not apply here. That
feature scoped retrieval by *project context*, so an agent working in repo A
would stop seeing repo B — fragmenting cross-project recall, which is the
product's core thesis, and breaking chains that span several directories. This
design scopes by *sensitivity*, which is orthogonal to project: an agent with
status **all** — the default, and the state of every agent until a user
intervenes — retains complete cross-project recall no matter how many folders
exist.

§4's **Group by Origin / Type / Tag** toggle survives as a display-time *view*.
Folder membership is the containment relation and the visibility carrier; type
and tag remain groupings over it.

---

## Open items

1. **Folder sprawl.** Flat plus auto-creation means an active developer
   accumulates dozens of project folders within a year — the review problem
   moved up one level. Needs **merge** and **rename**, plus sorting by recency
   and size. Merge matters most: it is how stale project folders collapse into
   one archive folder in a single action.
2. **Terminology.** Folders are *sensitive / not sensitive*; agents are
   *all / non-sensitive only*. Fix this in schema and UI copy now — "visibility"
   is the word most likely to end up meaning both and neither.

---

## Limits

Agent identity is **self-reported**. `MCPClientIdentity` takes the client's name
from its own `initialize` handshake, with an environment-variable fallback
(`Sources/localmem-mcp/MCPClientIdentity.swift`). Any local process can claim to
be an agent with **all** status.

The honest promise of this feature is therefore **"restricted agents stay in
their lane"** — it stops a trusted but overbroad tool from surfacing memories you
would rather it did not. It is *not* a defence against a malicious local program,
and neither the UI copy nor the documentation should imply otherwise.

Closing that gap is separate, orthogonal work: a per-client secret provisioned at
setup and verified server-side, instead of trusting a self-asserted name.
`localmem setup` already writes and merges keys into each client's MCP config
block, so the mechanism exists — but it should be scoped and argued on its own
merits, not assumed as a side effect of folders.
