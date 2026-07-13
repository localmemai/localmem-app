import Foundation

/// A portable, versioned JSON container for exporting and importing memories.
///
/// The archive is the on-disk format behind the app's Import/Export feature and
/// the wire format for moving a vault between machines. It lives in the core
/// (not the GUI) so the CLI can reuse it and the codec is unit-testable without
/// linking AppKit.
///
/// `memories` uses `Memory`'s synthesized `Codable` conformance, so every field
/// — id, timestamps, tags, exclusions, source — round-trips at full fidelity.
public struct MemoryArchive: Codable, Sendable, Equatable {
    /// The archive format version. Bump when the shape of the envelope or of a
    /// `Memory` changes in a way importers must reason about. Importers reject
    /// anything newer than `currentSchemaVersion`.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let app: String
    public let memories: [Memory]

    public init(
        schemaVersion: Int = MemoryArchive.currentSchemaVersion,
        exportedAt: Date = Date(),
        app: String = "Localmem",
        memories: [Memory]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.app = app
        self.memories = memories
    }

    // MARK: - Codec

    /// ISO-8601 dates + sorted, pretty-printed keys so exports are stable,
    /// diff-friendly, and human-inspectable outside the app. Dates use the same
    /// fractional-second `DateFormat.iso8601` the store persists with, so a
    /// round-trip through an archive preserves timestamps exactly (JSONEncoder's
    /// built-in `.iso8601` strategy would silently drop sub-second precision).
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DateFormat.iso8601.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = DateFormat.iso8601.date(from: string) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid ISO-8601 date: \(string)"
                ))
            }
            return date
        }
        return d
    }

    /// Serializes `memories` into a versioned archive blob ready to write to disk.
    public static func encode(_ memories: [Memory], exportedAt: Date = Date()) throws -> Data {
        try encoder.encode(MemoryArchive(exportedAt: exportedAt, memories: memories))
    }

    /// Parses an archive blob, rejecting formats this build is too old to
    /// understand. Returns the contained memories; callers decide how to merge
    /// them into the store.
    public static func decode(_ data: Data) throws -> [Memory] {
        let archive: MemoryArchive
        do {
            archive = try decoder.decode(MemoryArchive.self, from: data)
        } catch {
            throw MemoryArchiveError.malformed(underlying: error)
        }
        guard archive.schemaVersion <= currentSchemaVersion else {
            throw MemoryArchiveError.unsupportedVersion(
                found: archive.schemaVersion,
                supported: currentSchemaVersion
            )
        }
        return archive.memories
    }
}

public enum MemoryArchiveError: Error, LocalizedError {
    /// The file isn't a Localmem archive, or is corrupt/truncated.
    case malformed(underlying: Error)
    /// The archive was written by a newer app that changed the format.
    case unsupportedVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .malformed:
            return "This file isn't a valid Localmem export."
        case let .unsupportedVersion(found, supported):
            return "This export was created by a newer version of Localmem "
                + "(format \(found), this app supports up to \(supported)). "
                + "Update Localmem and try again."
        }
    }
}

/// Outcome of importing an archive: how many rows were newly added versus
/// skipped because a memory with the same id already existed.
public struct ImportSummary: Sendable, Equatable {
    public let imported: Int
    public let skipped: Int

    public init(imported: Int, skipped: Int) {
        self.imported = imported
        self.skipped = skipped
    }
}
