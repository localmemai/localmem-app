import ArgumentParser
import Foundation
import LocalmemCore

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Register localmem with every installed MCP client."
    )

    @Flag(name: .long, inversion: .prefixedNo, help: "Install agent instruction files (~/.localmem/AGENTS.md and per-agent imports).")
    var instructions: Bool = true

    func run() async throws {
        let binaryPath = try BinaryLocator.mcpServerPath()

        // Fast file-based clients first, slow CLI-based ones last — see
        // the rationale in the earlier reorder commit.
        let registrars: [ClientRegistrar] = [
            ClaudeDesktopRegistrar(),
            AntigravityRegistrar(),
            CursorRegistrar(),
            CodexRegistrar(),
            ClaudeCodeRegistrar(),
        ]

        if ProgressBar.isTerminal {
            try await runStreaming(registrars: registrars, binaryPath: binaryPath)
        } else {
            try await runBatch(registrars: registrars, binaryPath: binaryPath)
        }
    }

    /// Run the instructions installer and return per-target rows.
    /// Caller decides how to render — streaming or batch.
    private func runInstructionsInstall() throws -> [SetupReport.InstructionRow] {
        let installer = try InstructionsInstaller()
        let results = try installer.installAll()
        return results.map { .init(name: $0.name, outcome: $0.outcome) }
    }

    // MARK: - Streaming (interactive terminal)

    /// Prints a permanent line per client as work completes, with a live spinner
    /// on the in-progress line. Past lines stay on screen so the user can see
    /// the full history at any moment.
    private func runStreaming(
        registrars: [ClientRegistrar],
        binaryPath: String
    ) async throws {
        for line in SetupReport.headerLines { print(line) }

        var rows: [SetupReport.Row] = []
        for registrar in registrars {
            let name = registrar.displayName

            // Show one frame synchronously so the spinner line is visible even
            // if the registrar finishes before the first sleep returns.
            writeSpinner(frame: 0, name: name)

            let spinTask = Task {
                var frame = 1
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { break }
                    if Task.isCancelled { break }
                    writeSpinner(frame: frame, name: name)
                    frame += 1
                }
            }

            // Do the registration off the main task so the spinner can animate.
            let r = registrar
            let outcome: Result<RegistrationOutcome, Error>
            do {
                let value = try await Task.detached {
                    guard r.isInstalled() else {
                        return RegistrationOutcome.skipped(reason: "client not detected")
                    }
                    return try r.register(binaryPath: binaryPath)
                }.value
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }

            spinTask.cancel()

            // Overwrite the spinner line with the completion line + newline.
            // After this, the cursor is on a fresh empty line ready for the
            // next spinner.
            let row = SetupReport.Row(name: name, outcome: outcome)
            let completion = SetupReport.formatRow(row)
            FileHandle.standardOutput.write(Data("\r\(completion)\u{001B}[K\n".utf8))
            rows.append(row)
        }

        if instructions {
            for line in SetupReport.instructionsHeaderLines { print(line) }
            for row in try runInstructionsInstall() {
                print(SetupReport.formatInstructionRow(row))
            }
        }

        print(SetupReport.renderSummary(rows))
    }

    /// Overwrites the current line with a spinner frame + label.
    private func writeSpinner(frame: Int, name: String) {
        let char = ProgressBar.spinnerFrames[frame % ProgressBar.spinnerFrames.count]
        let line = "[\(char)] Registering \(name)..."
        FileHandle.standardOutput.write(Data("\r\(line)\u{001B}[K".utf8))
    }

    // MARK: - Batch (non-TTY: piped, CI, redirected)

    private func runBatch(
        registrars: [ClientRegistrar],
        binaryPath: String
    ) async throws {
        var rows: [SetupReport.Row] = []
        for registrar in registrars {
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
        var report = SetupReport(rows: rows)
        if instructions {
            report.instructionRows = try runInstructionsInstall()
        }
        print(report.render())
    }
}
