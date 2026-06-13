import SwiftUI
import AppKit
import LocalmemCore

@main
struct LocalmemApp: App {
    init() {
        // SwiftPM executables aren't .app bundles, so macOS defaults the
        // process to a background-only app and the window never appears.
        // Force regular foreground policy. Use NSApplication.shared, not
        // NSApp — the latter is nil before SwiftUI bootstraps the app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Localmem") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - Sections (Phase 2)

enum AppSection: String, CaseIterable, Hashable {
    case overview, memories, agents, access, audit, sync, connectors

    var label: String {
        switch self {
        case .overview:   "Overview"
        case .memories:   "Memories"
        case .agents:     "Agents"
        case .access:     "Access Roster"
        case .audit:      "Audit Log"
        case .sync:       "Sync & Devices"
        case .connectors: "Connectors"
        }
    }

    var symbol: String {
        switch self {
        case .overview:   "square.grid.2x2"
        case .memories:   "doc.text"
        case .agents:     "person.crop.square"
        case .access:     "lock.shield"
        case .audit:      "list.bullet.rectangle"
        case .sync:       "icloud"
        case .connectors: "arrow.left.arrow.right"
        }
    }
}

// MARK: - Source palette (Phase 6 — kept from earlier iteration)

enum SourcePalette {
    static func color(for source: String?) -> Color? {
        switch source {
        case "user":                           return .accentColor
        case "claude-code", "claude-desktop":  return .orange
        case "cursor":                         return .purple
        case "codex":                          return .green
        case "antigravity", "antigravity-client": return .pink
        case "phone":                          return .cyan
        case nil, "":                          return nil   // hollow ring
        default:                               return .gray
        }
    }
}

struct SourceDot: View {
    let source: String?
    var size: CGFloat = 10

    var body: some View {
        if let color = SourcePalette.color(for: source) {
            Circle().fill(color).frame(width: size, height: size)
        } else {
            Circle().stroke(.gray.opacity(0.6), lineWidth: 1)
                .frame(width: size, height: size)
        }
    }
}

/// Identity + UI snapshot for a single connected agent. The "snapshot" framing
/// is deliberate — the data here is rebuilt each render from
/// `VaultStatusViewModel.recentActivity` and the shared agent catalog.
struct AgentSnapshot: Identifiable, Hashable {
    let id: String           // matches `actor_id` written by the MCP server.
    let displayName: String
    let symbol: String
    let isConnected: Bool
    let lastAccess: Date?
    let reads: Int
    let writes: Int
}

// MARK: - Pill (reusable across pages)

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - View models (Phase 5, 7, 12)

@Observable @MainActor
final class MemoryStoreViewModel {
    private(set) var memories: [Memory] = []
    private(set) var loadError: String?
    private let store: MemoryStore

    init() throws { self.store = try MemoryStore() }

    /// Single entry point for both initial load and live search. Empty query
    /// falls back to `recent` so the lists always have something to show.
    func search(_ query: String, limit: Int = 50) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        do {
            memories = trimmed.isEmpty
                ? try await store.recent(limit: limit)
                : try await store.search(query: trimmed, limit: limit)
            loadError = nil
        } catch {
            memories = []
            loadError = String(describing: error)
        }
    }

    @discardableResult
    func create(
        title: String?,
        type: MemoryType,
        content: String,
        tags: [String],
        excludedAgents: [String] = []
    ) async throws -> Memory.ID {
        let memory = try await store.add(
            content: content,
            type: type,
            title: title?.isEmpty == false ? title : nil,
            tags: tags,
            excludedAgents: excludedAgents,
            actorKind: .cli,
            actorID: "user"
        )
        await search("")
        return memory.id
    }

    /// Replace an existing memory's mutable fields. Returns the new (post-
    /// update) version so callers can reflect the freshest data immediately
    /// without waiting for the reload.
    @discardableResult
    func update(
        id: Memory.ID,
        title: String?,
        type: MemoryType,
        content: String,
        tags: [String],
        excludedAgents: [String]? = nil
    ) async throws -> Memory {
        let updated = try await store.update(
            id: id,
            content: content,
            type: type,
            title: title?.isEmpty == false ? title : nil,
            tags: tags,
            excludedAgents: excludedAgents,
            actorKind: .cli,
            actorID: "user"
        )
        await search("")
        return updated
    }

    func delete(_ id: Memory.ID) async throws {
        _ = try await store.delete(id: id, actorKind: .cli, actorID: "user")
        await search("")
    }
}

/// Drives the bottom status bar's five segments and the Overview's stats strip
/// / activity panel. Polls once a second while visible.
@Observable @MainActor
final class VaultStatusViewModel {
    private(set) var vaultLocked = false       // Touch ID arrives in Phase 13.
    private(set) var connectedAgents: [String] = []
    private(set) var cloudSyncOn = false        // CloudKit arrives in Phase 14.
    private(set) var companionConnected = false // iPhone companion: future work.
    private(set) var lastActivity: Date?
    private(set) var memoryCount = 0
    private(set) var accessesToday = 0
    private(set) var blockedCount = 0           // We don't yet record blocks.
    private(set) var recentActivity: [Activity] = []

