/// The coarse bucket an activity/MCP operation falls into, used to classify
/// audit-log events (and drive the log's kind filter). This is UI-agnostic
/// provenance logic — the app maps these buckets to labels and colors — so it
/// lives in the core where it can be unit-tested without linking the GUI.
public enum OperationCategory: Sendable, Equatable {
    case reads
    case writes
    case access

    /// Classify an operation string (e.g. `memory_search`, `memory_store`,
    /// `access_grant`). Reads are the non-mutating lookups; anything prefixed
    /// `access_` is an access-control change; everything else is a write.
    public static func classify(_ operation: String) -> OperationCategory {
        switch operation {
        case "memory_search", "memory_recent":
            return .reads
        default:
            return operation.hasPrefix("access_") ? .access : .writes
        }
    }
}
