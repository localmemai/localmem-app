import Foundation
import OSLog

public enum LogCategory: String, Sendable {
    case store, mcp, cli, setup
}

public enum Log {
    private static let subsystem = "com.localmem"
    private static let handler = RotatingFileLogHandler()

    public static func debug(_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:]) {
        write(.debug, category, message, context)
    }

    public static func info(_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:]) {
        write(.info, category, message, context)
    }

    public static func notice(_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:]) {
        write(.notice, category, message, context)
    }

    public static func error(_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:]) {
        write(.error, category, message, context)
    }

    public static func fault(_ category: LogCategory, _ message: @autoclosure () -> String, _ context: [String: String] = [:]) {
        write(.fault, category, message, context)
    }

    private static func write(_ level: LogLevel, _ category: LogCategory, _ message: () -> String, _ context: [String: String]) {
        guard level >= minimumLevel else { return }
        let text = message()
        emit(level, category, text)

        guard level >= fileMinimumLevel else { return }
        let record = LogRecord(
            ts: DateFormat.iso8601.string(from: Date()),
            level: level.rawValue,
            category: category.rawValue,
            message: text,
            context: context.isEmpty ? nil : context
        )
        guard
            let data = try? JSONEncoder().encode(record),
            let line = String(data: data, encoding: .utf8)
        else {
            return
        }
        handler.write(line + "\n")
    }

    private static func emit(_ level: LogLevel, _ category: LogCategory, _ text: String) {
        let logger = LoggerCache.logger(for: category, subsystem: subsystem)
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .fault: logger.fault("\(text, privacy: .public)")
        }
    }

    /// Effective minimum level for any sink. Set via `LOCALMEM_LOG_LEVEL` env
    /// var; defaults to `.info` so noisy debug lines stay off in production.
    private static var minimumLevel: LogLevel {
        envLevel("LOCALMEM_LOG_LEVEL") ?? .info
    }

    /// File sink can be configured separately for diagnostic captures.
    private static var fileMinimumLevel: LogLevel {
        envLevel("LOCALMEM_LOG_FILE_LEVEL") ?? .notice
    }

    private static func envLevel(_ name: String) -> LogLevel? {
        guard let raw = ProcessInfo.processInfo.environment[name]?.lowercased() else {
            return nil
        }
        return LogLevel(rawValue: raw)
    }
}

private enum LoggerCache {
    nonisolated(unsafe) private static var cache: [String: Logger] = [:]
    private static let lock = NSLock()

    static func logger(for category: LogCategory, subsystem: String) -> Logger {
        lock.withLock {
            if let cached = cache[category.rawValue] { return cached }
            let made = Logger(subsystem: subsystem, category: category.rawValue)
            cache[category.rawValue] = made
            return made
        }
    }
}

private struct LogRecord: Encodable {
    let ts: String
    let level: String
    let category: String
    let message: String
    let context: [String: String]?
}

private enum LogLevel: String, Comparable {
    case debug, info, notice, error, fault

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .error: 3
        case .fault: 4
        }
    }
}

/// Synchronous, lock-serialised file writer with size-based rotation. Each
/// write opens the handle, appends, closes — simple and ordering-safe across
/// threads because the lock serialises the whole sequence. Per-line file IO is
/// well under a millisecond and these calls are infrequent (notice-and-above
/// only), so an async actor buys nothing.
final class RotatingFileLogHandler: @unchecked Sendable {
    private let directory: URL
    private let activeURL: URL
    private let maxBytes: UInt64
    private let retainedArchives: Int
    private let lock = NSLock()
    private var failedWriteWasReported = false

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("Localmem"),
        baseName: String = "localmem.log",
        maxBytes: Int = 10_000_000,
        retainedArchives: Int = 5
    ) {
        self.directory = directory
        self.activeURL = directory.appendingPathComponent(baseName)
        self.maxBytes = UInt64(maxBytes)
        self.retainedArchives = retainedArchives
    }

    func write(_ line: String) {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bytes = UInt64(line.utf8.count)
                if try currentSize() + bytes > maxBytes {
                    try rotate()
                }
                if !FileManager.default.fileExists(atPath: activeURL.path) {
                    FileManager.default.createFile(atPath: activeURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: activeURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
                failedWriteWasReported = false
            } catch {
                if !failedWriteWasReported {
                    failedWriteWasReported = true
                    Logger(subsystem: "com.localmem", category: "store")
                        .error("Failed to write Localmem log file: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func currentSize() throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return 0 }
        let attrs = try FileManager.default.attributesOfItem(atPath: activeURL.path)
        return attrs[.size] as? UInt64 ?? 0
    }

    private func rotate() throws {
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return }
        for index in stride(from: retainedArchives, through: 1, by: -1) {
            let source = archiveURL(index)
            let destination = archiveURL(index + 1)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                if index == retainedArchives {
                    try FileManager.default.removeItem(at: source)
                } else {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            }
        }
        try FileManager.default.moveItem(at: activeURL, to: archiveURL(1))
    }

    private func archiveURL(_ index: Int) -> URL {
        directory.appendingPathComponent("localmem.\(index).log")
    }
}
