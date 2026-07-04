import Testing
@testable import localmem_app

/// `AuditLogViewModel.category(of:)` is the single classifier that drives the
/// Audit Log's kind filter and event-dot color, so the operation → bucket
/// mapping is worth pinning down.
@Suite("AuditLogViewModel.category")
struct AuditLogTests {
    @Test func readsAreClassifiedAsReads() {
        #expect(AuditLogViewModel.category(of: "memory_search") == .reads)
        #expect(AuditLogViewModel.category(of: "memory_recent") == .reads)
    }

    @Test func writesAreClassifiedAsWrites() {
        #expect(AuditLogViewModel.category(of: "memory_store") == .writes)
        #expect(AuditLogViewModel.category(of: "memory_update") == .writes)
        #expect(AuditLogViewModel.category(of: "memory_delete") == .writes)
    }

    @Test func accessOperationsAreClassifiedAsAccess() {
        #expect(AuditLogViewModel.category(of: "access_grant") == .access)
        #expect(AuditLogViewModel.category(of: "access_revoke") == .access)
        #expect(AuditLogViewModel.category(of: "access_grant_all") == .access)
        #expect(AuditLogViewModel.category(of: "access_revoke_all") == .access)
        #expect(AuditLogViewModel.category(of: "access_filtered") == .access)
        #expect(AuditLogViewModel.category(of: "access_blocked") == .access)
    }

    @Test func unknownOperationsFallBackToWrites() {
        #expect(AuditLogViewModel.category(of: "something_new") == .writes)
    }
}