    private let activityStore: ActivityStore
    private let memoryStore: MemoryStore

    init() throws {
        self.activityStore = try ActivityStore()
        self.memoryStore = try MemoryStore()
    }

    func refresh() async {
        let rows = (try? await activityStore.recent(limit: 50)) ?? []
        recentActivity = rows
        connectedAgents = Array(Set(rows.compactMap(\.actorID))).sorted()
        lastActivity    = rows.first?.occurredAt
        memoryCount     = (try? await memoryStore.count()) ?? 0

        let startOfToday = Calendar.current.startOfDay(for: Date())
        accessesToday = rows.filter { $0.occurredAt >= startOfToday }.count
    }
}

// MARK: - Root shell (Phase 1)

/// Drives every modal presentation in the shell. One enum, one `.sheet(item:)`
/// modifier — easier to extend than a `showingX` `Bool` per case. Phase 9 will
/// add `.agentConfig(AgentSnapshot)` etc. without touching the call site.
enum SheetKind: Identifiable {
    case newMemory
    case editMemory(Memory)
    case agentConfig(AgentSnapshot)

    var id: String {
        switch self {
        case .newMemory:                 return "new"
        case .editMemory(let memory):    return "edit-\(memory.id)"
        case .agentConfig(let agent):    return "agent-\(agent.id)"
        }
    }
}

struct ContentView: View {
    @State private var section: AppSection = .overview
    @State private var query = ""
    @State private var sheet: SheetKind?
    @State private var memorySelection: Memory.ID?

    // try? swallows DB-open errors so the app launches into a degraded state
    // rather than crashing. Each VM is optional all the way down.
    @State private var memoryVM: MemoryStoreViewModel? = try? MemoryStoreViewModel()
    @State private var statusVM: VaultStatusViewModel? = try? VaultStatusViewModel()
    @State private var sidebarCollapsed = false

    var body: some View {
        // Two-level layout so the status bar spans the full window width:
        //   VStack {
        //     HStack { sidebar | (toolbar + content) }   // window body
        //     StatusBar                                   // full-width footer
        //   }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarRail(section: $section)
                        .frame(width: 244)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    TopToolbar(
                        query: $query,
                        sidebarCollapsed: sidebarCollapsed,
                        onToggleSidebar: {
                            withAnimation(.snappy) { sidebarCollapsed.toggle() }
                        },
                        onNewMemory: { sheet = .newMemory }
                    )
                    .frame(height: 52)

                    Divider()

                    ContentArea(
                        section: section,
                        memoryVM: memoryVM,
                        statusVM: statusVM,
                        memorySelection: $memorySelection,
                        onEditMemory: { memory in sheet = .editMemory(memory) },
                        onConfigureAgent: { agent in sheet = .agentConfig(agent) },
                        jumpToMemories: {
                            withAnimation(.snappy) { section = .memories }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Push the right column past the implicit content inset so
                // the toolbar sits flush with the top of the window — matches
                // the vault prototype.
                .ignoresSafeArea(.all, edges: .top)
            }

            Divider()

            if let statusVM {
                StatusBar(vm: statusVM)
                    .frame(height: 52)
            } else {
                StatusBarFallback().frame(height: 52)
            }
        }
        .task(id: query) { await memoryVM?.search(query) }
        .task {
            // Status bar polling — auto-cancels on view disappear.
            guard let statusVM else { return }
            while !Task.isCancelled {
                await statusVM.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .newMemory:
                if let memoryVM {
                    MemoryEditorView(mode: .new, vm: memoryVM) { newID in
                        memorySelection = newID
                        section = .memories
                    }
                }
            case .editMemory(let memory):
                if let memoryVM {
                    MemoryEditorView(mode: .edit(memory), vm: memoryVM) { updatedID in
                        memorySelection = updatedID
                    }
                }
            case .agentConfig(let agent):
                // In-memory configure only — Phase 10's persistence layer
                // arrives later. Save is a no-op for now.
                AgentConfigSheet(agent: agent)
            }
        }
    }
}

// MARK: - Sidebar rail (Phase 1, 2)

struct SidebarRail: View {
    @Binding var section: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandHeader()

