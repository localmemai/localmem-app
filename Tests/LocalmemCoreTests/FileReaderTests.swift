import Foundation
import Testing
@testable import LocalmemCore

@Suite("FileReader")
struct FileReaderTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lm-fr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, _ body: String) throws -> URL {
        let url = try tempDir().appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Reading a text file returns its trimmed body, a hash, and processed status")
    func readsText() throws {
        let url = try write("a.md", "  hello world  \n")
        let result = FileReader().read(url, relPath: "a.md")
        #expect(result.status == .processed)
        #expect(result.text == "hello world")
        #expect(result.truncated == false)
        #expect(result.sha256?.count == 64)          // hex SHA-256
        #expect(result.reasonCode == nil)
    }

    @Test("A missing file is failed with a 'missing' reason")
    func missingFails() throws {
        let url = try tempDir().appendingPathComponent("gone.md")   // never created
        let result = FileReader().read(url, relPath: "gone.md")
        #expect(result.status == .failed)
        #expect(result.reasonCode == "missing")
        #expect(result.text == nil)
    }

    @Test("An unsupported extension is skipped, not read")
    func unsupportedSkipped() throws {
        let url = try write("data.bin", "whatever")
        let result = FileReader().read(url, relPath: "data.bin")
        #expect(result.status == .skipped)
        #expect(result.reasonCode == "unsupported")
    }

    @Test("An empty file is skipped with an 'empty' reason")
    func emptySkipped() throws {
        let url = try write("blank.txt", "   \n\t ")
        let result = FileReader().read(url, relPath: "blank.txt")
        #expect(result.status == .skipped)
        #expect(result.reasonCode == "empty")
    }

    @Test("A file over the size limit is skipped before being read")
    func oversizeSkipped() throws {
        let url = try tempDir().appendingPathComponent("huge.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        // Sparse file just past the limit — no need to write real bytes.
        try handle.truncate(atOffset: UInt64(ConnectorLimits.maxFileSizeBytes + 1))
        try handle.close()

        let result = FileReader().read(url, relPath: "huge.txt")
        #expect(result.status == .skipped)
        #expect(result.reasonCode == "too_large")
        #expect(result.text == nil)
    }

    @Test("Text past the character cap is truncated and marked partial")
    func truncatesLongText() throws {
        let body = String(repeating: "a", count: ConnectorLimits.maxTextChars + 500)
        let url = try write("long.txt", body)
        let result = FileReader().read(url, relPath: "long.txt")
        #expect(result.status == .partial)
        #expect(result.truncated)
        #expect(result.reasonCode == "truncated_size")
        #expect(result.text?.count == ConnectorLimits.maxTextChars)
    }

    @Test("A non-UTF8 file falls back to Latin-1 rather than failing")
    func latin1Fallback() throws {
        let url = try tempDir().appendingPathComponent("latin.txt")
        // 0xE9 is 'é' in Latin-1 but an invalid standalone UTF-8 byte.
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)   // "caf" + 0xE9
        let result = FileReader().read(url, relPath: "latin.txt")
        #expect(result.status == .processed)
        #expect(result.text?.hasPrefix("caf") == true)
    }
}
