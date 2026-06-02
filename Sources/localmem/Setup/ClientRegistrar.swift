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

    /// Returns true if our `localmem` entry is currently present in the client's config.
    func isRegistered() -> Bool

    /// Returns the binary path currently registered, if any. nil = not registered or unknown.
    func registeredBinaryPath() -> String?

    /// Pre-authorize Localmem's tools so the client doesn't prompt on every
    /// session. Returns `.unsupported` if the client has no pre-auth mechanism.
    /// Default implementation in the protocol extension returns `.unsupported`.
    func preauthorize(tools: [String]) throws -> PreauthorizationOutcome

    /// Reports the current pre-auth state for `status`, without writing.
    /// Default implementation returns `.unsupported`.
    func preauthorizationState(tools: [String]) -> PreauthorizationState
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

/// Result of a single `preauthorize` call. Mirrors `RegistrationOutcome` so the
/// SetupReport can render it next to the registration result.
enum PreauthorizationOutcome: Sendable {
    /// We wrote new pre-auth entries for at least one tool.
    case authorized(scope: Scope)
    /// All requested tools were already authorized; we wrote nothing.
    case alreadyAuthorized(scope: Scope)
    /// Some tools were already authorized; we added the rest.
    case updated(scope: Scope)
    /// The client has no pre-auth mechanism we can drive.
    case unsupported
    /// Non-fatal failure (file locked, parse error, etc). Caller continues.
    case skipped(reason: String)

    /// Describes *what* got authorized — per-tool list or server-wide trust.
    /// Antigravity is the only client that forces `.server`; everyone else
    /// gets `.tools(count:)` so the report can show "3 tools".
    enum Scope: Sendable, Equatable {
        case tools(count: Int)
        case server
    }
}

/// Snapshot for `localmem status`. Read-only; never writes.
enum PreauthorizationState: Sendable {
    case authorized        // every requested tool / server-wide trust is set
    case partial(missing: Int)
    case notAuthorized
    case unsupported       // client has no mechanism (default)
}

extension ClientRegistrar {
    var cliCommand: String? { nil }

    func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome {
        throw SetupError.cliNotSupported(client: displayName)
    }

    func isRegistered() -> Bool { false }
    func registeredBinaryPath() -> String? { nil }

    func preauthorize(tools: [String]) throws -> PreauthorizationOutcome { .unsupported }
    func preauthorizationState(tools: [String]) -> PreauthorizationState { .unsupported }

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
