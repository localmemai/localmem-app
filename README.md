<div align="center">

# Localmem

**Persistent memory for your AI agents.**

Localmem is private, file-based memory that lets your AI agents recall context
across every conversation and project — over the [Model Context Protocol][mcp],
all on your machine. Open-source core, macOS-native.

[localmem.ai][site]

[![Core license: Apache 2.0](https://img.shields.io/badge/Core-Apache_2.0-blue.svg)](LICENSING.md)
[![App license: FSL-1.1-ALv2](https://img.shields.io/badge/App-FSL--1.1--ALv2-blue.svg)](LICENSING.md)
[![CI](https://github.com/localmemai/localmem-app/actions/workflows/ci.yml/badge.svg)](https://github.com/localmemai/localmem-app/actions/workflows/ci.yml)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#getting-started)

</div>

> **Status:** early and under active development. macOS-only.
> Signed & notarized builds are on the [releases page][releases].

---

## What it is

AI agents forget everything the moment a conversation ends. Localmem gives them
a memory that stays: a local SQLite store your agents read from and write to
over MCP, so a preference you state in one session — or a decision you make in
one project — is there in every session after, across every project.

Memory is **user-level and cross-project**. A fact stored in one repo's session
is visible from every other repo's session. Nothing leaves your Mac: no account,
no server, no cloud.

Three surfaces sit on top of one shared `LocalmemCore` engine, so the app, the
CLI, and the MCP server all read and write the same database with identical
search, permissions, and audit behavior:

| Binary | Role |
|---|---|
| `localmem-app` | The SwiftUI vault app — browse memory, manage agent access, review the audit log |
| `localmem` | The command-line tool — `setup`, `add`, `search`, `list`, and more |
| `localmem-mcp` | The MCP server your AI clients actually talk to |

## Features

- **Local and file-based.** Memory lives in a SQLite database on your machine.
  No account, no backend, no sync required.
- **Cross-project by design.** One memory store, shared across every repo and
  every agent session.
- **Full-text search** over every memory via SQLite FTS5.
- **Per-agent access control.** Grant or revoke each connected agent's access to
  individual memories.
- **Audit log.** Every read, search, and write is attributed to the agent that
  made it and recorded so you can see what was accessed.
- **Import from your files.** Pick Text, Markdown, or PDF files and Localmem
  extracts the key facts into memories — on-device via Apple Intelligence when
  available, otherwise through a CLI agent you already use (Claude Code or
  Codex). Every candidate fact is then verified against the source document
  before anything is stored, and each file shows its "N extracted → M kept"
  tally. You choose every file; nothing is scanned automatically.
- **One-command setup.** `localmem setup` registers the MCP server with every
  installed client. Your client asks you to approve Localmem's tools the first
  time an agent uses them — approve it once. (Pass `--preauthorize` to skip that
  prompt if you'd rather auto-approve.)

### MCP tools

Agents interact with Localmem through five tools:

- `memory_store` — persist a new fact, preference, or decision. Supports optional `supersedes` parameter to deprecate older entries.
- `memory_search` — full-text search over stored memories (returns compact metadata without verbatim body).
- `memory_recent` — most-recent-first listing (returns compact metadata without verbatim body).
- `memory_get` — retrieve the full verbatim body for a set of memory IDs, with their supersession edges.
- `memory_update` — replace fields on an existing memory, including its `supersedes` edges.

### Supported clients

Setup auto-detects and registers Localmem with:

- Claude Code
- Claude Desktop
- Cursor
- Codex
- Antigravity

## Getting started

Localmem is macOS-only (macOS 26+, Apple Silicon & Intel).

**Download:** grab the signed, notarized DMG from the [releases page][releases]
(or [localmem.ai][site]), drag Localmem to Applications, and launch. The setup
wizard connects your installed AI clients and can add the `localmem` CLI to
your PATH in one click.

**Or build from source:**

```sh
git clone https://github.com/localmemai/localmem-app.git
cd localmem-app
swift build

# Register the MCP server with every installed AI client
swift run localmem setup
```

Once setup finishes, restart your AI clients and they'll have Localmem
available. Try telling one "remember that I prefer flat whites" — then ask a
fresh session in another project what you like to drink.

Homebrew and a curl installer are planned as additional channels.

## CLI

The `localmem` command is the pro-user and debugging surface:

| Command | Description |
|---|---|
| `localmem setup` | Register the MCP server with all installed clients |
| `localmem add` | Add a memory |
| `localmem search` | Full-text search |
| `localmem list` | List recent memories |
| `localmem show` | Show a single memory |
| `localmem update` | Edit a memory |
| `localmem delete` | Remove a memory |
| `localmem status` | Show store and registration status |
| `localmem path` | Print the database path |

Run `localmem --help` for the full command set.

## Architecture

Localmem is a single Swift package. `LocalmemCore` owns memory CRUD, search,
per-agent permissions, and audit logging; the app, CLI, and MCP server are thin
surfaces over it. Storage is SQLite via [GRDB][grdb] with an FTS5 index for
search. The MCP server is built on the official [Swift MCP SDK][swift-sdk].

The full architecture, data model, security model, access control, app UI, and
distribution plan live in the [technical design](docs/Technical_Design.md).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Localmem is open-core — see [LICENSING.md](LICENSING.md) for the full picture:

- **Core, CLI, and MCP server** — [Apache 2.0](LICENSE). Everything that
  touches your memories is fully open source.
- **macOS app** (`Sources/localmem-app`) —
  [FSL-1.1-ALv2](Sources/localmem-app/LICENSE.md): source-available so you can
  verify everything stays on your device; free to use and contribute to; no
  competing use. Each release converts to Apache 2.0 after two years.

[mcp]: https://modelcontextprotocol.io
[site]: https://localmem.ai
[releases]: https://github.com/localmemai/localmem-app/releases/latest
[grdb]: https://github.com/groue/GRDB.swift
[swift-sdk]: https://github.com/modelcontextprotocol/swift-sdk
