import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ShellHelper {
    struct Result { let exitCode: Int32; let stdout: String; let stderr: String }

    /// Hard ceiling on how long any spawned client CLI may run. These are
    /// config commands (`claude mcp add`, `codex mcp add`, …) that normally
    /// finish in well under a second; the cap only exists so a wedged child
    /// can never hang `localmem setup` indefinitely.
    static let defaultTimeout: TimeInterval = 60

    /// Returns true if `command` is found on PATH. Walks PATH in-process
    /// rather than forking `which`, so a `localmem setup` of five registrars
    /// pays zero subprocess overhead for the existence checks.
    static func commandExists(_ command: String) -> Bool {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command)
        }
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            if fm.isExecutableFile(atPath: "\(dir)/\(command)") { return true }
        }
        return false
    }

    @discardableResult
    static func run(_ command: String, _ args: [String], timeout: TimeInterval = defaultTimeout) throws -> Result {
        let process = Process()
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            // Resolve via env so we pick up PATH lookups consistently.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }

        // Detach the child from the caller's terminal. Without this, an
        // interactive-aware CLI (e.g. `claude mcp list`, which does its own
        // job-control setup) reads the inherited TTY from a background process
        // group, gets stopped by SIGTTIN, and our wait never returns — setup
        // hangs forever. `nullDevice` makes any stdin read return EOF instead.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes on background queues so a child that writes more
        // than the OS pipe buffer (~64KB) can't deadlock against our wait.
        var outData = Data()
        var errData = Data()
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "localmem.shellhelper.io", attributes: .concurrent)
        ioQueue.async(group: ioGroup) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        ioQueue.async(group: ioGroup) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()                                  // SIGTERM
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)         // last resort
            }
            ioGroup.wait()
            throw ShellError.timedOut(command: command, seconds: timeout)
        }

        ioGroup.wait()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
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
        case timedOut(command: String, seconds: TimeInterval)

        var description: String {
            switch self {
            case .commandFailed(let cmd, let code, let stderr):
                return "\(cmd) exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .timedOut(let cmd, let seconds):
                return "\(cmd) did not finish within \(Int(seconds))s and was terminated."
            }
        }
    }
}
