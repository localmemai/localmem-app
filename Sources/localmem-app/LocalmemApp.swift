import SwiftUI
import AppKit
import LocalAuthentication
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
    case overview, memories, agents, access, audit

    var label: String {
        switch self {
        case .overview:   "Overview"
        case .memories:   "Memories"
        case .agents:     "Agents"
        case .access:     "Access Roster"
        case .audit:      "Audit Log"
        }
    }

    var symbol: String {
        switch self {
        case .overview:   "square.grid.2x2"
        case .memories:   "doc.text"
        case .agents:     "person.crop.square"
        case .access:     "lock.shield"
        case .audit:      "list.bullet.rectangle"
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

struct AgentConfigurationState {
    let agent: AgentSnapshot
    let isInstalled: Bool
    let isRegistered: Bool
    let registeredBinaryPath: String?
    let configPath: String?
    let instructionPath: String?
    let hasInstructionImport: Bool?

    var statusText: String {
        if !isInstalled { return "Not installed" }
        if isRegistered && hasInstructionImport != false { return "Configured" }
        if isRegistered || hasInstructionImport == true { return "Needs repair" }
        return "Not configured"
    }

    var statusColor: Color {
        switch statusText {
        case "Configured": return .green
        case "Needs repair": return .orange
        case "Not configured": return .gray
        default: return .secondary
        }
    }

    var instructionText: String {
        guard let hasInstructionImport else { return "Not supported" }
        return hasInstructionImport ? "Installed" : "Missing"
    }
}

enum AgentConfigurationInspector {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func state(for agent: AgentSnapshot) -> AgentConfigurationState {
        let config = configURL(for: agent.id)
        let instruction = instructionTarget(for: agent.id)
        let registered = config.map { isRegistered(agentID: agent.id, configURL: $0) } ?? false
        let instructionInstalled = instruction.map { hasImportLine(relativePath: $0.relativePath) }

        return AgentConfigurationState(
            agent: agent,
            isInstalled: isInstalled(agentID: agent.id, configURL: config, instructionTarget: instruction),
            isRegistered: registered,
            registeredBinaryPath: config.flatMap { registeredBinaryPath(agentID: agent.id, configURL: $0) },
            configPath: config?.path,
            instructionPath: instruction.map { home.appendingPathComponent($0.relativePath).path },
            hasInstructionImport: instructionInstalled
        )
    }

    static func repairAll(resetImports: Bool = false) async throws -> String {
        if resetImports {
            let installer = try InstructionsInstaller()
            _ = installer.removeAll()
        }
        return try await runLocalmemSetup()
    }

    static func repair(agentID: String) async throws -> String {
        _ = agentID
        return try await runLocalmemSetup()
    }

    static func removeConnection(agentID: String) async throws {
        if let target = instructionTarget(for: agentID) {
            let installer = try InstructionsInstaller()
            _ = try installer.removeImportLine(from: target)
        }
        if let config = configURL(for: agentID) {
            try removeMCPEntry(agentID: agentID, configURL: config)
        }
    }

    private static func configURL(for agentID: String) -> URL? {
        switch agentID {
        case "claude-code": return home.appendingPathComponent(".claude.json")
        case "claude-desktop": return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case "cursor": return home.appendingPathComponent(".cursor/mcp.json")
        case "codex": return home.appendingPathComponent(".codex/config.toml")
        case "antigravity-client": return home.appendingPathComponent(".gemini/config/mcp_config.json")
        default: return nil
        }
    }

    private static func instructionTarget(for agentID: String) -> AgentInstructionTarget? {
        switch agentID {
        case "claude-code": return .init(displayName: "Claude Code", relativePath: ".claude/CLAUDE.md")
        case "cursor": return .init(displayName: "Cursor", relativePath: ".cursor/AGENTS.md")
        case "codex": return .init(displayName: "Codex", relativePath: ".codex/AGENTS.md")
        case "antigravity-client": return .init(displayName: "Antigravity", relativePath: ".gemini/AGENTS.md")
        default: return nil
        }
    }

    private static func isInstalled(agentID: String, configURL: URL?, instructionTarget: AgentInstructionTarget?) -> Bool {
        switch agentID {
        case "claude-desktop":
            return FileManager.default.fileExists(atPath: "/Applications/Claude.app")
                || configURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        case "cursor":
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path)
        case "codex":
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
        case "antigravity-client":
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path)
        case "claude-code":
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
                || FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path)
        default:
            return configURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
                || instructionTarget.map { FileManager.default.fileExists(atPath: home.appendingPathComponent($0.relativePath).deletingLastPathComponent().path) } == true
        }
    }

    private static func hasImportLine(relativePath: String) -> Bool {
        let url = home.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("<!-- localmem -->")
    }

    private static func isRegistered(agentID: String, configURL: URL) -> Bool {
        if agentID == "codex" {
            guard let raw = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            return raw.contains("[mcp_servers.localmem]") || raw.contains("[mcp_servers.\"localmem\"]")
        }
        return readJSONMCPEntry(at: configURL) != nil
    }

    private static func registeredBinaryPath(agentID: String, configURL: URL) -> String? {
        if agentID == "codex" {
            guard let raw = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            var inLocalmem = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    inLocalmem = trimmed == "[mcp_servers.localmem]" || trimmed == "[mcp_servers.\"localmem\"]"
                    continue
                }
                if inLocalmem, trimmed.hasPrefix("command") {
                    return trimmed.split(separator: "=", maxSplits: 1).last?
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                }
            }
            return nil
        }
        return readJSONMCPEntry(at: configURL)?["command"] as? String
    }

    private static func readJSONMCPEntry(at url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers["localmem"] as? [String: Any]
        else { return nil }
        return entry
    }

    private static func removeMCPEntry(agentID: String, configURL: URL) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        if agentID == "codex" {
            let raw = try String(contentsOf: configURL, encoding: .utf8)
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            var output: [Substring] = []
            var skipping = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    skipping = trimmed == "[mcp_servers.localmem]"
                        || trimmed == "[mcp_servers.\"localmem\"]"
                        || trimmed.hasPrefix("[mcp_servers.localmem.")
                        || trimmed.hasPrefix("[mcp_servers.\"localmem\".")
                }
                if !skipping { output.append(line) }
            }
            var updated = output.joined(separator: "\n")
            if raw.hasSuffix("\n") { updated += "\n" }
            try updated.write(to: configURL, atomically: true, encoding: .utf8)
            return
        }

        let data = try Data(contentsOf: configURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers.removeValue(forKey: "localmem")
        root["mcpServers"] = servers
        let next = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try next.write(to: configURL, options: .atomic)
    }

    private static func runLocalmemSetup() async throws -> String {
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe

            if let executablePath = Bundle.main.executablePath {
                let sibling = URL(fileURLWithPath: executablePath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("localmem")
                if FileManager.default.isExecutableFile(atPath: sibling.path) {
                    process.executableURL = sibling
                    process.arguments = ["setup"]
                }
            }
            if process.executableURL == nil {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["localmem", "setup"]
            }

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "LocalmemAgentSetup",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr]
                )
            }
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
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
    private(set) var vaultLocked = false       // Driven by the Touch ID lock (Phase 13).
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

    func setLocked(_ locked: Bool) { vaultLocked = locked }
}

