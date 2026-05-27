# LocalMem `setup` Subcommand - Step-by-Step Build Guide

A step-by-step guide for building `localmem setup` — a single command that detects every installed MCP client on the user's machine and registers `localmem-mcp` with each one, without the user ever editing a config file by hand.

Same format as the V1 build guide: each step has **Goal / Why / Do / Verify**.

## Target user experience

```bash
$ localmem setup

LocalMem — installing MCP integration
========================================================
✓  Claude Code         registered (via CLI)
✓  Codex               registered (via config file)
✓  Claude Desktop      registered (via config file)
✓  Antigravity         registered (via config file)
–  Cursor              not installed — skipped
--------------------------------------------------------
4 registered · 1 skipped · 0 failed

Restart any open Claude / Codex / Antigravity / Cursor sessions
to pick up the new MCP server.
```

`setup` is **idempotent** — re-running produces the same result. It never overwrites unrelated MCP servers the user already configured. If a client isn't installed, `setup` skips it cleanly.

## The dual-strategy pattern (read this first)

Each MCP client falls into one of two categories:

1. **Has a CLI** for managing MCP registration (Claude Code's `claude mcp add`, Codex's `codex mcp add`). Using the CLI is preferred because it handles validation, scope semantics, and config schema variation across versions.
2. **No CLI** — config-file edit is the only path (Claude Desktop, Antigravity, Cursor).

But many users with category-1 clients only install the **IDE/desktop app** and skip the CLI. We can't leave those users without integration.

**The pattern:** every registrar declares whether it has a CLI. The framework tries the CLI first. If the CLI isn't on PATH (or it fails), it transparently falls back to direct config-file edit. One protocol, two strategies, framework picks.

```
                 ┌────────────────────────────┐
                 │   ClientRegistrar.register │  ← default impl in protocol extension
                 └────────────┬───────────────┘
                              │
                ┌─────────────┴─────────────┐
                │  cliCommand on PATH?      │
                └─────┬─────────────────┬───┘
                      │ yes             │ no
                      ▼                 │
              ┌───────────────┐         │
              │ registerViaCLI│ ── fails ───┐
              └───────────────┘             │
                                            ▼
                                    ┌─────────────────────┐
                                    │ registerViaConfigFile│
                                    └─────────────────────┘
```

Each concrete registrar implements one or both methods depending on what's possible:

| Client | `cliCommand` | Implements |
|---|---|---|
| Claude Code | `"claude"` | CLI + file |
| Codex | `"codex"` | CLI + file |
| Claude Desktop | `nil` | file only |
| Antigravity | `nil` | file only |
| Cursor | `nil` | file only |

## Architecture at a glance

```
SetupCommand
    │
    ├── BinaryLocator       — finds the localmem-mcp path to register
    │
    ├── Helpers/
    │   ├── ShellHelper     — Process wrapper for shell-out
    │   ├── JSONConfig      — atomic JSON read-modify-write
    │   └── TOMLConfig      — atomic TOML read-modify-write (TOMLKit)
    │
    ├── ClientRegistrar protocol (+ default `register` strategy)
    │       │
    │       ├── ClaudeCodeRegistrar     (CLI + file)
    │       ├── CodexRegistrar          (CLI + file)
    │       ├── ClaudeDesktopRegistrar  (file)
    │       ├── AntigravityRegistrar    (file)
    │       └── CursorRegistrar         (file)
    │
    └── SetupReport         — pretty status table
```

---

## Phase 1 — Foundation

### Step 1.1 — `BinaryLocator`: find the right `localmem-mcp` path
**Goal:** Resolve the absolute path of the `localmem-mcp` binary that should be registered with each client.

**Why this matters:** MCP clients store the absolute path. If we register `./build/release/localmem-mcp` and then move the binary, every client breaks. We want a stable, portable resolution.

**Strategy:** Use `Bundle.main.executablePath` to find the running `localmem` binary, then look for `localmem-mcp` as a sibling. That works in both dev (where both binaries live in `.build/release/`) and production installs (where both live in `/usr/local/bin/`).

**Do:** Create `Sources/localmem/Setup/BinaryLocator.swift`:

