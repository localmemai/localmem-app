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
        let total = registrars.count
        var rows: [SetupReport.Row] = []

        for (index, registrar) in registrars.enumerated() {
            ProgressBar.draw(
                current: index,
                total: total,
                label: "Registering \(registrar.displayName)..."
            )

            let outcome: Result<RegistrationOutcome, Error>
            if !registrar.isInstalled() {
                outcome = .success(.skipped(reason: "client not detected"))
            } else {
                do {
                    outcome = .success(try registrar.register(binaryPath: binaryPath))
                } catch {
                    outcome = .failure(error)
                }
            }
            rows.append(.init(name: registrar.displayName, outcome: outcome))
        }

        // Briefly show 100% so completion is visible, then erase the bar
        // before printing the final report.
        ProgressBar.draw(current: total, total: total, label: "Done")
        ProgressBar.clear()

        print(SetupReport(rows: rows).render())
    }
}
