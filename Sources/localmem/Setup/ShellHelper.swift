import Foundation

enum ShellHelper {
    struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    /// Returns true if `command` is found on PATH.
    static func commandExists(_ command: String) -> Bool {
        (try? run("/usr/bin/env", ["which", command]).exitCode) == 0
    }

    @discardableResult
    static func run(_ command: String, _ args: [String]) throws -> Result {
        let process = Process()
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            // Resolve via env so we pick up PATH lookups consistently.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func runOrThrow(_ command: String, _ args: [String]) throws {
        let result = try run(command, args)
        guard result.exitCode == 0 else {
            throw ShellError.commandFailed(
                command: command,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    enum ShellError: Error, CustomStringConvertible {
        case commandFailed(command: String, exitCode: Int32, stderr: String)

        var description: String {
            switch self {
            case .commandFailed(let cmd, let code, let stderr):
                return "\(cmd) exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