// MARK: - Root shell (Phase 1)

/// Drives every modal presentation in the shell. One enum, one `.sheet(item:)`
/// modifier — easier to extend than a `showingX` `Bool` per case. Phase 9 will
/// add `.agentConfig(AgentSnapshot)` etc. without touching the call site.
enum SheetKind: Identifiable {
    case newMemory
    case editMemory(Memory)
    case agentDetails(AgentSnapshot)

    var id: String {
        switch self {
        case .newMemory:                 return "new"
        case .editMemory(let memory):    return "edit-\(memory.id)"
        case .agentDetails(let agent):   return "agent-\(agent.id)"
        }
    }
}

struct ContentView: View {
    @State private var section: AppSection = .overview
    @State private var selectedComingSoon: ComingSoonFeature?
    @State private var query = ""
    @State private var sheet: SheetKind?
    @State private var memorySelection: Memory.ID?
    @State private var auditMemoryFilter: Memory.ID?

    // try? swallows DB-open errors so the app launches into a degraded state
    // rather than crashing. Each VM is optional all the way down.
    @State private var memoryVM: MemoryStoreViewModel? = try? MemoryStoreViewModel()
    @State private var statusVM: VaultStatusViewModel? = try? VaultStatusViewModel()
    @State private var sidebarCollapsed = false
    @FocusState private var searchFocused: Bool
    @AppStorage("seenWizard") private var seenWizard = false
    @State private var showSetupWizard = false
    @State private var wizardMode: SetupWizardMode = .firstRun