```swift
import Foundation

enum BinaryLocator {
    static func mcpServerPath() throws -> String {
        guard let executablePath = Bundle.main.executablePath else {
            throw SetupError.cannotLocateBinary(reason: "Bundle.main.executablePath is nil")
        }
        let mcpURL = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent("localmem-mcp")

        guard FileManager.default.isExecutableFile(atPath: mcpURL.path) else {
            throw SetupError.cannotLocateBinary(
                reason: "no executable at \(mcpURL.path) (build with `swift build -c release` first)"
            )
        }
        return mcpURL.path
    }
}

enum SetupError: Error, CustomStringConvertible {
    case cannotLocateBinary(reason: String)
    case cliNotSupported(client: String)

    var description: String {
        switch self {
        case .cannotLocateBinary(let reason):
            return "Cannot locate localmem-mcp binary: \(reason)"
        case .cliNotSupported(let client):
            return "\(client) has no CLI-based registration path"
        }
    }
}
```

**Verify:** `swift build` succeeds.

### Step 1.2 — `ClientRegistrar` protocol with default strategy
**Goal:** Define the interface every per-client implementation conforms to, with a default `register(...)` that encodes the "CLI first, file fallback" strategy.

**Why a default implementation:** The CLI-vs-file decision logic lives in one place — the protocol extension. Each concrete registrar only describes *what* its CLI command is and *how* to do each path, never *when* to pick which.

**Do:** Create `Sources/localmem/Setup/ClientRegistrar.swift`:

```swift
import Foundation

protocol ClientRegistrar: Sendable {
    /// Human-readable name shown in the status report.
    var displayName: String { get }

    /// nil if this client has no CLI for managing MCP registrations.
    /// When non-nil, the framework will look for this command on PATH.
    var cliCommand: String? { get }

    /// Returns true if this client looks installed on the machine
    /// (independent of whether its CLI is on PATH).
    func isInstalled() -> Bool

    /// Register localmem via the client's own CLI (`<cli> mcp add ...` etc).
    /// Only invoked when `cliCommand` is non-nil and the command is on PATH.
    func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome

    /// Register localmem by directly editing the client's config file.
    /// Must be implemented by every registrar — it's the fallback.
    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome
}

enum RegistrationOutcome: Sendable {
    case registered(via: Strategy)
    case alreadyRegistered(via: Strategy)
    case updated(via: Strategy)
    case skipped(reason: String)

    enum Strategy: Sendable {
        case cli, configFile
    }
}

extension ClientRegistrar {
    var cliCommand: String? { nil }

    func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome {
        throw SetupError.cliNotSupported(client: displayName)
    }

    /// Default strategy: prefer CLI when present, fall back to file edit otherwise.
    func register(binaryPath: String) throws -> RegistrationOutcome {
        if let cli = cliCommand, ShellHelper.commandExists(cli) {
            do {
                return try registerViaCLI(binaryPath: binaryPath)
            } catch {
                // CLI is present but failed — fall through to file edit.
                return try registerViaConfigFile(binaryPath: binaryPath)
            }
        }
        return try registerViaConfigFile(binaryPath: binaryPath)
    }
}
```

**Verify:** `swift build` succeeds. The protocol references `ShellHelper.commandExists` which we'll write in Step 2.1.

> If the build errors on the missing `ShellHelper` reference, temporarily comment out the `register(...)` default implementation, build, then uncomment it after Step 2.1.

---

## Phase 2 — Foundation helpers

We need three tiny utility modules before we can write any registrar that does real work: a `Process` wrapper for shell-out, a JSON read-modify-write helper, and a TOML one. All three are used in Phase 3 onward.

### Step 2.1 — `ShellHelper`: safe `Process` wrapper
**Goal:** A small wrapper around Foundation's `Process` for invoking external CLIs and inspecting their output.

**Why:** Foundation's `Process` API is verbose and error-prone. Centralizing it gives us consistent PATH lookups, exit-code handling, and stdout/stderr capture across every shell-out.

**Do:** Create `Sources/localmem/Setup/ShellHelper.swift`:

