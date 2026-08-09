import Testing
import Foundation
@testable import LocalmemCore

@Suite struct SemVerComparerTests {
    @Test func testSameVersion() {
        #expect(SemVerComparer.compare("1.0.1", "1.0.1") == .orderedSame)
        #expect(SemVerComparer.compare("v1.0.1", "1.0.1") == .orderedSame)
        #expect(SemVerComparer.compare("V1.0.1", "v1.0.1") == .orderedSame)
    }

    @Test func testMajorMinorPatchComparison() {
        #expect(SemVerComparer.compare("1.1.0", "1.0.1") == .orderedDescending)
        #expect(SemVerComparer.compare("1.0.0", "1.0.1") == .orderedAscending)
        #expect(SemVerComparer.compare("2.0.0", "1.99.99") == .orderedDescending)
        #expect(SemVerComparer.compare("1.10.0", "1.9.0") == .orderedDescending)
    }

    @Test func testDifferentLengths() {
        #expect(SemVerComparer.compare("1.0", "1.0.0") == .orderedSame)
        #expect(SemVerComparer.compare("1.0.1.1", "1.0.1") == .orderedDescending)
    }

    @Test func testBuildMetadataStripping() {
        #expect(SemVerComparer.compare("1.2.0-beta.1", "1.1.9") == .orderedDescending)
        #expect(SemVerComparer.compare("v2.1.0-rc1", "v2.1.0") == .orderedSame)
    }
}
