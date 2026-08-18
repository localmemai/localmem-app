import Foundation

public enum ProcessUtility {
    /// Hard ceiling for the `lsof` probe. This runs on the `memory_store` path,
    /// so it must never be able to wedge the server: an unresponsive network
    /// mount can make `lsof` block indefinitely, and a stalled probe would take
    /// every subsequent tool call down with it. Failing to detect the project is
    /// harmless — the memory lands in Inbox.
    private static let cwdProbeTimeout: TimeInterval = 2.0

    /// Discovers the current working directory of the parent process on macOS.
    ///
    /// `async`, and all blocking work happens on a global queue: this is called
    /// from an actor, and waiting on `DispatchGroup` from a Swift-concurrency
    /// cooperative thread while depending on global-queue work items starves the
    /// pool and deadlocks under load.
    /// Memoized per parent pid for the life of the server.
    ///
    /// This probe forks `lsof` and then walks parent directories looking for a
    /// `.git`, which is tens to hundreds of milliseconds on a busy machine — and
    /// it ran on *every* `memory_store` without an explicit project root. The
    /// parent of an MCP session is a single client process whose working
    /// directory does not change for as long as that session lives, so the
    /// answer is stable. A `nil` result is cached too: repeatedly re-paying for
    /// a probe that already failed is the case worth avoiding most, and a miss
    /// is harmless — the memory lands in Inbox.
    private static let cwdCache = CWDCache()

    private actor CWDCache {
        private var byPPID: [pid_t: String?] = [:]

        func cwd(for ppid: pid_t, probe: @Sendable () async -> String?) async -> String? {
            if let cached = byPPID[ppid] { return cached }
            let value = await probe()
            byPPID[ppid] = value
            return value
        }
    }

    public static func getParentCWD() async -> String? {
        await cwdCache.cwd(for: getppid()) {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: probeParentCWD())
                }
            }
        }
    }

    private static func probeParentCWD() -> String? {
        let ppid = getppid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", String(ppid), "-a", "-d", "cwd", "-Fn"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes off-thread and start draining before the process can
        // fill them. `lsof` on a machine with many open files can exceed the
        // ~64 KB pipe buffer, and a full, unread pipe blocks the child forever —
        // reading only after `waitUntilExit()` deadlocks exactly then. stderr
        // needs draining for the same reason even though its content is unused.
        var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + cwdProbeTimeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        guard process.terminationStatus == 0,
              let output = String(data: outData, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: .newlines) where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Walk up from a directory to find the nearest parent directory containing a `.git` folder.
    public static func findGitRoot(from startPath: String) -> String? {
        var currentPath = startPath
        let fileManager = FileManager.default

        while !currentPath.isEmpty && currentPath != "/" {
            let gitPath = (currentPath as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                return currentPath
            }
            let parent = (currentPath as NSString).deletingLastPathComponent
            // `deletingLastPathComponent` is a fixed point on a bare component
            // ("foo" → "foo"), so a relative start path would loop forever.
            guard parent != currentPath else { return nil }
            currentPath = parent
        }
        return nil
    }
}
