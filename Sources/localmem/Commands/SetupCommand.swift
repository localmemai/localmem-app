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

    @Flag(name: .long, inversion: .prefixedNo, help: "Pre-approve Localmem's tools so clients don't prompt on every call.")
    var preauthorize: Bool = true

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

    /// One client's full setup pass: install check, register, then pre-authorize
    /// if registration landed and the caller didn't opt out. Returns the data
    /// the report renders — never throws.
    static func processClient(
        _ registrar: ClientRegistrar,
        binaryPath: String,
        preauthorize: Bool
    ) -> (Result<RegistrationOutcome, Error>, Result<PreauthorizationOutcome, Error>?) {
        guard registrar.isInstalled() else {
            return (.success(.skipped(reason: "client not detected")), nil)
        }

        let registration: Result<RegistrationOutcome, Error>
        do {
            registration = .success(try registrar.register(binaryPath: binaryPath))
        } catch {
            registration = .failure(error)
        }

        // Skip pre-auth when the user opted out, when registration failed, or
        // when registration was a no-op (.skipped) — writing auto-approve into
        // a file the client won't load just adds noise.
        guard preauthorize, case .success(let outcome) = registration else {
            return (registration, nil)
        }
        if case .skipped = outcome { return (registration, nil) }

        let preauth: Result<PreauthorizationOutcome, Error>
        do {
            preauth = .success(try registrar.preauthorize(tools: Localmem.preauthorizedToolNames))
        } catch {
            preauth = .failure(error)
        }
        return (registration, preauth)
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

            // Do the work off the main task so the spinner can animate.
            let r = registrar
            let preauth = preauthorize
            let result = await Task.detached {
                Self.processClient(r, binaryPath: binaryPath, preauthorize: preauth)
            }.value

            spinTask.cancel()

            // Overwrite the spinner line with the completion line + newline.
            // After this, the cursor is on a fresh empty line ready for the
            // next spinner.
            let row = SetupReport.Row(
                name: name,
                outcome: result.0,
                preauthorization: result.1
            )
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
            let (outcome, preauth) = Self.processClient(
                registrar,
                binaryPath: binaryPath,
                preauthorize: preauthorize
            )
            rows.append(.init(
                name: registrar.displayName,
                outcome: outcome,
                preauthorization: preauth
            ))
        }
        var report = SetupReport(rows: rows)
        if instructions {
            report.instructionRows = try runInstructionsInstall()
        }
        print(report.render())
    }
}
