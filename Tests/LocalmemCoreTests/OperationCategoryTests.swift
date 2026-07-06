import Testing
@testable import LocalmemCore

/// `OperationCategory.classify` is the single classifier that drives the Audit
/// Log's kind filter and event-dot color, so the operation → bucket mapping is
/// worth pinning down. (Moved here from the app target so it runs headlessly in
/// CI.)
@Suite("OperationCategory.classify")
struct OperationCategoryTests {
    @Test func readsAreClassifiedAsReads() {
        #expect(OperationCategory.classify("memory_search") == .reads)
        #expect(OperationCategory.classify("memory_recent") == .reads)
    }

    @Test func writesAreClassifiedAsWrites() {
        #expect(OperationCategory.classify("memory_store") == .writes)
        #expect(OperationCategory.classify("memory_update") == .writes)
        #expect(OperationCategory.classify("memory_delete") == .writes)
    }

    @Test func accessOperationsAreClassifiedAsAccess() {
        #expect(OperationCategory.classify("access_grant") == .access)
        #expect(OperationCategory.classify("access_revoke") == .access)
        #expect(OperationCategory.classify("access_grant_all") == .access)
        #expect(OperationCategory.classify("access_revoke_all") == .access)
        #expect(OperationCategory.classify("access_filtered") == .access)
        #expect(OperationCategory.classify("access_blocked") == .access)
    }

    @Test func unknownOperationsFallBackToWrites() {
        #expect(OperationCategory.classify("something_new") == .writes)
    }
}
