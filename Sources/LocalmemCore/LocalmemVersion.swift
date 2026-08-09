import Foundation

/// The single source of truth for Localmem's version, shared by all three
/// binaries (`localmem --version`, the MCP server's `initialize` response,
/// and anywhere else a version string is needed).
public enum LocalmemVersion {
    public static let current = "1.0.1"
}

/// Component-wise semver comparison helper (§12 of Technical Design).
public enum SemVerComparer {
    public static func compare(_ v1: String, _ v2: String) -> ComparisonResult {
        let clean1 = v1.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
        let clean2 = v2.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)

        let base1 = clean1.split(separator: "-").first ?? ""
        let base2 = clean2.split(separator: "-").first ?? ""

        let parts1 = base1.split(separator: ".").compactMap { Int($0) }
        let parts2 = base2.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let num1 = i < parts1.count ? parts1[i] : 0
            let num2 = i < parts2.count ? parts2[i] : 0
            if num1 < num2 { return .orderedAscending }
            if num1 > num2 { return .orderedDescending }
        }
        return .orderedSame
    }
}