    var body: some View {
        // Two-level layout so the status bar spans the full window width:
        //   VStack {
        //     HStack { sidebar | (toolbar + content) }   // window body
        //     StatusBar                                   // full-width footer
        //   }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarRail(
                        section: $section,
                        selectedComingSoon: $selectedComingSoon
                    )
                        .frame(width: 244)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }

                VStack(spacing: 0) {
                    TopToolbar(
                        query: $query,
                        sidebarCollapsed: sidebarCollapsed,
                        onToggleSidebar: {
                            withAnimation(.snappy) { sidebarCollapsed.toggle() }
                        },
                        onNewMemory: { sheet = .newMemory },
                        onLock: { statusVM?.setLocked(true) },
                        searchFocused: $searchFocused
                    )
                    .frame(height: 52)

                    Divider()

                    ContentArea(
                        section: section,
                        memoryVM: memoryVM,
                        statusVM: statusVM,
                        selectedComingSoon: selectedComingSoon,
                        memorySelection: $memorySelection,
                        onEditMemory: { memory in sheet = .editMemory(memory) },
                        onConfigureAgent: { agent in sheet = .agentDetails(agent) },
                        onReconfigureAgents: {
                            wizardMode = .reconfigure
                            showSetupWizard = true
                        },
                        onShowAuditTrail: { memory in
                            auditMemoryFilter = memory.id
                            selectedComingSoon = nil
                            withAnimation(.snappy) { section = .audit }
                        },
                        onOpenAuditMemory: { memoryID in
                            query = ""
                            memorySelection = memoryID
                            selectedComingSoon = nil
                            withAnimation(.snappy) { section = .memories }
                        },
                        auditMemoryFilter: $auditMemoryFilter,
                        jumpToMemories: {
                            selectedComingSoon = nil
                            withAnimation(.snappy) { section = .memories }
                        },
                        onTestWizard: {
                            wizardMode = .firstRun
                            showSetupWizard = true
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if statusVM?.vaultLocked == true {
                            LockScreen { statusVM?.setLocked(false) }
                        }
                    }
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
        .background { sectionShortcuts }
        .onAppear {
            if !seenWizard {
                wizardMode = .firstRun
                showSetupWizard = true
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
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView(isPresented: $showSetupWizard, mode: wizardMode) {
                seenWizard = true
                Task { await statusVM?.refresh() }
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .newMemory:
                if let memoryVM {
                    MemoryEditorView(mode: .new, vm: memoryVM) { newID in
                        memorySelection = newID
                        selectedComingSoon = nil
                        section = .memories
                    }
                }
            case .editMemory(let memory):
                if let memoryVM {
                    MemoryEditorView(mode: .edit(memory), vm: memoryVM) { updatedID in
                        memorySelection = updatedID
                        selectedComingSoon = nil
                    }
                }
            case .agentDetails(let agent):
                AgentDetailsSheet(agent: agent)
            }
        }
    }

    /// Hidden buttons that register ⌘1–⌘7 (jump to section) and ⌘F (focus
    /// search). Kept off-screen so they only contribute key equivalents.
    private var sectionShortcuts: some View {
        ZStack {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, sec in
                Button("") {
                    selectedComingSoon = nil
                    withAnimation(.snappy) { section = sec }
                }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
    }
}

// MARK: - Sidebar rail (Phase 1, 2)

struct SidebarRail: View {
    @Binding var section: AppSection
    @Binding var selectedComingSoon: ComingSoonFeature?
    @State private var comingSoonExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandHeader()

            VStack(alignment: .leading, spacing: 4) {
                ForEach(AppSection.allCases, id: \.self) { item in
                    NavItem(item: item, isActive: selectedComingSoon == nil && item == section) {
                        selectedComingSoon = nil
                        withAnimation(.snappy) { section = item }
                    }
                }
            }

            ComingSoonSidebarGroup(
                expanded: $comingSoonExpanded,
                selected: $selectedComingSoon
            )

            Spacer()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 15)
        .background(.regularMaterial)
    }
}

