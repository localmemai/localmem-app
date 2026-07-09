import Foundation
import CryptoKit
#if canImport(PDFKit)
import PDFKit
#endif

/// The result of reading one file: extracted text (nil when skipped/failed) plus
/// a status/reason the connector surfaces. The size gate runs before the file is
/// read, so an oversized PDF is never parsed or loaded into memory.
public struct ReadFile: Sendable {
    public var relPath: String
    public var text: String?
    public var sha256: String?
    public var modifiedAt: Date?
    public var status: SourceFileState.Status
    public var reasonCode: String?
    public var error: String?
    public var truncated: Bool
}

public struct FileReader: Sendable {
    public init() {}

    /// Supported files under a source root (recursive for folders), capped.
    public func enumerate(root: URL, kind: ImportSource.Kind) -> [URL] {
        if kind == .file { return [root] }
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in walker {
            guard ConnectorLimits.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
            if files.count >= ConnectorLimits.maxFilesPerSource { break }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// A file's path relative to the source root (for display + linking).
    public func relPath(of url: URL, root: URL, kind: ImportSource.Kind) -> String {
        if kind == .file { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    public func read(_ url: URL, relPath: String) -> ReadFile {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = attrs?[.modificationDate] as? Date

        // Size gate first — a too-big file is never read or parsed.
        if size > ConnectorLimits.maxFileSizeBytes {
            let limitMB = ConnectorLimits.maxFileSizeBytes / (1024 * 1024)
            let actualMB = Double(size) / (1024 * 1024)
            return skip(relPath, mtime, "too_large",
                        String(format: "File is %.0f MB (limit %d MB).", actualMB, limitMB))
        }

        let ext = url.pathExtension.lowercased()
        let raw: String?
        if ext == "pdf" {
            raw = Self.readPDF(url)
            if raw == nil {
                return skip(relPath, mtime, "no_text",
                            "PDF has no extractable text (looks scanned — OCR isn't supported).")
            }
        } else {
            raw = Self.readText(url)
            if raw == nil {
                return fail(relPath, mtime, "read_error",
                            "Couldn't read the file (permission or unsupported encoding).")
            }
        }

        var body = raw!.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return skip(relPath, mtime, "empty", "File is empty.")
        }

        var truncated = false
        if body.count > ConnectorLimits.maxTextChars {
            body = String(body.prefix(ConnectorLimits.maxTextChars))
            truncated = true
        }

        return ReadFile(
            relPath: relPath,
            text: body,
            sha256: Self.sha256(body),
            modifiedAt: mtime,
            status: truncated ? .partial : .processed,
            reasonCode: truncated ? "truncated_size" : nil,
            error: truncated ? "Large file — extracted the first \(ConnectorLimits.maxTextChars / 1000)k characters." : nil,
            truncated: truncated
        )
    }

    // MARK: - Helpers

    private func skip(_ relPath: String, _ mtime: Date?, _ code: String, _ message: String) -> ReadFile {
        ReadFile(relPath: relPath, text: nil, sha256: nil, modifiedAt: mtime,
                 status: .skipped, reasonCode: code, error: message, truncated: false)
    }

    private func fail(_ relPath: String, _ mtime: Date?, _ code: String, _ message: String) -> ReadFile {
        ReadFile(relPath: relPath, text: nil, sha256: nil, modifiedAt: mtime,
                 status: .failed, reasonCode: code, error: message, truncated: false)
    }

    private static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        return nil
    }

    private static func readPDF(_ url: URL) -> String? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else { return nil }
        let s = doc.string ?? ""
        return s.isEmpty ? nil : s
        #else
        return nil
        #endif
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
