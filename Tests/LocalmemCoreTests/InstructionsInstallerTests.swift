import Testing
import Foundation
@testable import LocalmemCore

@Suite("InstructionsInstaller")
struct InstructionsInstallerTests {

    // MARK: - Fixtures

    /// Stand up an isolated home dir + an installer pointed at it.
    /// Caller is responsible for cleanup via the returned tmp URL.
    func makeFixture(existingAgentDirs: [String] = []) throws -> (InstructionsInstaller, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        for dir in existingAgentDirs {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(dir, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // Use a small fixed content for tests — keeps assertions stable across
        // edits to the real bundled AGENTS.md.
        let installer = InstructionsInstaller(
            agentsContent: "# Test AGENTS.md\n\nFixture content.\n",
            homeDir: tmp
        )
        return (installer, tmp)
    }

    // MARK: - Bundled resource smoke test

    @Test("Bundled AGENTS.md is present and non-empty")
    func bundledResourceLoads() throws {
        let s = try AgentsResource.read()
        #expect(!s.isEmpty)
        #expect(s.contains("Localmem"), "AGENTS.md should mention the product name")
    }

    @Test("Bundled InstructionsInstaller convenience init uses the resource")
    func bundledInstallerInit() throws {
        let i = try InstructionsInstaller()
        #expect(!i.agentsContent.isEmpty)
    }

    // MARK: - Canonical file (§6.2, §7 managed-file contract)

    @Test("Canonical file is created under ~/.localmem/ on first install")
    func canonicalFileCreated() throws {
        let (installer, tmp) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try installer.installCanonicalFile()

        let url = tmp.appendingPathComponent(".localmem/AGENTS.md")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == installer.agentsContent)
    }

    @Test("Canonical file is unconditionally overwritten on re-run (§7)")
    func canonicalFileOverwrittenOnRerun() throws {
        let (installer, tmp) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try installer.installCanonicalFile()
        let url = installer.canonicalURL

        try "USER EDIT".write(to: url, atomically: true, encoding: .utf8)

        try installer.installCanonicalFile()
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == installer.agentsContent)
        #expect(!after.contains("USER EDIT"))
    }

    // MARK: - Fresh install (§6.2)