struct ComingSoonSidebarGroup: View {
    @Binding var expanded: Bool
    @Binding var selected: ComingSoonFeature?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text("Coming Soon")
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ComingSoonFeature.allCases) { feature in
                        Button {
                            selected = feature
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: feature.symbol)
                                    .frame(width: 16)
                                    .foregroundStyle(.secondary)
                                Text(feature.sidebarTitle)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.caption)
                            .padding(.leading, 18)
                            .padding(.trailing, 10)
                            .frame(height: 30)
                            .background(
                                selected == feature ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .foregroundStyle(selected == feature ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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
    let onLock: () -> Void
    @FocusState.Binding var searchFocused: Bool

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
                .focused($searchFocused)

            Spacer()

            Button(action: onLock) {
                Image(systemName: "lock")
            }
            .help("Lock the vault")
            .keyboardShortcut("l", modifiers: .command)
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
    let selectedComingSoon: ComingSoonFeature?
    @Binding var memorySelection: Memory.ID?
    let onEditMemory: (Memory) -> Void
    let onConfigureAgent: (AgentSnapshot) -> Void
    let onReconfigureAgents: () -> Void
    let onShowAuditTrail: (Memory) -> Void
    let onOpenAuditMemory: (Memory.ID) -> Void
    @Binding var auditMemoryFilter: Memory.ID?
    let jumpToMemories: () -> Void
    let onTestWizard: () -> Void

    var body: some View {
        Group {
            if let selectedComingSoon {
                ComingSoonDetailPage(feature: selectedComingSoon)
            } else {
                switch section {
                case .overview:
                    OverviewView(
                        memoryVM: memoryVM,
                        statusVM: statusVM,
                        jumpToMemories: jumpToMemories,
                        onTestWizard: onTestWizard
                    )
                case .memories:
                    MemoriesView(
                        vm: memoryVM,
                        selection: $memorySelection,
                        onEdit: onEditMemory,
                        onShowAuditTrail: onShowAuditTrail
                    )
                case .agents:
                    AgentsView(
                        statusVM: statusVM,
                        onConfigure: onConfigureAgent,
                        onReconfigureAgents: onReconfigureAgents
                    )
                case .access:
                    AccessRulesView(statusVM: statusVM)
                case .audit:
                    AuditLogView(memoryFilter: $auditMemoryFilter, onOpenMemory: onOpenAuditMemory)
                }
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
    let onTestWizard: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Overview",
                    subtitle: "Recent memories and agent activity."
                ) {
                    Button {
                        onTestWizard()
                    } label: {
                        Label("Test Setup Wizard", systemImage: "wand.and.stars")
                    }
                }

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

enum ComingSoonFeature: String, CaseIterable, Identifiable {
    case syncCompanion
    case importExport
    case connectors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .syncCompanion: "iCloud sync + companion app"
        case .importExport: "Import / Export memories"
        case .connectors: "Connectors"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .syncCompanion: "iCloud + Companion"
        case .importExport: "Import / Export"
        case .connectors: "Connectors"
        }
    }

    var subtitle: String {
        switch self {
        case .syncCompanion: "Private sync across your devices."
        case .importExport: "Portable memory backup and restore."
        case .connectors: "Apple Notes, Obsidian, Markdown files, and more."
        }
    }

    var symbol: String {
        switch self {
        case .syncCompanion: "icloud.and.arrow.up"
        case .importExport: "tray.and.arrow.up"
        case .connectors: "point.3.connected.trianglepath.dotted"
        }
    }

    var details: String {
        switch self {
        case .syncCompanion:
            return "Sync your Localmem vault through iCloud and capture memories from a lightweight companion app while keeping the human in control of approval and access."
        case .importExport:
            return "Bring memories in from files and export a full-fidelity archive for backup, migration, or inspection outside the app."
        case .connectors:
            return "Connect selected sources like Apple Notes, Obsidian vaults, Markdown folders, and other local files with explicit review before anything becomes memory."
        }
    }
}

struct ComingSoonDetailPage: View {
    let feature: ComingSoonFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: feature.title,
                subtitle: "Coming soon"
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.subtitle)
                            .font(.headline)
                        Pill(text: "Coming soon", color: .secondary)
                    }
                    Spacer()
                }

                Divider()

                Text(feature.details)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                FeaturePreviewBullets(feature: feature)
            }
            .padding(18)
            .frame(maxWidth: 620, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FeaturePreviewBullets: View {
    let feature: ComingSoonFeature

    private var bullets: [String] {
        switch feature {
        case .syncCompanion:
            return ["iCloud-backed device sync", "Companion capture flow", "Approval-first privacy controls"]
        case .importExport:
            return ["Full-fidelity archive export", "Portable import path", "Backup and migration support"]
        case .connectors:
            return ["Apple Notes ingestion", "Obsidian and Markdown folder support", "Explicit review before memory creation"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bullets, id: \.self) { bullet in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color.accentColor)
                    Text(bullet)
                        .foregroundStyle(.primary)
                }
                .font(.callout)
            }
        }
    }
}