            VStack(alignment: .leading, spacing: 4) {
                ForEach(AppSection.allCases, id: \.self) { item in
                    NavItem(item: item, isActive: item == section) {
                        withAnimation(.snappy) { section = item }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 15)
        .background(.regularMaterial)
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Text("L")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Localmem").font(.headline)
                Text("Private AI Memory Vault")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

struct NavItem: View {
    let item: AppSection
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(item.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                isActive ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Top toolbar (Phase 1)

struct TopToolbar: View {
    @Binding var query: String
    let sidebarCollapsed: Bool
    let onToggleSidebar: () -> Void
    let onNewMemory: () -> Void

    /// When the sidebar is collapsed, the toolbar runs all the way to the
    /// window's left edge — where macOS draws the traffic-light cluster.
    /// Indent the toggle button past them so they don't overlap.
    private var leadingInset: CGFloat {
        sidebarCollapsed ? 80 : 16
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSidebar) {
                Image(systemName: sidebarCollapsed ? "sidebar.left" : "sidebar.left")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Show sidebar" : "Hide sidebar")
            .keyboardShortcut("s", modifiers: [.command, .option])

            SearchField(text: $query)
                .frame(maxWidth: 420)

            Spacer()

            Button("Import") {}              // Phase 15
            Button("Export") {}              // Phase 15
            Button("+ New Memory", action: onNewMemory)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 16)
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search private memory vault", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Content router (Phase 2)

struct ContentArea: View {
    let section: AppSection
    let memoryVM: MemoryStoreViewModel?
    let statusVM: VaultStatusViewModel?
    @Binding var memorySelection: Memory.ID?
    let onEditMemory: (Memory) -> Void
    let onConfigureAgent: (AgentSnapshot) -> Void
    let jumpToMemories: () -> Void

    var body: some View {
        Group {
            switch section {
            case .overview:
                OverviewView(
                    memoryVM: memoryVM,
                    statusVM: statusVM,
                    jumpToMemories: jumpToMemories
                )
            case .memories:
                MemoriesView(
                    vm: memoryVM,
                    selection: $memorySelection,
                    onEdit: onEditMemory
                )
            case .agents:
                AgentsView(statusVM: statusVM, onConfigure: onConfigureAgent)
            case .access:
                AccessRulesView()
            case .audit:
                SectionStub(section: .audit,
                            note: "The full audit log page lands in Phase 11.")
            case .sync:
                SectionStub(section: .sync,
                            note: "CloudKit + device list lands in Phase 14.")
            case .connectors:
                SectionStub(section: .connectors,
                            note: "Obsidian / Markdown / JSON connectors land in Phase 15.")
            }
        }
    }
}

struct SectionStub: View {
    let section: AppSection
    let note: String

    var body: some View {
        ContentUnavailableView(
            section.label,
            systemImage: section.symbol,
            description: Text(note)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Overview (Phase 3)

struct OverviewView: View {
    let memoryVM: MemoryStoreViewModel?
    let statusVM: VaultStatusViewModel?
    let jumpToMemories: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Overview",
                    subtitle: "Recent memories and agent activity."
                )

                StatsStrip(statusVM: statusVM)

                HStack(alignment: .top, spacing: 20) {
                    Panel(title: "Recent Memories",
                          actionLabel: "View all",
                          onAction: jumpToMemories) {
                        if let memoryVM {
                            VStack(spacing: 6) {
                                ForEach(memoryVM.memories.prefix(5)) { memory in
                                    RecentMemoryRow(memory: memory,
                                                    onTap: jumpToMemories)
                                }
                                if memoryVM.memories.isEmpty {
                                    Text("No memories yet — try `+ New Memory` above.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Store unavailable.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    Panel(title: "Recent Agent Activity") {
                        if let statusVM {
                            VStack(spacing: 6) {
                                ForEach(statusVM.recentActivity.prefix(5)) { row in
                                    ActivityRow(activity: row)
                                }
                                if statusVM.recentActivity.isEmpty {
                                    Text("No activity yet — agents will show up here once they connect.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Activity unavailable.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(24)
        }
    }
}

struct StatsStrip: View {
    let statusVM: VaultStatusViewModel?

    var body: some View {
        HStack(spacing: 12) {
            StatCard(value: "\(statusVM?.memoryCount ?? 0)",
                     label: "Memories")
            StatCard(value: "\(statusVM?.connectedAgents.count ?? 0)",
                     label: "Agents")
            StatCard(value: "\(statusVM?.accessesToday ?? 0)",
                     label: "Accesses today")
            StatCard(value: "\(statusVM?.blockedCount ?? 0)",
                     label: "Blocked")
        }
    }
}

struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 28, weight: .bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RecentMemoryRow: View {
    let memory: Memory
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                SourceDot(source: memory.source)
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.title ?? String(memory.content.prefix(40)))
                        .lineLimit(1)
                    Text("\(memory.type.rawValue.capitalized) · \(memory.createdAt, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.green)   // Phase 10 introduces Blocked/Needs Review.
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(activity.actorID ?? "—")")
                        .fontWeight(.semibold)
                    Text(activity.operation)
                        .foregroundStyle(.secondary)
                }
                Text(activity.occurredAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}

// MARK: - Memories view (Phase 4)

struct MemoriesView: View {
    let vm: MemoryStoreViewModel?
    @Binding var selection: Memory.ID?
    let onEdit: (Memory) -> Void

    private var selected: Memory? {
        vm?.memories.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            MemoryListPane(memories: vm?.memories ?? [], selection: $selection)
                .frame(width: 320)
                .background(.background.secondary)

            Divider()

            MemoryDetailPane(
                memory: selected,
                vm: vm,
                onDeleted: { selection = nil },
                onEdit: onEdit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MemoryListPane: View {
    let memories: [Memory]
    @Binding var selection: Memory.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memories").font(.headline)
                Spacer()
                Text("\(memories.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if memories.isEmpty {
                ContentUnavailableView(
                    "No memories yet",
                    systemImage: "tray",
                    description: Text("Add one with **+ New Memory** above.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(memories, selection: $selection) { memory in
                    MemoryListRow(memory: memory)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct MemoryListRow: View {
    let memory: Memory

    var body: some View {
        HStack(spacing: 10) {
            SourceDot(source: memory.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.title ?? String(memory.content.prefix(40)))
                    .lineLimit(1)
                Text("\(memory.type.rawValue.capitalized) · \(memory.createdAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MemoryDetailPane: View {
    let memory: Memory?
    let vm: MemoryStoreViewModel?
    let onDeleted: () -> Void
    let onEdit: (Memory) -> Void

    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?

    var body: some View {
        if let memory {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(memory.title ?? "Untitled")
                            .font(.system(size: 28, weight: .bold))

                        MetadataStrip(memory: memory)

                        Text(memory.content)
                            .textSelection(.enabled)

                        // Read-only access summary, right after the content.
                        AgentAccessSummary(memory: memory)

                        if !memory.tags.isEmpty {
                            TagRow(tags: memory.tags)
                        }

                        if let deleteError {
                            Text(deleteError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Actions pinned to the bottom of the pane.
                HStack(spacing: 10) {
                    Button("Edit") { onEdit(memory) }
                    Button("Delete", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .tint(.red)
                    Button("Audit trail") {}                          // Phase 11
                    Spacer()
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
            }
            .confirmationDialog(
                "Delete this memory?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await performDelete(memory) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage(for: memory))
            }
        } else {
            ContentUnavailableView("Select a memory", systemImage: "doc.text")
        }
    }

    private func confirmationMessage(for memory: Memory) -> String {
        let title = memory.title ?? "(untitled)"
        let preview = memory.content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(160)
        let suffix = memory.content.count > 160 ? "…" : ""
        return "\(title)\n\n\(preview)\(suffix)"
    }

    private func performDelete(_ memory: Memory) async {
        guard let vm else { return }
        do {
            try await vm.delete(memory.id)
            onDeleted()
        } catch {
            deleteError = "Couldn't delete: \(error.localizedDescription)"
        }
    }
}

struct MetadataStrip: View {
    let memory: Memory

    var body: some View {
        HStack(spacing: 8) {
            SourceDot(source: memory.source, size: 8)
            Text(memory.source ?? "unknown")
            Bullet()
            Text(memory.type.rawValue)
            Bullet()
            Text(memory.createdAt, format: .relative(presentation: .named))
            if memory.updatedAt != memory.createdAt {
                Bullet()
                Text("updated \(memory.updatedAt, format: .relative(presentation: .named))")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// Read-only per-agent access list shown in the detail pane. Mirrors the
/// editor's checkbox section but as a status display: each known agent is
/// marked allowed or blocked based on the memory's exclusion denylist.
struct AgentAccessSummary: View {
    let memory: Memory

    private var excluded: Set<String> { Set(memory.excludedAgents) }

    private var headline: String {
        let blocked = KnownAgents.all.filter { excluded.contains($0.id) }
        if blocked.isEmpty { return "Agent access — all agents" }
        return "Agent access — \(KnownAgents.all.count - blocked.count) of \(KnownAgents.all.count) agents"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.subheadline.weight(.semibold))

            ForEach(KnownAgents.all, id: \.id) { agent in
                let allowed = !excluded.contains(agent.id)
                HStack(spacing: 8) {
                    Image(systemName: agent.symbol)
                        .foregroundStyle(allowed ? (SourcePalette.color(for: agent.id) ?? .gray) : Color.gray.opacity(0.5))
                        .frame(width: 18)
                    Text(agent.displayName)
                        .foregroundStyle(allowed ? .primary : .secondary)
                    Text(agent.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: allowed ? "checkmark.circle.fill" : "slash.circle")
                        .foregroundStyle(allowed ? Color.green : .secondary)
                    Text(allowed ? "Allowed" : "No access")
                        .font(.caption)
                        .foregroundStyle(allowed ? Color.green : .secondary)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TagRow: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct Bullet: View {
    var body: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}

// MARK: - Panel reusable (Phase 3)

struct Panel<Content: View>: View {
    let title: String
    var actionLabel: String? = nil
    var onAction: (() -> Void)? = nil
    @ViewBuilder let content: Content

    init(
        title: String,
        actionLabel: String? = nil,
        onAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.actionLabel = actionLabel
        self.onAction = onAction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let actionLabel, let onAction {
                    Button(actionLabel, action: onAction).buttonStyle(.link)
                }
            }
            content
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.weight(.bold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Memory editor sheet (Phase 8 — handles both new and edit)

struct MemoryEditorView: View {
    enum Mode {
        case new
        case edit(Memory)
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let vm: MemoryStoreViewModel
    /// Called with the saved memory's id — new IDs come from `create`, edits
    /// echo back the same id (lets the caller re-select after save).
    let onSaved: (Memory.ID) -> Void

    @State private var title: String
    @State private var type: MemoryType
    @State private var content: String
    @State private var tagsInput: String
    @State private var allowedAgentIDs: Set<String>
    @State private var saveError: String?

    /// Exclusions for agents the checkbox list can't render (an excluded
    /// `agent_id` not in the `KnownAgents` catalog). The editor only toggles
    /// catalog agents, so we carry these through untouched and re-merge them on
    /// save — otherwise editing a memory would silently re-grant access.
    private let preservedExclusions: [String]

    init(mode: Mode, vm: MemoryStoreViewModel, onSaved: @escaping (Memory.ID) -> Void) {
        self.mode = mode
        self.vm = vm
        self.onSaved = onSaved
        let catalogIDs = Set(KnownAgents.all.map(\.id))
        switch mode {
        case .new:
            _title = State(initialValue: "")
            _type = State(initialValue: .note)
            _content = State(initialValue: "")
            _tagsInput = State(initialValue: "")
            _allowedAgentIDs = State(initialValue: catalogIDs)
            preservedExclusions = []
        case .edit(let memory):
            _title = State(initialValue: memory.title ?? "")
            _type = State(initialValue: memory.type)
            _content = State(initialValue: memory.content)
            _tagsInput = State(initialValue: memory.tags.joined(separator: ", "))
            _allowedAgentIDs = State(initialValue: catalogIDs.subtracting(memory.excludedAgents))
            preservedExclusions = memory.excludedAgents.filter { !catalogIDs.contains($0) }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true } else { return false }
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit memory" : "New memory")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 14) {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Text("Type").foregroundStyle(.secondary)
                    Picker("", selection: $type) {
                        ForEach(MemoryType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
                .padding(.leading, 5)

                TextField("Tags (e.g. diet, food, vegan)", text: $tagsInput)
                    .textFieldStyle(.roundedBorder)

                TextField(
                    "What do you want to remember?",
                    text: $content,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(6...12)
                .frame(minHeight: 160, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Agent access — \(accessSummary)")
                        .font(.subheadline.weight(.semibold))
                    Text("Unchecked agents can't see this memory over MCP. You, the CLI, and this app always can.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(KnownAgents.all, id: \.id) { agent in
                        Toggle(isOn: accessBinding(for: agent.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: agent.symbol)
                                    .foregroundStyle(SourcePalette.color(for: agent.id) ?? .gray)
                                Text(agent.displayName)
                                Text(agent.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            }

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save Changes" : "Save") {
                    Task { await save() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // Fixed width, but height grows with content so expanding the
        // "Agent access" section enlarges the sheet instead of clipping the
        // buttons. The Spacer above keeps the buttons pinned to the bottom at
        // the minimum height; past it, the sheet resizes to fit.
        .frame(width: 560)
        .frame(minHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accessSummary: String {
        if allowedAgentIDs.count == KnownAgents.all.count { return "All agents" }
        return "\(allowedAgentIDs.count) of \(KnownAgents.all.count) agents"
    }

    private var excludedAgents: [String] {
        let catalogExcluded = KnownAgents.all.map(\.id).filter { !allowedAgentIDs.contains($0) }
        return catalogExcluded + preservedExclusions
    }

    private func accessBinding(for agentID: String) -> Binding<Bool> {
        Binding(
            get: { allowedAgentIDs.contains(agentID) },
            set: { isAllowed in
                if isAllowed {
                    allowedAgentIDs.insert(agentID)
                } else {
                    allowedAgentIDs.remove(agentID)
                }
            }
        )
    }

    private func save() async {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTags = tagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        do {
            switch mode {
            case .new:
                let newID = try await vm.create(
                    title: cleanTitle.isEmpty ? nil : cleanTitle,
                    type: type,
                    content: cleanedContent,
                    tags: cleanedTags,
                    excludedAgents: excludedAgents
                )
                onSaved(newID)
            case .edit(let memory):
                let updated = try await vm.update(
                    id: memory.id,
                    title: cleanTitle.isEmpty ? nil : cleanTitle,
                    type: type,
                    content: cleanedContent,
                    tags: cleanedTags,
                    excludedAgents: excludedAgents
                )
                onSaved(updated.id)
            }
            dismiss()
        } catch {
            saveError = String(describing: error)
        }
    }
}

// MARK: - Agents page (Phase 9)

struct AgentsView: View {
    let statusVM: VaultStatusViewModel?
    let onConfigure: (AgentSnapshot) -> Void

    private var snapshots: [AgentSnapshot] {
        let activity = statusVM?.recentActivity ?? []
        let now = Date()
        // "Connected" = saw any activity in the last 5 minutes. Better than
        // a binary "ever seen" check for a status that we want to feel live.
        let connectedWindow: TimeInterval = 300

        return KnownAgents.all.map { entry in
            let mine = activity.filter { $0.actorID == entry.id }
            let last = mine.first?.occurredAt
            let reads = mine.filter { ["memory_recent", "memory_search"].contains($0.operation) }.count
            let writes = mine.filter { ["memory_store", "memory_update"].contains($0.operation) }.count
            let connected = (last.map { now.timeIntervalSince($0) < connectedWindow }) ?? false
            return AgentSnapshot(
                id: entry.id,
                displayName: entry.displayName,
                symbol: entry.symbol,
                isConnected: connected,
                lastAccess: last,
                reads: reads,
                writes: writes
            )
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Agents",
                    subtitle: "Every connected AI tool gets explicit memory permissions."
                )

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(snapshots) { agent in
                        AgentCard(agent: agent, onConfigure: { onConfigure(agent) })
                    }
                }
            }
            .padding(24)
        }
    }
}

struct AgentCard: View {
    let agent: AgentSnapshot
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill((SourcePalette.color(for: agent.id) ?? .gray).opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: agent.symbol)
                        .foregroundStyle(SourcePalette.color(for: agent.id) ?? .gray)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName).font(.headline)
                    Text(agent.isConnected ? "Connected" : "Idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Pill(text: "Per-memory access", color: .blue)

            HStack(spacing: 18) {
                Stat(label: "reads", value: "\(agent.reads)")
                Stat(label: "writes", value: "\(agent.writes)")
                Spacer(minLength: 0)
                if let last = agent.lastAccess {
                    Text(last, format: .relative(presentation: .numeric))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Button("Configure", action: onConfigure)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private struct Stat: View {
        let label: String
        let value: String
        var body: some View {
            HStack(spacing: 4) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AgentConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agent: AgentSnapshot

    init(agent: AgentSnapshot) {
        self.agent = agent
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configure \(agent.displayName)")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: agent.symbol)
                        .foregroundStyle(SourcePalette.color(for: agent.id) ?? .gray)
                    Text(agent.id).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Pill(text: agent.isConnected ? "Connected" : "Idle",
                         color: agent.isConnected ? .green : .gray)
                }

                Divider()

                Text("Access is configured per memory. Open a memory's create or edit sheet and untick this agent to hide that memory from the MCP client.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 340)
    }
}

// MARK: - Access roster

struct AccessRulesView: View {
    private let agents = KnownAgents.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Access Roster",
                    subtitle: "Known MCP agents. Access is set per memory in the memory editor."
                )

                Panel(title: "Known Agents") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(agents, id: \.id) { agent in
                            HStack(spacing: 10) {
                                Image(systemName: agent.symbol)
                                    .foregroundStyle(SourcePalette.color(for: agent.id) ?? .gray)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.displayName)
                                        .font(.callout.weight(.medium))
                                    Text(agent.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Pill(text: "Default open", color: .green)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Status bar (Phase 12 preview)

struct StatusBar: View {
    let vm: VaultStatusViewModel

    var body: some View {
        HStack(spacing: 28) {
            StatusSegment(
                glyph: vm.vaultLocked ? "lock.fill" : "lock.open",
                glyphColor: vm.vaultLocked ? .red : .green,
                title: vm.vaultLocked ? "Locked" : "Unlocked",
                detail: vm.vaultLocked ? "Touch ID required" : "Touch ID on"
            )
            connectedSegment
            cloudSyncSegment
            companionSegment
            // Spacer here so Last Activity is pushed to the right edge —
            // matches the prototype's `.last-access { margin-left: auto }`.
            Spacer(minLength: 16)
            lastActivitySegment
        }
        .padding(.horizontal, 20)
    }

    private var connectedSegment: some View {
        StatusSegment(
            glyph: "circle.fill",
            glyphColor: vm.connectedAgents.isEmpty ? .gray : .green,
            title: "Connected Agents",
            detail: vm.connectedAgents.isEmpty
                ? "None"
                : vm.connectedAgents.joined(separator: ", ")
        )
    }

    private var cloudSyncSegment: some View {
        StatusSegment(
            glyph: "icloud.fill",
            glyphColor: vm.cloudSyncOn ? .blue : .gray,
            title: "Cloud Sync",
            detail: vm.cloudSyncOn ? "On" : "Off"
        )
    }

    private var companionSegment: some View {
        StatusSegment(
            glyph: vm.companionConnected ? "iphone" : "iphone.slash",
            glyphColor: vm.companionConnected ? .green : .gray,
            title: "Companion App",
            detail: vm.companionConnected ? "Connected" : "Not connected"
        )
    }

    private var lastActivitySegment: some View {
        StatusSegment(
            glyph: "clock",
            glyphColor: .secondary,
            title: "Last Activity",
            detail: vm.lastActivity.map { date in
                date.formatted(.relative(presentation: .numeric))
            } ?? "—"
        )
    }
}

struct StatusSegment: View {
    let glyph: String
    let glyphColor: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .foregroundStyle(glyphColor)
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

struct StatusBarFallback: View {
    var body: some View {
        HStack {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Vault status unavailable").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}