    @Test("Fresh install: target file does not exist → created with only the import line")
    func freshInstallCreatesFile() throws {
        let (installer, tmp) = try makeFixture(existingAgentDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let target = AgentInstructionTarget(displayName: "Claude Code", relativePath: ".claude/CLAUDE.md")
        let outcome = try installer.injectImportLine(into: target)

        if case .created = outcome {} else { Issue.record("expected .created, got \(outcome)") }
        let content = try String(contentsOf: tmp.appendingPathComponent(target.relativePath), encoding: .utf8)
        #expect(content.contains("<!-- localmem -->"))
        #expect(content.contains(".localmem/AGENTS.md"))
    }

    // MARK: - Idempotency (§6.2)

    @Test("Re-run on a file that already has the import line is a no-op")
    func idempotentReinjection() throws {
        let (installer, tmp) = try makeFixture(existingAgentDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let target = AgentInstructionTarget(displayName: "Claude Code", relativePath: ".claude/CLAUDE.md")
        _ = try installer.injectImportLine(into: target)
        let firstWrite = try String(contentsOf: tmp.appendingPathComponent(target.relativePath), encoding: .utf8)

        let secondOutcome = try installer.injectImportLine(into: target)
        if case .alreadyImported = secondOutcome {} else { Issue.record("expected .alreadyImported, got \(secondOutcome)") }
        let secondWrite = try String(contentsOf: tmp.appendingPathComponent(target.relativePath), encoding: .utf8)
        #expect(firstWrite == secondWrite, "second run must not modify the file")
    }

    // MARK: - Existing-file preservation (§6.2, §8 success criterion)

    @Test("Existing file: import line appended; original content preserved byte-for-byte")
    func existingFilePreservedByteForByte() throws {
        let (installer, tmp) = try makeFixture(existingAgentDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let target = AgentInstructionTarget(displayName: "Claude Code", relativePath: ".claude/CLAUDE.md")
        let userContent = "# My existing instructions\n\nAlways use snake_case.\nPrefer Tailwind.\n"
        try userContent.write(to: tmp.appendingPathComponent(target.relativePath), atomically: true, encoding: .utf8)

        let outcome = try installer.injectImportLine(into: target)
        if case .imported = outcome {} else { Issue.record("expected .imported, got \(outcome)") }

        let after = try String(contentsOf: tmp.appendingPathComponent(target.relativePath), encoding: .utf8)
        #expect(after.hasPrefix(userContent), "original content must remain at the start of the file, unchanged")
        #expect(after.contains("<!-- localmem -->"))
    }

    @Test("Remove import line preserves surrounding user instructions")
    func removeImportLinePreservesUserContent() throws {
        let (installer, tmp) = try makeFixture(existingAgentDirs: [".claude"])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let target = AgentInstructionTarget(displayName: "Claude Code", relativePath: ".claude/CLAUDE.md")
        let before = """
        # My existing instructions

        \(installer.importLine)
        Prefer Tailwind.

        """
        try before.write(to: tmp.appendingPathComponent(target.relativePath), atomically: true, encoding: .utf8)

        let outcome = try installer.removeImportLine(from: target)
        if case .removed = outcome {} else { Issue.record("expected .removed, got \(outcome)") }

        let after = try String(contentsOf: tmp.appendingPathComponent(target.relativePath), encoding: .utf8)
        #expect(!after.contains("<!-- localmem -->"))
        #expect(after.contains("# My existing instructions"))
        #expect(after.contains("Prefer Tailwind."))
    }

    // MARK: - Skip when agent not installed (§6.2)

    @Test("Skips target when the agent's directory does not exist")
    func skipsWhenAgentMissing() throws {
        let (installer, tmp) = try makeFixture(existingAgentDirs: [])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let target = AgentInstructionTarget(displayName: "Cursor", relativePath: ".cursor/AGENTS.md")
        let outcome = try installer.injectImportLine(into: target)
        if case .skipped(let reason) = outcome {
            #expect(reason.contains("not installed"))
        } else {
            Issue.record("expected .skipped, got \(outcome)")
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent(".cursor").path))
    }

    // MARK: - Per-agent matrix (§6.2)

    @Test("Per-agent matrix: each agent gets the right path with the right import")
    func perAgentMatrix() throws {
        for target in InstructionsInstaller.defaultTargets {
            let parentDir = (target.relativePath as NSString).deletingLastPathComponent
            let (installer, tmp) = try makeFixture(existingAgentDirs: [parentDir])
            defer { try? FileManager.default.removeItem(at: tmp) }

            let outcome = try installer.injectImportLine(into: target)
            if case .skipped = outcome {
                Issue.record("did not expect skip for \(target.displayName)")
            }

            let written = try String(contentsOf: tmp.appendingPathComponent(target.relativePath), encoding: .utf8)
            #expect(written.contains("<!-- localmem -->"), "missing tag for \(target.displayName)")
            #expect(written.contains(installer.canonicalURL.path), "missing canonical path for \(target.displayName)")
        }
    }

    // MARK: - installAll integration (§6.2)

    @Test("installAll succeeds when no agents are installed: every target skipped, canonical written")
    func installAllNoAgents() throws {
        let (installer, tmp) = try makeFixture(existingAgentDirs: [])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let results = try installer.installAll()
        #expect(results.count == InstructionsInstaller.defaultTargets.count)
        for r in results {
            switch r.outcome {
            case .success(.skipped): break
            default: Issue.record("expected .skipped for \(r.name), got \(r.outcome)")
            }
        }
        #expect(FileManager.default.fileExists(atPath: installer.canonicalURL.path))
    }
}
