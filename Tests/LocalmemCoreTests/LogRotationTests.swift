import Foundation
import Testing
@testable import LocalmemCore

@Suite("RotatingFileLogHandler")
struct LogRotationTests {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Archive filenames are hardcoded to `localmem.N.log` inside the handler,
    /// so tests use the default `baseName` to keep the active and archive
    /// names aligned with how production code rotates.
    @Test("write creates the directory, the active file, and appends each line")
    func writeCreatesAndAppends() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let handler = RotatingFileLogHandler(
            directory: dir,
            maxBytes: 1_000_000,
            retainedArchives: 3
        )
        handler.write("line one\n")
        handler.write("line two\n")

        let active = dir.appendingPathComponent("localmem.log")
        #expect(FileManager.default.fileExists(atPath: active.path))
        let contents = try String(contentsOf: active, encoding: .utf8)
        #expect(contents == "line one\nline two\n")
    }

    @Test("rotation triggers when the next write would exceed maxBytes")
    func rotationAtThreshold() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let handler = RotatingFileLogHandler(
            directory: dir,
            maxBytes: 20,
            retainedArchives: 5
        )
        handler.write("hello\n")
        handler.write("this is a long line that pushes us over\n")

        let active = dir.appendingPathComponent("localmem.log")
        let archive = dir.appendingPathComponent("localmem.1.log")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(try String(contentsOf: archive, encoding: .utf8) == "hello\n")
        #expect(try String(contentsOf: active, encoding: .utf8)
                == "this is a long line that pushes us over\n")
    }

    @Test("rotation cascades archives and drops the oldest beyond retainedArchives")
    func rotationCascadesAndDropsOldest() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let handler = RotatingFileLogHandler(
            directory: dir,
            maxBytes: 5,
            retainedArchives: 2
        )
        handler.write("a\n")
        handler.write("bbbbb\n")
        handler.write("ccccc\n")
        handler.write("ddddd\n")

        let active = dir.appendingPathComponent("localmem.log")
        let one = dir.appendingPathComponent("localmem.1.log")
        let two = dir.appendingPathComponent("localmem.2.log")
        let three = dir.appendingPathComponent("localmem.3.log")

        #expect(try String(contentsOf: active, encoding: .utf8) == "ddddd\n")
        #expect(try String(contentsOf: one, encoding: .utf8) == "ccccc\n")
        #expect(try String(contentsOf: two, encoding: .utf8) == "bbbbb\n")
        #expect(!FileManager.default.fileExists(atPath: three.path))
    }
}
