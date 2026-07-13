import Testing
import Foundation
import LocalmemCore
@testable import localmem

@Suite("SetupReport")
struct SetupReportTests {

    // A stable error for testing the FAILED line — `\(err)` interpolates this.
    struct FakeError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - formatRow (registrar pass)

    @Test("formatRow renders the registered/CLI outcome with ✓")
    func formatRegisteredCLI() {
        let row = SetupReport.Row(
            name: "Claude Code",
            outcome: .success(.registered(via: .cli))
        )
        let line = SetupReport.formatRow(row)
        #expect(line.contains("✓"))
        #expect(line.contains("Claude Code"))
        #expect(line.contains("registered (via CLI)"))
    }

    @Test("formatRow renders alreadyRegistered with ↺ and via label")
    func formatAlreadyRegistered() {
        let row = SetupReport.Row(
            name: "Codex",
            outcome: .success(.alreadyRegistered(via: .configFile))
        )
        let line = SetupReport.formatRow(row)
        #expect(line.contains("↺"))
        #expect(line.contains("already registered (via config file)"))
    }

    @Test("formatRow renders updated outcome with ✓ and via label")
    func formatUpdated() {
        let row = SetupReport.Row(
            name: "Cursor",
            outcome: .success(.updated(via: .configFile))
        )
        let line = SetupReport.formatRow(row)
        #expect(line.contains("✓"))
        #expect(line.contains("updated (via config file)"))
    }

    @Test("formatRow renders skipped with the reason inline")
    func formatSkipped() {
        let row = SetupReport.Row(
            name: "Antigravity",
            outcome: .success(.skipped(reason: "not installed"))
        )
        let line = SetupReport.formatRow(row)
        #expect(line.contains("–"))
        #expect(line.contains("not installed — skipped (not installed)"))
    }

    @Test("formatRow renders a failure with ✗ and the underlying error string")
    func formatFailure() {
        let row = SetupReport.Row(
            name: "Cursor",
            outcome: .failure(FakeError(description: "boom"))
        )
        let line = SetupReport.formatRow(row)
        #expect(line.contains("✗"))
        #expect(line.contains("FAILED — boom"))
    }

    // MARK: - formatInstructionRow (instructions pass)

    @Test("formatInstructionRow renders created/imported/alreadyImported with the right symbols")
    func formatInstructionOutcomes() {
        let created = SetupReport.InstructionRow(name: "Claude Code", outcome: .success(.created))
        #expect(SetupReport.formatInstructionRow(created).contains("✓"))
        #expect(SetupReport.formatInstructionRow(created).contains("instructions file created"))

        let imported = SetupReport.InstructionRow(name: "Cursor", outcome: .success(.imported))
        #expect(SetupReport.formatInstructionRow(imported).contains("✓"))
        #expect(SetupReport.formatInstructionRow(imported).contains("import line added"))

        let already = SetupReport.InstructionRow(name: "Codex", outcome: .success(.alreadyImported))
        #expect(SetupReport.formatInstructionRow(already).contains("↺"))
        #expect(SetupReport.formatInstructionRow(already).contains("import line already present"))
    }

    @Test("formatInstructionRow renders a skipped reason")
    func formatInstructionSkipped() {
        let row = SetupReport.InstructionRow(
            name: "Antigravity",
            outcome: .success(.skipped(reason: "Antigravity not installed"))
        )
        let line = SetupReport.formatInstructionRow(row)
        #expect(line.contains("–"))
        #expect(line.contains("skipped (Antigravity not installed)"))
    }

    @Test("formatInstructionRow renders a failure with the error string")
    func formatInstructionFailure() {
        let row = SetupReport.InstructionRow(
            name: "Claude Code",
            outcome: .failure(FakeError(description: "perm denied"))
        )
        let line = SetupReport.formatInstructionRow(row)
        #expect(line.contains("✗"))
        #expect(line.contains("FAILED — perm denied"))
    }

    // MARK: - renderSummary

    @Test("renderSummary counts registered/alreadyRegistered/updated as registered")
    func summaryCountsRegisteredVariants() {
        let rows: [SetupReport.Row] = [
            .init(name: "A", outcome: .success(.registered(via: .cli))),
            .init(name: "B", outcome: .success(.alreadyRegistered(via: .configFile))),
            .init(name: "C", outcome: .success(.updated(via: .cli))),
            .init(name: "D", outcome: .success(.skipped(reason: "x"))),
            .init(name: "E", outcome: .failure(FakeError(description: "x"))),
        ]
        let summary = SetupReport.renderSummary(rows)
        #expect(summary.contains("3 registered · 1 skipped · 1 failed"))
        #expect(summary.contains("Restart any open"))
    }

    @Test("renderSummary handles an empty row set gracefully")
    func summaryHandlesEmpty() {
        let summary = SetupReport.renderSummary([])
        #expect(summary.contains("0 registered · 0 skipped · 0 failed"))
    }

    // MARK: - render

    @Test("render emits header, every row, and the summary in order")
    func renderFullReport() {
        let report = SetupReport(rows: [
            .init(name: "Claude Code", outcome: .success(.registered(via: .cli))),
            .init(name: "Cursor",      outcome: .success(.skipped(reason: "not installed"))),
        ])
        let out = report.render()
        // Header is present.
        #expect(out.contains("Localmem — installing MCP integration"))
        // Both rows present.
        #expect(out.contains("Claude Code"))
        #expect(out.contains("Cursor"))
        // Summary is present.
        #expect(out.contains("1 registered · 1 skipped · 0 failed"))
        // No instructions section unless instructionRows is set.
        #expect(!out.contains("Installing agent instructions"))
    }

    @Test("render emits the instructions section when instructionRows is non-empty")
    func renderIncludesInstructionsSection() {
        var report = SetupReport(rows: [
            .init(name: "Claude Code", outcome: .success(.registered(via: .cli))),
        ])
        report.instructionRows = [
            .init(name: "Claude Code", outcome: .success(.created)),
            .init(name: "Cursor",      outcome: .success(.alreadyImported)),
        ]
        let out = report.render()
        #expect(out.contains("Installing agent instructions"))
        #expect(out.contains("instructions file created"))
        #expect(out.contains("import line already present"))
    }
}
