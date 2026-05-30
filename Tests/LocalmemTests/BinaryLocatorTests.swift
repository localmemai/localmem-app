import Foundation
import Testing
@testable import localmem

@Suite("BinaryLocator")
struct BinaryLocatorTests {
    @Test("mcpServerPath throws because no localmem-mcp sits beside the test runner")
    func mcpServerPathThrowsInTestRunner() {
        // Bundle.main.executablePath under `swift test` points at the test
        // host binary, not the release dir, so there is never a sibling
        // localmem-mcp present. This is the natural failure path.
        #expect(throws: SetupError.self) {
            _ = try BinaryLocator.mcpServerPath()
        }
    }

    @Test("SetupError.cannotLocateBinary description carries the underlying reason")
    func cannotLocateBinaryDescriptionContainsReason() {
        let err = SetupError.cannotLocateBinary(reason: "no executable at /tmp/x")
        #expect(String(describing: err).contains("no executable at /tmp/x"))
    }

    @Test("SetupError.cliNotSupported description names the client")
    func cliNotSupportedDescriptionContainsClient() {
        let err = SetupError.cliNotSupported(client: "Claude Desktop")
        let s = String(describing: err)
        #expect(s.contains("Claude Desktop"))
        #expect(s.contains("CLI"))
    }
}