struct ComingSoonDetail: View {
    @Environment(\.dismiss) private var dismiss
    let feature: ComingSoonFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: feature.symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .font(.headline)
                    Text("Coming soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(feature.details)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
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
        VStack(alignment: .center, spacing: 4) {
            Text(value).font(.system(size: 28, weight: .bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
    let onShowAuditTrail: (Memory) -> Void

    private var selected: Memory? {
        vm?.memories.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            MemoryListPane(memories: vm?.memories ?? [], selection: $selection)
                .frame(width: 320)
                .background(.background.secondary)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.separator).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.separator).frame(width: 1)
                }

            Divider()

            MemoryDetailPane(
                memory: selected,
                vm: vm,
                onDeleted: { selection = nil },
                onEdit: onEdit,
                onShowAuditTrail: onShowAuditTrail
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
    let onShowAuditTrail: (Memory) -> Void

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

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Content")
                                .font(.headline)
                            Text(memory.content)
                                .font(.body)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

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

                AgentAccessSummary(memory: memory)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 14)

                Divider()

                // Actions pinned to the bottom of the pane.
                HStack(spacing: 10) {
                    Button("Edit") { onEdit(memory) }
                    Button("Delete", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .tint(.red)
                    Button("Audit trail") { onShowAuditTrail(memory) }
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
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
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
    let actions: AnyView?

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.actions = nil
    }

    init<Actions: View>(title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = AnyView(actions())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            actions
        }
    }
}

// MARK: - Memory editor sheet (Phase 8 — handles both new and edit)

struct MemoryEditorView: View {
    enum Mode {
        case new
        case edit(Memory)
    }

    private static let titleLimit = 80
    private static let contentLimit = 2_000

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
    @State private var accessExpanded = false
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
        validationMessage == nil
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

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EditorSection(title: nil) {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Title", text: $title)
                                    .font(.title3)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.large)
                                    .frame(height: 44)
                                    .onChange(of: title) { _, value in
                                        title = limited(value, to: Self.titleLimit)
                                    }
                                CharacterCount(count: title.count, limit: Self.titleLimit)
                            }

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

                            TextField("Tags (comma separated)", text: $tagsInput)
                                .textFieldStyle(.roundedBorder)

                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topLeading) {
                                    TextEditor(text: $content)
                                        .font(.body)
                                        .scrollContentBackground(.hidden)
                                        .padding(6)
                                        .frame(height: 190)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
                                        .onChange(of: content) { _, value in
                                            content = limited(value, to: Self.contentLimit)
                                        }
                                    if content.isEmpty {
                                        Text("What do you want to remember?")
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 14)
                                            .allowsHitTesting(false)
                                    }
                                }
                                CharacterCount(count: content.count, limit: Self.contentLimit)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            withAnimation(.snappy) { accessExpanded.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Access Control — \(accessSummary)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: accessExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if accessExpanded {
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
                    }
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
            } else if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .frame(maxHeight: 720)
    }

    private var accessSummary: String {
        if allowedAgentIDs.count == KnownAgents.all.count { return "All agents" }
        return "\(allowedAgentIDs.count) of \(KnownAgents.all.count) agents"
    }

    private var excludedAgents: [String] {
        let catalogExcluded = KnownAgents.all.map(\.id).filter { !allowedAgentIDs.contains($0) }
        return catalogExcluded + preservedExclusions
    }

    private var cleanedTags: [String] {
        tagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required."
        }
        if cleanedTags.isEmpty {
            return "Add at least one tag."
        }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Memory details are required."
        }
        return nil
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

    private func limited(_ value: String, to limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit)) : value
    }

    private func save() async {
        if let validationMessage {
            saveError = validationMessage
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch mode {
            case .new:
                let newID = try await vm.create(
                    title: cleanTitle,
                    type: type,
                    content: cleanedContent,
                    tags: cleanedTags,
                    excludedAgents: excludedAgents
                )
                onSaved(newID)
            case .edit(let memory):
                let updated = try await vm.update(
                    id: memory.id,
                    title: cleanTitle,
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

struct EditorSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CharacterCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count)/\(limit)")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(count >= limit ? Color.orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Agents page (Phase 9)

struct AgentsView: View {
    let statusVM: VaultStatusViewModel?
    let onConfigure: (AgentSnapshot) -> Void
    let onReconfigureAgents: () -> Void
    @State private var showingResetConfirmation = false
    @State private var resetInProgress = false
    @State private var resetMessage: String?

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
                ) {
                    Button("Reconfigure...", action: onReconfigureAgents)
                        .buttonStyle(.borderedProminent)
                }

                if let resetMessage {
                    Text(resetMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(snapshots) { agent in
                        AgentCard(agent: agent, onConfigure: { onConfigure(agent) })
                    }
                }

                Divider().padding(.top, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full reset").font(.callout.weight(.semibold))
                        Text("Remove Localmem's managed instruction imports, then run setup again for every detected agent.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(resetInProgress ? "Resetting..." : "Reset All Agent Configurations...", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .disabled(resetInProgress)
                }
            }
            .padding(24)
        }
        .alert("Reset all agent configurations?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset and Reconfigure", role: .destructive) {
                resetInProgress = true
                resetMessage = nil
                Task {
                    do {
                        _ = try await AgentConfigurationInspector.repairAll(resetImports: true)
                        resetMessage = "Agent configurations were reset and reconfigured."
                    } catch {
                        resetMessage = "Reset failed: \(error.localizedDescription)"
                    }
                    resetInProgress = false
                }
            }
        } message: {
            Text("This removes only Localmem's managed import lines and rewrites Localmem setup. Your other agent instructions stay in place.")
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

            let config = AgentConfigurationInspector.state(for: agent)
            Pill(text: config.statusText, color: config.statusColor)

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
                Button("Details", action: onConfigure)
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

struct AgentDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agent: AgentSnapshot
    @State private var state: AgentConfigurationState
    @State private var runningAction: String?
    @State private var message: String?
    @State private var showingRemoveConfirmation = false

    init(agent: AgentSnapshot) {
        self.agent = agent
        _state = State(initialValue: AgentConfigurationInspector.state(for: agent))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(agent.displayName) details")
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

                VStack(alignment: .leading, spacing: 10) {
                    DetailRow(label: "Configuration", value: state.statusText)
                    DetailRow(label: "MCP registration", value: state.isRegistered ? "Configured" : "Missing")
                    DetailRow(label: "Binary", value: state.registeredBinaryPath ?? "Not registered")
                    DetailRow(label: "Config file", value: state.configPath ?? "Not supported")
                    DetailRow(label: "Instructions", value: state.instructionText)
                    DetailRow(label: "Instruction file", value: state.instructionPath ?? "Not supported")
                    DetailRow(label: "Last access", value: agent.lastAccess.map { $0.formatted(.relative(presentation: .numeric)) } ?? "No activity yet")
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Button("Remove Connection", role: .destructive) {
                    showingRemoveConfirmation = true
                }
                .disabled(runningAction != nil)
                Button(runningAction == "repair" ? "Repairing..." : "Repair") {
                    run("repair") {
                        _ = try await AgentConfigurationInspector.repair(agentID: agent.id)
                    }
                }
                .disabled(runningAction != nil)
                Button(runningAction == "reconfigure" ? "Reconfiguring..." : "Reconfigure") {
                    run("reconfigure") {
                        _ = try await AgentConfigurationInspector.repair(agentID: agent.id)
                    }
                }
                .disabled(runningAction != nil)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 480)
        .alert("Remove \(agent.displayName) connection?", isPresented: $showingRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Connection", role: .destructive) {
                run("remove") {
                    try await AgentConfigurationInspector.removeConnection(agentID: agent.id)
                }
            }
        } message: {
            Text("This removes Localmem's MCP entry and managed instruction import for this agent only.")
        }
    }

    private func run(_ action: String, operation: @escaping () async throws -> Void) {
        runningAction = action
        message = nil
        Task {
            do {
                try await operation()
                state = AgentConfigurationInspector.state(for: agent)
                message = "\(agent.displayName) \(action == "remove" ? "connection removed" : "configuration updated")."
            } catch {
                message = "\(action.capitalized) failed: \(error.localizedDescription)"
            }
            runningAction = nil
        }
    }

    private struct DetailRow: View {
        let label: String
        let value: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Access roster

/// Agent-centric access management: for each known agent, what it's blocked
/// from, with bulk grant/revoke and per-memory unblock. The inverse of the
/// per-memory checkboxes in the editor.
@Observable @MainActor
final class AccessRosterViewModel {
    struct AgentRow: Identifiable {
        let agent: KnownAgent
        var blocked: [Memory]
        var id: String { agent.id }
    }

    private(set) var rows: [AgentRow] = []
    private(set) var loadError: String?
    private let store: MemoryStore

    init() throws { self.store = try MemoryStore() }

    func refresh() async {
        do {
            var result: [AgentRow] = []
            for agent in KnownAgents.all {
                let blocked = try await store.memoriesExcluding(agent: agent.id)
                result.append(AgentRow(agent: agent, blocked: blocked))
            }
            rows = result
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    func unblock(_ memory: Memory, from agent: KnownAgent) async {
        await run { _ = try await self.store.setExclusion(memoryID: memory.id, agent: agent.id, excluded: false, actorKind: .cli, actorID: "user") }
    }

    func allowAll(_ agent: KnownAgent) async {
        await run { _ = try await self.store.grantAllAccess(toAgent: agent.id, actorKind: .cli, actorID: "user") }
    }

    func hideAll(_ agent: KnownAgent) async {
        await run { _ = try await self.store.revokeAllAccess(fromAgent: agent.id, actorKind: .cli, actorID: "user") }
    }

    private func run(_ op: @escaping () async throws -> Void) async {
        do { try await op(); await refresh() }
        catch { loadError = String(describing: error) }
    }
}

struct AccessRulesView: View {
    let statusVM: VaultStatusViewModel?
    @State private var vm: AccessRosterViewModel? = try? AccessRosterViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "Access Roster",
                    subtitle: "Per-agent memory access. Block or unblock an agent across memories here; per-memory control lives in each memory's editor."
                )

                if let vm {
                    if let loadError = vm.loadError {
                        Text(loadError).font(.footnote).foregroundStyle(.red)
                    }
                    ForEach(vm.rows) { row in
                        AgentAccessCard(row: row, connected: isConnected(row.agent.id), vm: vm)
                    }
                } else {
                    Text("Couldn't open the memory store.").foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .task { await vm?.refresh() }
    }

    private func isConnected(_ id: String) -> Bool {
        guard let last = (statusVM?.recentActivity ?? []).first(where: { $0.actorID == id })?.occurredAt
        else { return false }
        return Date().timeIntervalSince(last) < 300
    }
}

struct AgentAccessCard: View {
    let row: AccessRosterViewModel.AgentRow
    let connected: Bool
    let vm: AccessRosterViewModel

    @State private var expanded = false
    @State private var confirmingHideAll = false

    private var agent: KnownAgent { row.agent }
    private var blockedCount: Int { row.blocked.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: agent.symbol)
                    .foregroundStyle(SourcePalette.color(for: agent.id) ?? .gray)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName).font(.callout.weight(.semibold))
                    Text(agent.id).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if connected {
                    Pill(text: "Connected", color: .green)
                }
                Pill(
                    text: blockedCount == 0 ? "Full access" : "Blocked from \(blockedCount)",
                    color: blockedCount == 0 ? .green : .orange
                )
            }

            HStack(spacing: 10) {
                Button("Allow all") { Task { await vm.allowAll(agent) } }
                    .disabled(blockedCount == 0)
                Button("Hide all") { confirmingHideAll = true }
                    .tint(.orange)
                if blockedCount > 0 {
                    Button(expanded ? "Hide list" : "Show \(blockedCount) blocked") {
                        expanded.toggle()
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if expanded && blockedCount > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(row.blocked) { memory in
                        HStack(spacing: 8) {
                            SourceDot(source: memory.source, size: 7)
                            Text(memory.title ?? String(memory.content.prefix(48)))
                                .lineLimit(1)
                            Spacer()
                            Button("Allow") { Task { await vm.unblock(memory, from: agent) } }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        .confirmationDialog(
            "Hide every memory from \(agent.displayName)?",
            isPresented: $confirmingHideAll,
            titleVisibility: .visible
        ) {
            Button("Hide all", role: .destructive) { Task { await vm.hideAll(agent) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(agent.displayName) won't see any current memory over MCP until you allow it again. New memories stay visible unless you exclude them.")
        }
    }
}

// MARK: - Audit Log (Phase 11)

@Observable @MainActor
final class AuditLogViewModel {
    enum Category: String, CaseIterable, Identifiable {
        case all = "All", reads = "Reads", writes = "Writes", access = "Access"
        var id: String { rawValue }
    }

    struct MemoryChoice: Identifiable {
        let id: Memory.ID
        let title: String
    }

    private(set) var all: [Activity] = []
    private(set) var memories: [Memory] = []
    private(set) var loadError: String?
    var actorFilter: String?            // nil = every actor

    private let store: ActivityStore
    private let memoryStore: MemoryStore
    init() throws {
        self.store = try ActivityStore()
        self.memoryStore = try MemoryStore()
    }

    func refresh() async {
        do {
            async let activityRows = store.recent(limit: 500)
            async let memoryRows = memoryStore.recent(limit: 500)
            all = try await activityRows
            memories = try await memoryRows
            loadError = nil
        }
        catch { loadError = String(describing: error) }
    }

    var actors: [String] { Array(Set(all.compactMap(\.actorID))).sorted() }

    var memoryChoices: [MemoryChoice] {
        let indexed = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        let ids = Set(all.compactMap(\.memoryID))
        return ids.sorted { lhs, rhs in
            memoryTitle(for: lhs) < memoryTitle(for: rhs)
        }.map { id in
            if let memory = indexed[id] {
                return MemoryChoice(id: id, title: memory.title ?? String(memory.content.prefix(40)))
            }
            let prefix = id.uuidString.prefix(8)
            return MemoryChoice(id: id, title: "Deleted memory \(prefix)")
        }
    }

    func memoryTitle(for id: Memory.ID) -> String {
        guard let memory = memories.first(where: { $0.id == id }) else {
            return "Deleted memory \(id.uuidString.prefix(8))"
        }
        return memory.title ?? String(memory.content.prefix(40))
    }

    func memoryExists(_ id: Memory.ID) -> Bool {
        memories.contains { $0.id == id }
    }

    func rows(memoryFilter: Memory.ID?) -> [Activity] {
        all.filter { a in
            (actorFilter == nil || a.actorID == actorFilter)
                && (memoryFilter == nil || a.memoryID == memoryFilter)
        }
    }

    nonisolated static func category(of op: String) -> Category {
        switch op {
        case "memory_search", "memory_recent": return .reads
        default: return op.hasPrefix("access_") ? .access : .writes
        }
    }
}

struct AuditLogView: View {
    @Binding var memoryFilter: Memory.ID?
    let onOpenMemory: (Memory.ID) -> Void
    @State private var vm: AuditLogViewModel? = try? AuditLogViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "Audit Log",
                subtitle: "Every read, write, and access change, newest first. Filter by agent or memory."
            )

            if let vm {
                HStack(spacing: 12) {
                    Picker("Agent", selection: Binding(
                        get: { vm.actorFilter },
                        set: { vm.actorFilter = $0 }
                    )) {
                        Text("All agents").tag(String?.none)
                        ForEach(vm.actors, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .fixedSize()

                    Picker("Memory", selection: $memoryFilter) {
                        Text("All memories").tag(Memory.ID?.none)
                        if let memoryFilter, !vm.memoryChoices.contains(where: { $0.id == memoryFilter }) {
                            Text(vm.memoryTitle(for: memoryFilter)).tag(Memory.ID?.some(memoryFilter))
                        }
                        ForEach(vm.memoryChoices) { memory in
                            Text(memory.title).tag(Memory.ID?.some(memory.id))
                        }
                    }
                    .fixedSize()

                    Spacer()
                    Text("\(vm.rows(memoryFilter: memoryFilter).count) events").font(.caption).foregroundStyle(.secondary)
                    Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }

                if let loadError = vm.loadError {
                    Text(loadError).font(.footnote).foregroundStyle(.red)
                }

                List(vm.rows(memoryFilter: memoryFilter)) { event in
                    AuditRow(
                        event: event,
                        memoryTitle: event.memoryID.map { vm.memoryTitle(for: $0) },
                        memoryExists: event.memoryID.map { vm.memoryExists($0) } ?? false,
                        onOpenMemory: onOpenMemory
                    )
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
                .overlay {
                    if vm.rows(memoryFilter: memoryFilter).isEmpty {
                        ContentUnavailableView("No activity", systemImage: "list.bullet.rectangle")
                    }
                }
            } else {
                Text("Couldn't open the activity store.").foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .task { await vm?.refresh() }
    }
}

struct AuditRow: View {
    let event: Activity
    let memoryTitle: String?
    let memoryExists: Bool
    let onOpenMemory: (Memory.ID) -> Void

    private var category: AuditLogViewModel.Category { AuditLogViewModel.category(of: event.operation) }

    private var categoryColor: Color {
        switch category {
        case .reads:  return .blue
        case .writes: return .green
        case .access: return .orange
        case .all:    return .gray
        }
    }

    private var categorySymbol: String {
        switch category {
        case .reads:  return "eye"
        case .writes: return "square.and.pencil"
        case .access: return event.operation == "access_blocked" || event.operation == "access_filtered" ? "hand.raised.fill" : "lock.shield"
        case .all:    return "circle"
        }
    }

    private var operationLabel: String {
        switch event.operation {
        case "access_blocked": return "Blocked"
        case "access_filtered": return "Filtered"
        default: return event.operation
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(category.rawValue, systemImage: categorySymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(categoryColor)
                .help(category.rawValue)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SourceDot(source: event.actorID, size: 7)
                    Text(event.actorID ?? "—").fontWeight(.semibold)
                    actionView
                    if let q = event.query, !q.isEmpty {
                        Text("“\(q)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(event.occurredAt, format: .relative(presentation: .named))
                    if let memoryID = event.memoryID, let memoryTitle {
                        Text("·")
                        if memoryExists {
                            Button(memoryTitle) { onOpenMemory(memoryID) }
                                .buttonStyle(.link)
                                .font(.caption)
                        } else {
                            Text(memoryTitle)
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if event.operation == "access_filtered", let n = event.resultCount {
                Pill(text: "\(n) blocked", color: .orange)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionView: some View {
        if let memoryID = event.memoryID, memoryExists {
            Button { onOpenMemory(memoryID) } label: {
                Text(operationLabel)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(categoryColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(categoryColor)
            }
            .buttonStyle(.plain)
            .help("Open memory")
        } else {
            Text(operationLabel)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(categoryColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(category == .access ? categoryColor : .secondary)
        }
    }
}

// MARK: - Touch ID vault lock (Phase 13)

/// Adapted from the guide's per-memory `PrivacyShield`: the `isPrivate` flag was
/// removed with the category prototype, so we gate the whole vault instead.
enum BiometryGate {
    /// True when the OS can evaluate owner auth (biometrics or device passcode).
    /// Returns false in an unsigned build with no biometrics — callers degrade.
    static var available: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

struct LockScreen: View {
    let onUnlock: () -> Void
    @State private var authenticating = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44))
            Text("Vault locked").font(.title2.weight(.semibold))
            Text(BiometryGate.available
                 ? "Unlock with Touch ID to view your memories."
                 : "Biometrics aren't available in this build — unlock to continue.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if failed {
                Text("Authentication failed.").font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await unlock() }
            } label: {
                Label(BiometryGate.available ? "Unlock with Touch ID" : "Unlock", systemImage: "touchid")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(authenticating)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func unlock() async {
        authenticating = true
        defer { authenticating = false }
        // Degrade gracefully: if the OS can't evaluate auth (unsigned build,
        // no biometrics), unlocking proceeds rather than trapping the user.
        if !BiometryGate.available {
            onUnlock(); return
        }
        if await BiometryGate.authenticate(reason: "Unlock your Localmem vault") {
            failed = false; onUnlock()
        } else {
            failed = true
        }
    }
}

// MARK: - Status bar (Phase 12 preview)

struct StatusBar: View {
    let vm: VaultStatusViewModel

    var body: some View {
        HStack(spacing: 0) {
            StatusSegment(
                glyph: vm.vaultLocked ? "lock.fill" : "lock.open",
                glyphColor: vm.vaultLocked ? .red : .green,
                title: vm.vaultLocked ? "Locked" : "Unlocked",
                detail: vm.vaultLocked ? "Touch ID required" : "Touch ID on"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            connectedSegment
                .frame(maxWidth: .infinity, alignment: .center)
            cloudSyncSegment
                .frame(maxWidth: .infinity, alignment: .center)
            companionSegment
                .frame(maxWidth: .infinity, alignment: .center)
            lastActivitySegment
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
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
