import Foundation
import Testing
import LocalmemCore
@testable import localmem

@Suite("ClientRegistrar.register routing")
struct ClientRegistrarTests {
    /// Mutable counter shared between the test and its fake registrars.
    final class Spy: @unchecked Sendable {
        var cliCalls = 0
        var fileCalls = 0
        var cliThrows = false
    }

    /// Declares a `cliCommand` known to be on PATH so the default
    /// `register()` extension goes through its CLI branch.
    struct CLIRegistrar: ClientRegistrar {
        let displayName = "CLI Spy"
        let cliCommand: String? = "sh"
        let spy: Spy

        func isInstalled() -> Bool { true }

        func registerViaCLI(binaryPath: String) throws -> RegistrationOutcome {
            spy.cliCalls += 1
            if spy.cliThrows {
                throw SetupError.cliNotSupported(client: displayName)
            }
            return .registered(via: .cli)
        }

        func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
            spy.fileCalls += 1
            return .registered(via: .configFile)
        }
    }

    /// Omits `cliCommand`, picking up the protocol-extension default of nil.
    /// The default `register()` must skip the CLI branch entirely.
    struct FileOnlyRegistrar: ClientRegistrar {
        let displayName = "File Only"
        let spy: Spy

        func isInstalled() -> Bool { true }

        func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
            spy.fileCalls += 1
            return .registered(via: .configFile)
        }
    }

    @Test("default register prefers the CLI path when the command is on PATH")
    func prefersCLIWhenAvailable() throws {
        let spy = Spy()
        let r = CLIRegistrar(spy: spy)
        let outcome = try r.register(binaryPath: "/tmp/x")
        if case .registered(.cli) = outcome {} else {
            Issue.record("expected .registered(.cli), got \(outcome)")
        }
        #expect(spy.cliCalls == 1)
        #expect(spy.fileCalls == 0)
    }

    @Test("default register falls back to the config file when the CLI throws")
    func fallsBackOnCLIThrow() throws {
        let spy = Spy()
        spy.cliThrows = true
        let r = CLIRegistrar(spy: spy)
        let outcome = try r.register(binaryPath: "/tmp/x")
        if case .registered(.configFile) = outcome {} else {
            Issue.record("expected .registered(.configFile), got \(outcome)")
        }
        #expect(spy.cliCalls == 1)
        #expect(spy.fileCalls == 1)
    }

    @Test("default register goes straight to the config file when no CLI command is declared")
    func usesFileWhenCLINotDeclared() throws {
        let spy = Spy()
        let r = FileOnlyRegistrar(spy: spy)
        _ = try r.register(binaryPath: "/tmp/x")
        #expect(spy.fileCalls == 1)
    }

    /// The protocol-extension defaults a minimal registrar inherits. These are
    /// what a newly added client gets for free, so they have to be the
    /// conservative answers: claim nothing, support nothing, never report a
    /// registration or pre-authorization that isn't there.
    @Test("a registrar declaring only the required members inherits safe defaults")
    func protocolDefaultsAreConservative() {
        let r = FileOnlyRegistrar(spy: Spy())

        #expect(r.cliCommand == nil)
        #expect(!r.isRegistered())
        #expect(r.registeredBinaryPath() == nil)

        if case .unsupported = try? r.preauthorize(tools: Localmem.preauthorizedToolNames) {} else {
            Issue.record("expected .unsupported from the default preauthorize")
        }
        if case .unsupported = r.preauthorizationState(tools: Localmem.preauthorizedToolNames) {} else {
            Issue.record("expected .unsupported from the default preauthorizationState")
        }
    }

    @Test("the default registerViaCLI refuses rather than silently doing nothing")
    func defaultCLIRegistrationThrows() {
        let r = FileOnlyRegistrar(spy: Spy())
        #expect(throws: SetupError.self) {
            _ = try r.registerViaCLI(binaryPath: "/tmp/x")
        }
    }
}