```swift
import Foundation

enum ShellHelper {
    struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    /// Returns true if `command` is found on PATH.
    static func commandExists(_ command: String) -> Bool {
        (try? run("/usr/bin/env", ["which", command]).exitCode) == 0
    }

    @discardableResult
    static func run(_ command: String, _ args: [String]) throws -> Result {
        let process = Process()
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            // Resolve via env so we pick up PATH lookups consistently.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func runOrThrow(_ command: String, _ args: [String]) throws {
        let result = try run(command, args)
        guard result.exitCode == 0 else {
            throw ShellError.commandFailed(
                command: command,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    enum ShellError: Error, CustomStringConvertible {
        case commandFailed(command: String, exitCode: Int32, stderr: String)
        var description: String {
            switch self {
            case .commandFailed(let cmd, let code, let stderr):
                return "\(cmd) exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
```

**Verify:** `swift build` succeeds.

### Step 2.2 — `JSONConfig`: atomic read-modify-write for JSON
**Goal:** Safely load a JSON config file, mutate it, and write it back atomically — without clobbering unrelated entries the user has configured.

**Why atomic:** if `setup` is interrupted mid-write (signal, power loss), the original config stays intact.

**Why read-modify-write:** users often have other MCP servers in the same config file. We must preserve them.

**Do:** Create `Sources/localmem/Setup/JSONConfig.swift`:

```swift
import Foundation

enum JSONConfig {
    /// Reads a JSON object from disk (empty if missing), applies `transform`, writes atomically.
    /// Creates parent directories if needed. Returns `true` if file content changed.
    @discardableResult
    static func update(at url: URL, transform: ([String: Any]) -> [String: Any]) throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var current: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                current = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
        }

        let next = transform(current)
        let nextData = try JSONSerialization.data(
            withJSONObject: next,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Skip rewrite if structurally identical.
        if FileManager.default.fileExists(atPath: url.path) {
            let currentData = try Data(contentsOf: url)
            let currentNormalized = (try? JSONSerialization.data(
                withJSONObject: try JSONSerialization.jsonObject(with: currentData),
                options: [.prettyPrinted, .sortedKeys]
            )) ?? currentData
            if currentNormalized == nextData { return false }
        }

        // Atomic write: temp file in the same dir, then replace.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try nextData.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        return true
    }
}
```

**Verify:** `swift build` succeeds.

### Step 2.3 — Add TOMLKit dependency + `TOMLConfig` helper
**Goal:** Same atomic read-modify-write semantics as `JSONConfig`, but for TOML files (Codex uses TOML).

