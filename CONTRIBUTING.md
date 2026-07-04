# Contributing to Localmem

Thanks for your interest in improving Localmem. This guide covers how to build
the project, the conventions we follow, and how to get a change merged.

## Prerequisites

Localmem is a **macOS-only** product. To build it you'll need:

- macOS 26 or later
- A recent Swift toolchain (the package targets `swift-tools-version: 6.2`)
- Xcode command-line tools

## Building and testing

Localmem is a single Swift package with three executable products and a shared
core library.

```sh
# Build everything
swift build

# Run the full test suite
swift test

# Run a specific surface
swift run localmem --help
swift run localmem-app
```

Please run `swift test` before opening a pull request and make sure the suite
passes. If you add or change behavior, add tests alongside it — coverage lives
in [`Tests/`](Tests/).

## Project layout

Everything sits on top of one shared core so the app, CLI, and MCP server never
diverge:

- `Sources/LocalmemCore` — memory CRUD, search, permissions, audit logging. All
  real logic lives here.
- `Sources/localmem` — the command-line tool.
- `Sources/localmem-mcp` — the MCP server AI clients talk to.
- `Sources/localmem-app` — the SwiftUI vault app.
- `docs/` — design documents.

When you add behavior, put it in `LocalmemCore` and expose it through the
surfaces, rather than duplicating logic in a single binary.

## Conventions

- **Match the surrounding code.** Follow the naming, structure, and comment
  density already in the file you're editing.
- **The brand name is "Localmem"** — lowercase `m`, never "LocalMem".
- **Keep it local-first.** Localmem does not require an account, a server, or the
  network. Changes should preserve that.

## Pull requests

1. Fork the repo and create a branch for your change.
2. Keep each PR focused on a single concern.
3. Make sure `swift build` and `swift test` both pass.
4. Write a clear description of what changed and why.

For anything large or architectural, open an issue first so we can discuss the
approach before you invest the work.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE), the same license that covers the project.
