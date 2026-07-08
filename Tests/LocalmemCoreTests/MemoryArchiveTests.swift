import Testing
import Foundation
@testable import LocalmemCore

@Suite("MemoryArchive")
struct MemoryArchiveTests {
    private func sampleMemory() -> Memory {
        Memory(
            type: .preference,
            title: "Coffee",
            content: "Flat white, oat milk.",
            tags: ["coffee", "drink"],
            excludedAgents: ["some-agent"],
            source: "user"
        )
    }

    @Test func roundTripsAllFields() throws {
        let original = sampleMemory()
        let data = try MemoryArchive.encode([original])
        let decoded = try MemoryArchive.decode(data)

        #expect(decoded.count == 1)
        let m = try #require(decoded.first)
        #expect(m.id == original.id)
        #expect(m.type == original.type)
        #expect(m.title == original.title)
        #expect(m.content == original.content)
        #expect(Set(m.tags) == Set(original.tags))
        #expect(m.excludedAgents == original.excludedAgents)
        #expect(m.source == original.source)
        // Dates survive the ISO-8601 hop to within formatter precision.
        #expect(abs(m.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
        #expect(abs(m.updatedAt.timeIntervalSince(original.updatedAt)) < 0.001)
    }

    @Test func rejectsNewerSchemaVersion() throws {
        // A well-formed envelope whose only problem is a too-new version — so
        // we're exercising the version guard, not date/field parsing.
        let future = MemoryArchive.currentSchemaVersion + 1
        let json = """
        {"schemaVersion": \(future), "exportedAt": "2026-07-08T00:00:00.000Z", "app": "Localmem", "memories": []}
        """
        let data = Data(json.utf8)

        #expect {
            _ = try MemoryArchive.decode(data)
        } throws: { error in
            guard case .unsupportedVersion = error as? MemoryArchiveError else { return false }
            return true
        }
    }

    @Test func rejectsMalformedJSON() throws {
        let junk = Data("not an archive".utf8)
        #expect(throws: MemoryArchiveError.self) {
            _ = try MemoryArchive.decode(junk)
        }
    }

    @Test func encodesVersionedEnvelope() throws {
        let data = try MemoryArchive.encode([sampleMemory()])
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schemaVersion\""))
        #expect(json.contains("\"exportedAt\""))
        #expect(json.contains("\"memories\""))
    }
}