**Why TOMLKit:** Swift has no built-in TOML parser. [TOMLKit](https://github.com/LebJe/TOMLKit) is pure Swift, well-maintained, and **preserves comments and formatting on round-trip** — important since users may have hand-edited their config.

**Do, part 1 — add the dependency** in `Package.swift`. In `dependencies:`:

```swift
.package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
```

In the `localmem` target's `dependencies:`:

```swift
.product(name: "TOMLKit", package: "TOMLKit"),
```

Run `swift package resolve` to fetch it.

**Do, part 2 — create the helper.** `Sources/localmem/Setup/TOMLConfig.swift`:

```swift
import Foundation
import TOMLKit

enum TOMLConfig {
    /// Reads a TOML document from disk (empty if missing), applies `transform`, writes atomically.
    /// Preserves comments and existing formatting where TOMLKit can.
    /// Returns `true` if content changed.
    @discardableResult
    static func update(at url: URL, transform: (inout TOMLTable) -> Void) throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var table: TOMLTable
        let originalText: String?
        if FileManager.default.fileExists(atPath: url.path) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            originalText = raw
            table = try TOMLTable(string: raw)
        } else {
            originalText = nil
            table = TOMLTable()
        }

        transform(&table)
        let nextText = table.convert()

        if originalText == nextText { return false }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try nextText.write(to: tempURL, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        return true
    }
}
```

**Verify:** `swift build` succeeds. Note that TOMLKit's exact API for in-place table mutation may vary by version — the `convert()` method serializes back to a TOML string. If your version uses a different method name, adapt.

---

## Phase 3 — Dual-strategy registrars (Claude Code, Codex)

These two clients ship a CLI. Each registrar declares both `registerViaCLI` and `registerViaConfigFile`. The protocol's default `register(...)` picks at runtime.

### Step 3.1 — `ClaudeCodeRegistrar`
**Do:** Create `Sources/localmem/Setup/Registrars/ClaudeCodeRegistrar.swift`:

```swift
import Foundation

struct ClaudeCodeRegistrar: ClientRegistrar {
    let displayName = "Claude Code"
    let cliCommand: String? = "claude"

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    func isInstalled() -> Bool {
        // Either the CLI is on PATH or the user has a Claude Code config dir.
        ShellHelper.commandExists("claude")
            || FileManager.default.fileExists(atPath: configURL.path)
            || FileManager.default.fileExists(atPath: FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".claude").path)
    }

    // MARK: - CLI path

    func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome {
        let list = try ShellHelper.run("claude", ["mcp", "list"])
        let registered = list.stdout.contains("localmem")
        let pointsAtUs = list.stdout.contains(binaryPath)

        if registered && pointsAtUs { return .alreadyRegistered(via: .cli) }
        if registered {
            _ = try? ShellHelper.run("claude", ["mcp", "remove", "localmem"])
            try ShellHelper.runOrThrow("claude", ["mcp", "add", "localmem", binaryPath, "--scope", "user"])
            return .updated(via: .cli)
        }
        try ShellHelper.runOrThrow("claude", ["mcp", "add", "localmem", binaryPath, "--scope", "user"])
        return .registered(via: .cli)
    }

    // MARK: - File path

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var previous: [String: Any]?
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            previous = servers["localmem"] as? [String: Any]
            servers["localmem"] = ["command": binaryPath]
            next["mcpServers"] = servers
            return next
        }
        if !changed { return .alreadyRegistered(via: .configFile) }
        return previous == nil ? .registered(via: .configFile) : .updated(via: .configFile)
    }
}
```

**Verify:** `swift build` succeeds.

### Step 3.2 — `CodexRegistrar`
**Do:** Create `Sources/localmem/Setup/Registrars/CodexRegistrar.swift`:

```swift
import Foundation
import TOMLKit

struct CodexRegistrar: ClientRegistrar {
    let displayName = "Codex"
    let cliCommand: String? = "codex"

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    private var codexDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    func isInstalled() -> Bool {
        // Either the CLI is on PATH or the desktop app left ~/.codex/ behind.
        ShellHelper.commandExists("codex")
            || FileManager.default.fileExists(atPath: codexDir.path)
    }

    // MARK: - CLI path

    func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome {
        // Codex's CLI doesn't easily distinguish "newly added" from "updated",
        // so we always report .registered. Remove-then-add is idempotent.
        _ = try? ShellHelper.run("codex", ["mcp", "remove", "localmem"])
        try ShellHelper.runOrThrow("codex", ["mcp", "add", "localmem", "--", binaryPath])
        return .registered(via: .cli)
    }

    // MARK: - File path

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var hadPrevious = false
        let changed = try TOMLConfig.update(at: configURL) { table in
            var mcpServers = (table["mcp_servers"] as? TOMLTable) ?? TOMLTable()
            hadPrevious = mcpServers["localmem"] != nil

            var entry = TOMLTable()
            entry["command"] = binaryPath
            mcpServers["localmem"] = entry
            table["mcp_servers"] = mcpServers
        }
        if !changed { return .alreadyRegistered(via: .configFile) }
        return hadPrevious ? .updated(via: .configFile) : .registered(via: .configFile)
    }
}
```

**Note:** TOMLKit's API for nested-table mutation has evolved; if the snippet above doesn't compile against your installed version, the **shape** stays the same — find the equivalent method names for "get a sub-table" and "assign a sub-table." Check TOMLKit's README.

**Verify:** `swift build` succeeds.

---

## Phase 4 — File-only registrars

These three clients have no CLI. They only need `registerViaConfigFile` — the default `register(...)` calls it directly because `cliCommand` is nil.

### Step 4.1 — `ClaudeDesktopRegistrar`
**Do:** Create `Sources/localmem/Setup/Registrars/ClaudeDesktopRegistrar.swift`:

```swift
import Foundation

struct ClaudeDesktopRegistrar: ClientRegistrar {
    let displayName = "Claude Desktop"

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    private var appDir: URL {
        URL(fileURLWithPath: "/Applications/Claude.app")
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: appDir.path)
            || FileManager.default.fileExists(atPath: configURL.path)
    }

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var previous: [String: Any]?
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            previous = servers["localmem"] as? [String: Any]
            servers["localmem"] = ["command": binaryPath]
            next["mcpServers"] = servers
            return next
        }
        if !changed { return .alreadyRegistered(via: .configFile) }
        return previous == nil ? .registered(via: .configFile) : .updated(via: .configFile)
    }
}
```

### Step 4.2 — `AntigravityRegistrar`
**Do:** Create `Sources/localmem/Setup/Registrars/AntigravityRegistrar.swift`:

```swift
import Foundation

struct AntigravityRegistrar: ClientRegistrar {
    let displayName = "Antigravity"

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/mcp_config.json")
    }

    private var geminiDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: geminiDir.path)
    }

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var previous: [String: Any]?
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            previous = servers["localmem"] as? [String: Any]
            servers["localmem"] = [
                "type": "stdio",
                "command": binaryPath,
                "args": []
            ] as [String: Any]
            next["mcpServers"] = servers
            return next
        }
        if !changed { return .alreadyRegistered(via: .configFile) }
        return previous == nil ? .registered(via: .configFile) : .updated(via: .configFile)
    }
}
```

**Note:** Antigravity's key name has been seen as both `mcpServers` and `mcp_servers` in tutorials. If your existing config uses snake_case, swap both reads/writes.

### Step 4.3 — `CursorRegistrar`
**Do:** Create `Sources/localmem/Setup/Registrars/CursorRegistrar.swift`:

```swift
import Foundation

struct CursorRegistrar: ClientRegistrar {
    let displayName = "Cursor"

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/mcp.json")
    }

    private var cursorDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor")
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: cursorDir.path)
    }

    func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
        var previous: [String: Any]?
        let changed = try JSONConfig.update(at: configURL) { current in
            var next = current
            var servers = (next["mcpServers"] as? [String: Any]) ?? [:]
            previous = servers["localmem"] as? [String: Any]
            servers["localmem"] = ["command": binaryPath]
            next["mcpServers"] = servers
            return next
        }
        if !changed { return .alreadyRegistered(via: .configFile) }
        return previous == nil ? .registered(via: .configFile) : .updated(via: .configFile)
    }
}
```

---

## Phase 5 — Wire it together

### Step 5.1 — `SetupReport`: pretty status output
**Do:** Create `Sources/localmem/Setup/SetupReport.swift`:

```swift
import Foundation

struct SetupReport {
    struct Row { let name: String; let outcome: Result<RegistrationOutcome, Error> }
    let rows: [Row]

    func render() -> String {
        var lines: [String] = []
        lines.append("LocalMem — installing MCP integration")
        lines.append(String(repeating: "=", count: 56))

        var registered = 0, skipped = 0, failed = 0

        for row in rows {
            let (symbol, detail): (String, String)
            switch row.outcome {
            case .success(let outcome):
                switch outcome {
                case .registered(let via):
                    symbol = "✓"; detail = "registered (via \(via.label))"
                case .alreadyRegistered(let via):
                    symbol = "↺"; detail = "already registered (via \(via.label))"
                case .updated(let via):
                    symbol = "✓"; detail = "updated (via \(via.label))"
                case .skipped(let why):
                    symbol = "–"; detail = "not installed — skipped (\(why))"
                }
            case .failure(let err):
                symbol = "✗"; detail = "FAILED — \(err)"
            }

            switch row.outcome {
            case .success(.registered), .success(.updated), .success(.alreadyRegistered):
                registered += 1
            case .success(.skipped): skipped += 1
            case .failure: failed += 1
            }

            let paddedName = row.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            lines.append("\(symbol)  \(paddedName) \(detail)")
        }

        lines.append(String(repeating: "-", count: 56))
        lines.append("\(registered) registered · \(skipped) skipped · \(failed) failed")
        lines.append("")
        lines.append("Restart any open Claude / Codex / Antigravity / Cursor")
        lines.append("sessions to pick up the new MCP server.")
        return lines.joined(separator: "\n")
    }
}

private extension RegistrationOutcome.Strategy {
    var label: String {
        switch self {
        case .cli: return "CLI"
        case .configFile: return "config file"
        }
    }
}
```

### Step 5.2 — `SetupCommand`: orchestrator
**Do:** Create `Sources/localmem/Commands/SetupCommand.swift`:

```swift
import ArgumentParser
import Foundation
import LocalMemCore

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Register localmem with every installed MCP client."
    )

    func run() throws {
        let binaryPath = try BinaryLocator.mcpServerPath()

        let registrars: [ClientRegistrar] = [
            ClaudeCodeRegistrar(),
            CodexRegistrar(),
            ClaudeDesktopRegistrar(),
            AntigravityRegistrar(),
            CursorRegistrar(),
        ]

        var rows: [SetupReport.Row] = []
        for registrar in registrars {
            guard registrar.isInstalled() else {
                rows.append(.init(
                    name: registrar.displayName,
                    outcome: .success(.skipped(reason: "client not detected"))
                ))
                continue
            }
            do {
                let outcome = try registrar.register(binaryPath: binaryPath)
                rows.append(.init(name: registrar.displayName, outcome: .success(outcome)))
            } catch {
                rows.append(.init(name: registrar.displayName, outcome: .failure(error)))
            }
        }

        print(SetupReport(rows: rows).render())
    }
}
```

### Step 5.3 — Register `SetupCommand` with the root CLI
**Do:** Edit `Sources/localmem/LocalMemCLI.swift`'s `subcommands` array to include `SetupCommand.self`:

```swift
subcommands: [
    ListCommand.self,
    SearchCommand.self,
    ShowCommand.self,
    AddCommand.self,
    SetupCommand.self,
    PathCommand.self,
],
```

### Step 5.4 — Build and test
**Do:**
```bash
swift build -c release
.build/release/localmem setup
```

**Verify:** You should see a table with five client rows. Output for your machine will look something like:

```
✓  Claude Code        already registered (via CLI)
✓  Codex              registered (via CLI)            ← if you installed codex CLI
                      registered (via config file)    ← if only the IDE
✓  Claude Desktop     registered (via config file)
✓  Antigravity        registered (via config file)
–  Cursor             not installed — skipped (client not detected)
```

Re-run immediately — every successful row should flip to `↺ already registered`. That's the idempotence check.

Inspect the written files to confirm no other servers got clobbered:

```bash
claude mcp list                                                                     # Claude Code
cat ~/.codex/config.toml                                                            # Codex
cat ~/Library/Application\ Support/Claude/claude_desktop_config.json 2>/dev/null    # Claude Desktop
cat ~/.gemini/config/mcp_config.json 2>/dev/null                                    # Antigravity
cat ~/.cursor/mcp.json 2>/dev/null                                                  # Cursor
```

---

## Phase 6 — `localmem status` (read-only health check)

A complementary command: report the current registration state without changing anything. Useful for "is localmem working?" troubleshooting.

### Step 6.1 — Extend `ClientRegistrar` with read methods
**Do:** Add two methods to the protocol (with default impls returning safe values):

```swift
protocol ClientRegistrar: Sendable {
    // ... existing requirements ...

    /// Returns true if our `localmem` entry is currently in the client's config.
    func isRegistered() -> Bool

    /// Returns the binary path currently registered, if any.
    func registeredBinaryPath() -> String?
}

extension ClientRegistrar {
    func isRegistered() -> Bool { false }
    func registeredBinaryPath() -> String? { nil }
}
```

Then implement `isRegistered()` and `registeredBinaryPath()` in each concrete registrar — for CLI-based clients, parse `<cli> mcp list` output; for file-based clients, parse the config file.

### Step 6.2 — `StatusCommand`
**Do:** Create `Sources/localmem/Commands/StatusCommand.swift`:

```swift
import ArgumentParser
import Foundation
import LocalMemCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report store stats and MCP client registration health."
    )

    func run() async throws {
        // Store stats
        let store = try MemoryStore()
        let dbPath = try Paths.databaseURL().path
        let recent = try await store.recent(limit: 1)
        let totalCount = try await store.recent(limit: 100000).count  // V1: full count
        let lastWrite = recent.first?.createdAt

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: dbPath)[.size] as? Int) ?? 0

        print("LocalMem Status")
        print(String(repeating: "=", count: 56))
        print("\nStore")
        print("  Database:    \(dbPath)")
        print("  Memories:    \(totalCount)")
        if let lastWrite = lastWrite {
            print("  Last write:  \(lastWrite)")
        }
        print("  Disk usage:  \(fileSize / 1024) KB")

        // Client connectivity
        let canonicalPath = (try? BinaryLocator.mcpServerPath()) ?? "<unresolved>"
        print("\nMCP clients")
        let registrars: [ClientRegistrar] = [
            ClaudeCodeRegistrar(),
            CodexRegistrar(),
            ClaudeDesktopRegistrar(),
            AntigravityRegistrar(),
            CursorRegistrar(),
        ]
        for registrar in registrars {
            let status: String
            if !registrar.isInstalled() {
                status = "– not installed"
            } else if !registrar.isRegistered() {
                status = "✗ installed but NOT registered — run `localmem setup`"
            } else if let path = registrar.registeredBinaryPath(), path != canonicalPath {
                status = "↺ registered · path STALE — run `localmem setup`"
            } else {
                status = "✓ registered · path OK"
            }
            let padded = registrar.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("  \(padded) \(status)")
        }
    }
}
```

Register `StatusCommand.self` in `LocalMemCLI`'s subcommands array.

### Step 6.3 — Update the V1 design doc
**Goal:** Capture the multi-client install story in [docs/LocalMem_V1_Build_Design.md](LocalMem_V1_Build_Design.md). Add a section noting that `localmem setup` and `localmem status` are part of V1's CLI surface, and that LocalMem registers with Claude Code, Codex, Claude Desktop, Antigravity, and Cursor.

---

## Final project layout

```
Sources/localmem/
├── LocalMemCLI.swift
├── OutputFormatter.swift
├── Commands/
│   ├── ListCommand.swift
│   ├── SearchCommand.swift
│   ├── ShowCommand.swift
│   ├── AddCommand.swift
│   ├── SetupCommand.swift              ← Phase 5
│   ├── StatusCommand.swift             ← Phase 6
│   └── PathCommand.swift
└── Setup/                              ← all new
    ├── BinaryLocator.swift             ← Phase 1
    ├── ClientRegistrar.swift           ← Phase 1
    ├── ShellHelper.swift               ← Phase 2
    ├── JSONConfig.swift                ← Phase 2
    ├── TOMLConfig.swift                ← Phase 2 (needs TOMLKit)
    ├── SetupReport.swift               ← Phase 5
    └── Registrars/
        ├── ClaudeCodeRegistrar.swift   ← Phase 3
        ├── CodexRegistrar.swift        ← Phase 3
        ├── ClaudeDesktopRegistrar.swift← Phase 4
        ├── AntigravityRegistrar.swift  ← Phase 4
        └── CursorRegistrar.swift       ← Phase 4
```

## Known limitations to address later

- **TOMLKit API drift** — TOMLKit's nested-table mutation API has evolved between versions; the snippets above show the shape but may need tweaks for the version that resolves.
- **Antigravity key name varies** (`mcpServers` vs `mcp_servers`). Future improvement: detect the form from the existing file, fall back to `mcpServers` for fresh installs.
- **No `localmem uninstall`** to reverse the registrations. Easy follow-up.
- **Detection by directory presence is fuzzy** — a leftover `~/.cursor/` from a previous install will look "installed" to us. Acceptable for V1; could harden later by checking for client binaries.
- **No tests yet.** JSONConfig and TOMLConfig in particular deserve unit tests — write a file, run the registrar, assert the result. Defer until shape is stable.
