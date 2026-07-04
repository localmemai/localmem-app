<div align="center">

# Localmem

**Persistent memory for your AI agents.**

Localmem is private, file-based memory that lets your AI agents recall context
across every conversation and project — over the [Model Context Protocol][mcp],
all on your machine. Open source, macOS-native.

[localmem.ai][site]

</div>

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
- **One-command setup.** `localmem setup` registers the MCP server with every
  installed client and pre-authorizes its tools so agents don't prompt on every
  call.

### MCP tools

Agents interact with Localmem through four tools:

- `memory_store` — persist a new fact, preference, or decision
- `memory_search` — full-text search over stored memories
- `memory_recent` — most-recent-first listing
- `memory_update` — replace fields on an existing memory

### Supported clients

Setup auto-detects and registers Localmem with:

- Claude Code
- Claude Desktop
- Cursor
- Codex
- Antigravity

## Getting started

Localmem is macOS-only.

```sh
# Build from source
git clone https://github.com/localmem-ai/localmem-app.git
cd localmem-app
swift build

# Register the MCP server with every installed AI client
swift run localmem setup
```

Once setup finishes, restart your AI clients and they'll have Localmem
available. Try telling one "remember that I prefer flat whites" — then ask a
fresh session in another project what you like to drink.

Packaged downloads (signed DMG and a Homebrew formula) are on the way — see
[localmem.ai][site].

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

Licensed under the [Apache License 2.0](LICENSE).

[mcp]: https://modelcontextprotocol.io
[site]: https://localmem.ai
[grdb]: https://github.com/groue/GRDB.swift
[swift-sdk]: https://github.com/modelcontextprotocol/swift-sdk
