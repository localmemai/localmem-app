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

    @Test("resolveMCPPath finds localmem-mcp sitting beside the executable")
    func resolvesSiblingWithoutFollowingSymlinks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("localmem")
        let mcp = dir.appendingPathComponent("localmem-mcp")
        try makeExecutable(at: exe)
        try makeExecutable(at: mcp)

        let resolved = try BinaryLocator.resolveMCPPath(fromExecutable: exe.path)
        #expect(resolved == mcp.path)
    }

    @Test("resolveMCPPath keeps the stable symlink dir when both binaries are linked (Homebrew shape)")
    func prefersUnresolvedSiblingOverSymlinkTarget() throws {
        let real = try makeTempDir()
        let link = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: real); try? FileManager.default.removeItem(at: link) }
        try makeExecutable(at: real.appendingPathComponent("localmem"))
        try makeExecutable(at: real.appendingPathComponent("localmem-mcp"))
        // Both binaries symlinked into the stable prefix dir, like `brew` does.
        let linkedExe = link.appendingPathComponent("localmem")
        try FileManager.default.createSymbolicLink(at: linkedExe, withDestinationURL: real.appendingPathComponent("localmem"))
        try FileManager.default.createSymbolicLink(
            at: link.appendingPathComponent("localmem-mcp"),
            withDestinationURL: real.appendingPathComponent("localmem-mcp"))

        let resolved = try BinaryLocator.resolveMCPPath(fromExecutable: linkedExe.path)
        // Must NOT resolve into the (versioned) real dir — the symlink dir is stable.
        #expect(resolved == link.appendingPathComponent("localmem-mcp").path)
    }

    @Test("resolveMCPPath follows the symlink when only localmem is linked (app-bundle shape)")
    func followsSymlinkWhenSiblingMissing() throws {
        let bundle = try makeTempDir()
        let binDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: bundle); try? FileManager.default.removeItem(at: binDir) }
        try makeExecutable(at: bundle.appendingPathComponent("localmem"))
        try makeExecutable(at: bundle.appendingPathComponent("localmem-mcp"))
        // Only the CLI is symlinked onto PATH; mcp lives only inside the bundle.
        let linkedExe = binDir.appendingPathComponent("localmem")
        try FileManager.default.createSymbolicLink(at: linkedExe, withDestinationURL: bundle.appendingPathComponent("localmem"))

        let resolved = try BinaryLocator.resolveMCPPath(fromExecutable: linkedExe.path)
        #expect(resolved == bundle.appendingPathComponent("localmem-mcp").path)
    }

    @Test("resolveMCPPath throws when no localmem-mcp exists in either location")
    func throwsWhenNoSibling() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(at: dir.appendingPathComponent("localmem"))
        #expect(throws: SetupError.self) {
            _ = try BinaryLocator.resolveMCPPath(fromExecutable: dir.appendingPathComponent("localmem").path)
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("binlocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so path comparisons are stable on macOS.
        return dir.resolvingSymlinksInPath()
    }

    private func makeExecutable(at url: URL) throws {
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
