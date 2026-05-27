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

    func isRegistered() -> Bool { false }
    func registeredBinaryPath() -> String? { nil }

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
