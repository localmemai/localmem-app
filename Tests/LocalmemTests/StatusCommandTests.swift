import Foundation
import Testing
@testable import localmem

/// Exercises `StatusCommand.statusLine` / `preauthLabel` — the per-client
/// health rendering for `localmem status`. The branches:
///
/// * not installed → dash line
/// * installed but not registered → ✗ + setup hint
/// * registered, path matches canonical → path OK
/// * registered, path differs → path STALE + setup hint
/// * registered, path unknown → ✓ without path claim
/// * each pre-auth state maps to its label
@Suite("StatusCommand status line")
struct StatusCommandTests {

    /// Configurable fake, defaulting to "installed, registered at the canonical
    /// path, fully pre-authorized" so each test overrides only what it needs.
    struct FakeRegistrar: ClientRegistrar {
        let displayName = "Fake"
        var installed: Bool = true
        var registered: Bool = true
        var binaryPath: String? = "/opt/localmem-mcp"
        var preauthState: PreauthorizationState = .authorized

        func isInstalled() -> Bool { installed }
        func isRegistered() -> Bool { registered }
        func registeredBinaryPath() -> String? { binaryPath }

        func registerViaConfigFile(binaryPath: String) throws -> RegistrationOutcome {
            .skipped(reason: "not exercised by status tests")
        }

        func preauthorizationState(tools: [String]) -> PreauthorizationState {
            preauthState
        }
    }

    private let canonical = "/opt/localmem-mcp"

    @Test("not installed → dash line, no setup hint")
    func notInstalled() {
        var r = FakeRegistrar()
        r.installed = false
        #expect(StatusCommand.statusLine(for: r, canonical: canonical) == "– not installed")
    }

    @Test("installed but not registered → ✗ with setup hint")
    func notRegistered() {
        var r = FakeRegistrar()
        r.registered = false
        #expect(StatusCommand.statusLine(for: r, canonical: canonical)
            == "✗ installed but NOT registered — run `localmem setup`")
    }

    @Test("registered at the canonical path → path OK plus pre-auth label")
    func registeredPathOK() {
        let r = FakeRegistrar()
        #expect(StatusCommand.statusLine(for: r, canonical: canonical)
            == "✓ registered · path OK · auto-approved")
    }

    @Test("registered at a different path → STALE with setup hint")
    func registeredPathStale() {
        var r = FakeRegistrar()
        r.binaryPath = "/old/build/localmem-mcp"
        #expect(StatusCommand.statusLine(for: r, canonical: canonical)
            == "↺ registered · path STALE — run `localmem setup` · auto-approved")
    }

    @Test("registered but the config exposes no path → path unknown")
    func registeredPathUnknown() {
        var r = FakeRegistrar()
        r.binaryPath = nil
        #expect(StatusCommand.statusLine(for: r, canonical: canonical)
            == "✓ registered · path unknown · auto-approved")
    }

    @Test("pre-auth states map to their labels")
    func preauthLabels() {
        var r = FakeRegistrar()

        r.preauthState = .authorized
        #expect(StatusCommand.preauthLabel(for: r) == "auto-approved")

        r.preauthState = .partial(missing: 2)
        #expect(StatusCommand.preauthLabel(for: r)
            == "auto-approved (partial, 2 missing — re-run setup)")

        r.preauthState = .notAuthorized
        #expect(StatusCommand.preauthLabel(for: r) == "prompts each call — re-run setup")

        r.preauthState = .unsupported
        #expect(StatusCommand.preauthLabel(for: r) == "no pre-auth mechanism")
    }
}
