import Foundation
import Testing
@testable import localmem

/// Exercises `SetupCommand.processClient` — the single orchestration point
/// that decides whether a client gets registered, pre-authorized, both, or
/// neither. The branches we care about are:
///
/// * client not installed → skipped, no pre-auth
/// * registration throws → failure surfaces, pre-auth not attempted
/// * registration returns .skipped → no pre-auth
/// * `preauthorize: false` → pre-auth not attempted even on success
/// * happy path → registration and pre-auth both succeed
/// * pre-auth throws → registration succeeds, pre-auth failure preserved
@Suite("SetupCommand.processClient")
struct SetupCommandTests {

    /// Fully configurable fake. Defaults to a sensible "installed, registers
    /// fine, pre-auth fine" baseline so each test only overrides what it needs.
    struct FakeRegistrar: ClientRegistrar {
        let displayName = "Fake"
        var installed: Bool = true
        var registerResult: Result<RegistrationOutcome, Error> = .success(.registered(via: .configFile))
        var preauthResult: Result<PreauthorizationOutcome, Error> = .success(.authorized(scope: .tools(count: 3)))

        func isInstalled() -> Bool { installed }

        func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
            try registerResult.get()
        }

        func preauthorize(tools: [String]) throws -> PreauthorizationOutcome {
            try preauthResult.get()
        }
    }

    struct Boom: Error, CustomStringConvertible {
        let description: String
    }

    @Test("client not installed → registration is .skipped, pre-auth is nil")
    func notInstalled() {
        var r = FakeRegistrar()
        r.installed = false
        let (reg, pre) = SetupCommand.processClient(r, binaryPath: "/tmp/x", preauthorize: true)
        guard case .success(.skipped) = reg else {
            Issue.record("expected .skipped, got \(reg)")
            return
        }
        #expect(pre == nil)
    }

    @Test("registration throws → failure surfaces, pre-auth not attempted")
    func registrationFails() {
        var r = FakeRegistrar()
        r.registerResult = .failure(Boom(description: "register kaboom"))
        let (reg, pre) = SetupCommand.processClient(r, binaryPath: "/tmp/x", preauthorize: true)
        guard case .failure(let err) = reg else {
            Issue.record("expected .failure, got \(reg)")
            return
        }
        #expect("\(err)".contains("register kaboom"))
        #expect(pre == nil)
    }

    @Test("registration returns .skipped → pre-auth is nil even with --preauthorize on")
    func registrationSkippedSuppressesPreauth() {
        var r = FakeRegistrar()
        r.registerResult = .success(.skipped(reason: "config locked"))
        let (reg, pre) = SetupCommand.processClient(r, binaryPath: "/tmp/x", preauthorize: true)
        guard case .success(.skipped) = reg else {
            Issue.record("expected .skipped, got \(reg)")
            return
        }
        #expect(pre == nil)
    }

    @Test("preauthorize: false → pre-auth is nil even on a clean registration")
    func optOutSuppressesPreauth() {
        let r = FakeRegistrar()
        let (reg, pre) = SetupCommand.processClient(r, binaryPath: "/tmp/x", preauthorize: false)
        guard case .success(.registered) = reg else {
            Issue.record("expected .registered, got \(reg)")
            return
        }
        #expect(pre == nil)
    }

    @Test("happy path → registration and pre-auth both succeed")
    func happyPath() {
        let r = FakeRegistrar()
        let (reg, pre) = SetupCommand.processClient(r, binaryPath: "/tmp/x", preauthorize: true)
        guard case .success(.registered) = reg else {
            Issue.record("expected .registered, got \(reg)")
            return
        }
        guard case .success(.authorized(.tools(let count))) = pre else {
            Issue.record("expected .authorized(.tools), got \(String(describing: pre))")
            return
        }
        #expect(count == 3)
    }

    @Test("pre-auth throws → registration result preserved, pre-auth surfaces the error")
    func preauthFailsAfterSuccessfulRegistration() {
        var r = FakeRegistrar()
        r.preauthResult = .failure(Boom(description: "preauth kaboom"))
        let (reg, pre) = SetupCommand.processClient(r, binaryPath: "/tmp/x", preauthorize: true)
        guard case .success(.registered) = reg else {
            Issue.record("expected .registered, got \(reg)")
            return
        }
        guard case .failure(let err) = pre else {
            Issue.record("expected pre-auth .failure, got \(String(describing: pre))")
            return
        }
        #expect("\(err)".contains("preauth kaboom"))
    }
}
