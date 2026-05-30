import Foundation
import Testing
import LocalmemCore
@testable import localmem
#if canImport(Darwin)
import Darwin
#endif

@Suite("OutputFormatter", .serialized)
struct OutputFormatterTests {
    @Test("printTable prints the (no memories) placeholder when given an empty array")
    func tableEmpty() throws {
        let out = try captureStdout { OutputFormatter.printTable([]) }
        #expect(out.contains("(no memories)"))
    }

    @Test("printTable renders a header row and one row per memory, using the title when present")
    func tableNonEmptyUsesTitle() throws {
        let memory = Memory(type: .note, title: "Title Row", content: "Body", source: .user)
        let out = try captureStdout { OutputFormatter.printTable([memory]) }
        #expect(out.contains("ID"))
        #expect(out.contains("TYPE"))
        #expect(out.contains("Title Row"))
    }

    @Test("printTable falls back to the content prefix when title is nil")
    func tableFallsBackToContent() throws {
        let memory = Memory(type: .note, title: nil, content: "preview-fallback", source: .user)
        let out = try captureStdout { OutputFormatter.printTable([memory]) }
        #expect(out.contains("preview-fallback"))
    }

    @Test("printDetail emits id, type, source, title, tags, and the body block")
    func detail() throws {
        let memory = Memory(
            type: .preference,
            title: "Coffee",
            content: "flat white, oat",
            tags: ["a", "b"],
            source: .user
        )
        let out = try captureStdout { OutputFormatter.printDetail(memory) }
        #expect(out.contains(memory.id.uuidString))
        #expect(out.contains("preference"))
        #expect(out.contains("user"))
        #expect(out.contains("Coffee"))
        #expect(out.contains("a, b"))
        #expect(out.contains("flat white, oat"))
    }

    @Test("printDetail omits title and tags lines when neither is present")
    func detailOmitsOptionalLines() throws {
        let memory = Memory(type: .note, content: "bare content", source: .user)
        let out = try captureStdout { OutputFormatter.printDetail(memory) }
        #expect(!out.contains("title:"))
        #expect(!out.contains("tags:"))
        #expect(out.contains("bare content"))
    }

    @Test("printJSON emits sorted-key, pretty-printed JSON")
    func json() throws {
        struct Item: Encodable { let a: Int; let b: Int }
        let out = try captureStdout {
            try OutputFormatter.printJSON([Item(a: 1, b: 2)])
        }
        let aIdx = out.range(of: "\"a\"")?.lowerBound
        let bIdx = out.range(of: "\"b\"")?.lowerBound
        #expect(aIdx != nil && bIdx != nil)
        if let aIdx, let bIdx { #expect(aIdx < bIdx, "sortedKeys must place a before b") }
        #expect(out.contains("\n"), "prettyPrinted output should contain newlines")
    }
}

/// Redirect fd 1 through a pipe for the duration of `body`, then read what was
/// written. Restores stdout even if `body` throws, so a test failure mid-print
/// can't permanently swap the runner's stdout.
private func captureStdout(_ body: () throws -> Void) throws -> String {
    let pipe = Pipe()
    let savedFd = dup(fileno(stdout))
    fflush(stdout)
    dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))

    var thrown: Error?
    do { try body() } catch { thrown = error }

    fflush(stdout)
    dup2(savedFd, fileno(stdout))
    close(savedFd)
    try? pipe.fileHandleForWriting.close()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    if let thrown { throw thrown }
    return String(decoding: data, as: UTF8.self)
}
