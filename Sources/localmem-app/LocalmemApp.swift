import SwiftUI
import AppKit
import LocalAuthentication
import UniformTypeIdentifiers
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
        // A bare executable has no bundle icon, so the Dock shows a generic
        // tool icon. Render the brand mark and set it explicitly.
        //
        // The Dock and the Cmd-Tab switcher both read `applicationIconImage`,
        // and the switcher draws its selection glow at a fixed inset — so an
        // icon large enough to look right in the Dock ends up hiding that glow.
        // Resolve it by giving each surface its own size: the switcher (and the
        // default) gets the smaller 0.85 inset so the glow shows around it,
        // while the Dock is overridden via `dockTile.contentView` with a fuller
        // 0.90 version.
        if let switcherIcon = LocalmemMark.dockIcon(inset: 0.85) {
            NSApplication.shared.applicationIconImage = switcherIcon
        }
        if let dockIcon = LocalmemMark.dockIcon(inset: 0.90) {
            let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            iconView.image = dockIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            NSApplication.shared.dockTile.contentView = iconView
            NSApplication.shared.dockTile.display()
        }
        // Screenshot/testing hook: pin the window appearance regardless of the
        // system setting. `LOCALMEM_APPEARANCE=light|dark`.
        switch ProcessInfo.processInfo.environment["LOCALMEM_APPEARANCE"] {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup("Localmem") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)

        // Standard macOS Settings window (⌘,) — currently just the theme
        // picker. The LOCALMEM_APPEARANCE env hook above still wins when set
        // (it pins NSApplication.appearance, which overrides the per-window
        // color scheme) so screenshot tooling stays deterministic.
        Settings {
            SettingsView()
        }
    }
}

// MARK: - Appearance

/// User-selectable theme. `system` follows the OS; the raw value is persisted
/// via @AppStorage("appearance").
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    /// nil = follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.rawValue) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Sections (Phase 2)

enum AppSection: String, CaseIterable, Hashable {
    case overview, memories, agents, audit, connectors

    var label: String {
        switch self {
        case .overview:   "Overview"
        case .memories:   "Memories"
        case .agents:     "Agents"
        case .audit:      "Audit Log"
        case .connectors: "Connectors"
        }
    }

    var symbol: String {
        switch self {
        case .overview:   "square.grid.2x2"
        case .memories:   "doc.text"
        case .agents:     "person.crop.square"
        case .audit:      "list.bullet.rectangle"
        case .connectors: "point.3.connected.trianglepath.dotted"
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

/// The agent that wrote (or acted on) a memory, shown as that agent's brand
/// mark via `AgentIcon` — so a Cursor-authored memory shows the Cursor logo, a
/// Claude one the Claude mark, and the local user a person glyph. Lets you see
/// *who* added each memory at a glance, in the list and the audit log.
struct SourceIcon: View {
    let source: String?
    var size: CGFloat = 16

    var body: some View {
        AgentIcon(agentID: source ?? "", symbol: Self.fallbackSymbol(for: source), size: size)
            .foregroundStyle(Self.tint(for: source))
    }

    /// SF Symbol used when there's no brand asset (local user or unknown source).
    static func fallbackSymbol(for source: String?) -> String {
        switch source {
        case "user":  return "person.crop.circle.fill"
        case nil, "": return "questionmark.circle"
        default:      return "sparkle"
        }
    }

    /// Tint for the SF Symbol fallback (brand PNGs render as-is and ignore it).
    private static func tint(for source: String?) -> Color {
        source == "user" ? .accentColor : .secondary
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

    /// How many known agents are currently fully configured — registered in
    /// their MCP config, with the instruction import in place where the agent
    /// supports one. Same definition as `AgentConfigurationState.statusText
    /// == "Configured"`, so the overview stat card and the per-agent config
    /// sheet can never disagree.
    static func configuredAgentCount() -> Int {
        KnownAgents.all.filter { agent in
            guard let config = configURL(for: agent.id),
                  isRegistered(agentID: agent.id, configURL: config) else { return false }
            guard let instruction = instructionTarget(for: agent.id) else { return true }
            return hasImportLine(relativePath: instruction.relativePath)
        }.count
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

    /// Whether this agent has an instruction file Localmem can inject its import
    /// line into. Claude Desktop, for example, is MCP-only (no CLAUDE.md-style
    /// file), so the setup flow must not expect — or flag a failure for — an
    /// import line it can never add.
    static func supportsInstructions(_ agentID: String) -> Bool {
        instructionTarget(for: agentID) != nil
    }

    private static func isInstalled(agentID: String, configURL: URL?, instructionTarget: AgentInstructionTarget?) -> Bool {
        switch agentID {
        case "claude-desktop":
            return FileManager.default.fileExists(atPath: "/Applications/Claude.app")
                || configURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        case "cursor":
            // The bare `~/.cursor` dir is created by too many things to be a
            // reliable signal. Require the actual app or a real MCP config file.
            return FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
                || FileManager.default.fileExists(atPath: home.appendingPathComponent("Applications/Cursor.app").path)
                || FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/mcp.json").path)
        case "codex":
            return FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path)
        case "antigravity-client":
            return FileManager.default.fileExists(atPath: "/Applications/Antigravity.app")
                || FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/config/mcp_config.json").path)
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
            // Diagnostic: the wizard has reported "failed" while agents were in
            // fact registered and connecting. Capture what the setup subprocess
            // actually did so a reproduction shows whether the failure is real or
            // a post-run re-check mismatch.
            Log.info(.setup, "localmem setup subprocess finished", [
                "executable": process.executableURL?.path ?? "nil",
                "exit_code": String(process.terminationStatus),
                "stdout": String(stdout.suffix(2000)),
                "stderr": String(stderr.suffix(2000)),
            ])
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
    private(set) var folders: [Folder] = []
    private(set) var agents: [Agent] = []
    private(set) var folderCounts: [UUID: Int] = [:]
    private(set) var loadError: String?
    private(set) var loadedMemories: [Memory.ID: Memory] = [:]
    private let store: MemoryStore

    init() throws { self.store = try MemoryStore() }

    /// Children of each expanded folder, loaded on demand. Kept separate from
    /// `memories` (the search/recent window) so a folder outside that window
    /// still lists its contents.
    private(set) var folderChildren: [UUID: [Memory]] = [:]

    /// The query the list currently reflects. Mutations re-run *this* rather
    /// than resetting to "", which would repopulate the list with unrelated
    /// recent memories while the search field and the tree still say a filter
    /// is active.
    private(set) var activeQuery = ""

    func loadFoldersAndAgents() async {
        do {
            folders = try await store.listFolders()
            agents = try await store.listAgents()
            folderCounts = (try? await store.getFolderCounts()) ?? [:]
        } catch {
            Log.error(.store, "Failed to load folders/agents", ["error": String(describing: error)])
        }
    }

    func loadChildren(of folderID: UUID) async {
        do {
            folderChildren[folderID] = try await store.memories(inFolder: folderID)
        } catch {
            Log.error(.store, "Failed to load folder contents", [
                "folder": folderID.uuidString,
                "error": String(describing: error),
            ])
        }
    }

    /// Re-read the children of every folder already loaded. Call *after* any
    /// write that can move a memory between folders — clearing the cache
    /// without refilling it leaves expanded folders rendering as empty.
    func refreshFolderChildren() async {
        for id in Array(folderChildren.keys) {
            await loadChildren(of: id)
        }
    }

    func loadFullMemoryIfNeeded(_ id: Memory.ID) async {
        guard loadedMemories[id] == nil else { return }
        do {
            if let full = try await store.get(id: id) {
                loadedMemories[id] = full
            }
        } catch {
            Log.error(.store, "Failed to load full memory for \(id)", ["error": String(describing: error)])
        }
    }

    /// Single entry point for both initial load and live search. Empty query
    /// falls back to `recent` so the lists always have something to show.
    func search(_ query: String, limit: Int = 50) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        activeQuery = query
        do {
            let result = trimmed.isEmpty
                ? try await store.recent(limit: limit)
                : try await store.search(query: trimmed, limit: limit)
            memories = result.memories
            loadError = nil
            await loadFoldersAndAgents()
            await refreshFolderChildren()
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
        folderID: UUID? = nil,
        sessionID: String? = nil
    ) async throws -> Memory.ID {
        let memory = try await store.add(
            content: content,
            type: type,
            title: title?.isEmpty == false ? title : nil,
            tags: tags,
            folderID: folderID,
            sessionID: sessionID,
            actorKind: .cli,
            actorID: "user"
        )
        await search(activeQuery)
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
        folderID: UUID? = nil
    ) async throws -> Memory {
        let updated = try await store.update(
            id: id,
            content: content,
            type: type,
            title: title?.isEmpty == false ? title : nil,
            tags: tags,
            folderID: folderID,
            actorKind: .cli,
            actorID: "user"
        )
        await search(activeQuery)
        return updated
    }

    func delete(_ id: Memory.ID) async throws {
        _ = try await store.delete(id: id, actorKind: .cli, actorID: "user")
        await refreshFolderChildren()
        await search(activeQuery)
    }

    /// Serializes the entire vault into a portable archive blob for Export.
    func exportArchive() async throws -> Data {
        let all = try await store.all()
        return try MemoryArchive.encode(all)
    }

    func createFolder(name: String, isSensitive: Bool) async throws {
        _ = try await store.createFolder(name: name, kind: .manual, projectRoot: nil, isSensitive: isSensitive)
        await loadFoldersAndAgents()
    }

    func updateFolder(id: UUID, name: String, isSensitive: Bool) async throws {
        _ = try await store.updateFolder(id: id, name: name, isSensitive: isSensitive)
        await refreshFolderChildren()
        await loadFoldersAndAgents()
        await search(activeQuery)
    }

    func deleteFolder(id: UUID) async throws {
        try await store.deleteFolder(id: id)
        await refreshFolderChildren()
        await loadFoldersAndAgents()
        await search(activeQuery)
    }

    func moveMemories(ids: [UUID], toFolder folderID: UUID) async throws {
        _ = try await store.moveMemories(ids: ids, toFolder: folderID)
        await refreshFolderChildren()
        await loadFoldersAndAgents()
        await search(activeQuery)
    }

    func mergeFolders(ids: [UUID], intoName: String) async throws {
        _ = try await store.mergeFolders(ids: ids, intoName: intoName)
        await refreshFolderChildren()
        await loadFoldersAndAgents()
        await search(activeQuery)
    }

    func setAgentStatus(id: String, status: Agent.Status) async throws {
        try await store.setAgentStatus(id: id, status: status)
        await loadFoldersAndAgents()
        await search(activeQuery)
    }

    /// Parses an exported archive and merges it into the store (skipping ids
    /// that already exist), then refreshes the visible list.
    @discardableResult
    func importArchive(_ data: Data) async throws -> ImportSummary {
        let memories = try MemoryArchive.decode(data)
        let summary = try await store.importMemories(memories, actorKind: .cli, actorID: "user")
        await search(activeQuery)
        return summary
    }
}

/// Drives the bottom status bar's five segments and the Overview's stats strip
/// / activity panel. Polls once a second while visible.
@Observable @MainActor
final class VaultStatusViewModel {
    private(set) var vaultLocked = false       // Driven by the Touch ID lock (Phase 13).
    private(set) var connectedAgents: [String] = []
    private(set) var configuredAgents = 0
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
        // Agents are MCP actors only — CLI rows carry the human "user" and the
        // connector's "import" actor, which must not count as connected agents
        // in the stat card or the status-bar agent list.
        connectedAgents = Array(Set(rows.filter { $0.actorKind == .mcp }.compactMap(\.actorID))).sorted()
        configuredAgents = AgentConfigurationInspector.configuredAgentCount()
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
    case newMemory(initialFolderID: UUID?)
    case editMemory(Memory)


    var id: String {
        switch self {
        case .newMemory:                 return "new"
        case .editMemory(let memory):    return "edit-\(memory.id)"

        }
    }
}

/// Shown once, after the folders migration has filed an existing vault. It
/// reports what happened using the user's own folder names rather than
/// describing a feature, and states plainly that access did not change —
/// after an upgrade that visibly rearranged the vault, that is the reasonable
/// fear to pre-empt. Suppressed entirely when migration created no folders,
/// since then it has nothing to say.
struct MigrationSummaryView: View {
    let folders: [Folder]
    let counts: [UUID: Int]
    let inboxCount: Int
    let onShowFolders: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your memories are now in folders")
                    .font(.headline)
                Text("Localmem 2.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CREATED FROM YOUR IMPORTS")
                        .font(.system(size: 9, weight: .medium))
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)

                    ForEach(folders) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                            Text(folder.name)
                                .font(.system(size: 13))
                            Spacer()
                            Text("\(counts[folder.id] ?? 0)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("\(inboxCount) memories written by agents are in Inbox. New ones will be filed by project automatically.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("**Every agent can still read everything.** To keep a folder from some agents, open its settings and choose who can read it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 18)

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button("Done", action: onDismiss)
                Button("Show me the folders", action: onShowFolders)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
    }
}

/// Mirrors what macOS does when you double-click a titlebar, honouring the
/// user's "Double-click a window's title bar to" setting in System Settings.
/// An unset preference means zoom, which is the system default.
@MainActor
func performTitlebarDoubleClickAction() {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
        window.miniaturize(nil)
    case "None":
        break
    default:
        window.zoom(nil)
    }
}

struct ContentView: View {
    static let inboxFolderID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Folders the migration created from imported documents — the only ones
    /// the summary has anything to say about.
    private func migratedSourceFolders(_ vm: MemoryStoreViewModel) -> [Folder] {
        vm.folders
            .filter { $0.kind == .source }
            .sorted { (vm.folderCounts[$0.id] ?? 0) > (vm.folderCounts[$1.id] ?? 0) }
    }

    // Screenshot/testing hook: `LOCALMEM_INITIAL_SECTION` (an AppSection raw
    // value) selects the section the window opens on. No effect when unset.
    @State private var section: AppSection = {
        if let raw = ProcessInfo.processInfo.environment["LOCALMEM_INITIAL_SECTION"],
           let seeded = AppSection(rawValue: raw) {
            return seeded
        }
        return .overview
    }()
    @State private var selectedComingSoon: ComingSoonFeature?
    @State private var query = ""
    @State private var sheet: SheetKind?
    @State private var memorySelection: Memory.ID?
    @State private var selectedFolderID: UUID? = nil
    @State private var auditMemoryFilter: Memory.ID?
    @AppStorage("seenMigrationWarning") private var seenMigrationWarning = false

    // try? swallows DB-open errors so the app launches into a degraded state
    // rather than crashing. Each VM is optional all the way down.
    @State private var memoryVM: MemoryStoreViewModel? = try? MemoryStoreViewModel()
    @State private var statusVM: VaultStatusViewModel? = try? VaultStatusViewModel()
    // Owned here, not by the Connectors section view: the import queue and
    // per-file "processing" state live in this VM, and a section-scoped @State
    // would discard them on every navigation — leaving an in-flight import
    // with no spinner and a stale file list when the user comes back.
    @State private var connectorsVM: ConnectorsViewModel? = try? ConnectorsViewModel()
    @State private var sidebarCollapsed = false
    @FocusState private var searchFocused: Bool
    @AppStorage("seenWizard") private var seenWizard = false
    @AppStorage("seenFolderMigrationSummary") private var seenFolderMigrationSummary = false
    @State private var showMigrationSummary = false
    @State private var showSetupWizard = false
    @State private var wizardMode: SetupWizardMode = .firstRun
    @State private var portabilityAlert: PortabilityAlert?

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
                        onNewMemory: { sheet = .newMemory(initialFolderID: selectedFolderID) },
                        onLock: { statusVM?.setLocked(true) },
                        onExport: exportMemories,
                        onImport: importMemories,
                        searchFocused: $searchFocused
                    )
                    .frame(height: 52)
                    .contentShape(Rectangle())
                    // The window hides its titlebar and the content ignores the
                    // top safe area, so this bar sits where the titlebar would
                    // be and swallows the system's double-click. Restore the
                    // standard behaviour by hand. A tap gesture on the
                    // container only fires when no control consumed the click,
                    // so the buttons and search field still work.
                    .onTapGesture(count: 2) { performTitlebarDoubleClickAction() }

                    Divider()

                    ContentArea(
                        section: section,
                        memoryVM: memoryVM,
                        statusVM: statusVM,
                        connectorsVM: connectorsVM,
                        selectedComingSoon: selectedComingSoon,
                        memorySelection: $memorySelection,
                        selectedFolderID: $selectedFolderID,
                        isSearching: !query.trimmingCharacters(in: .whitespaces).isEmpty,
                        onEditMemory: { memory in sheet = .editMemory(memory) },

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
            // Screenshot/testing hooks: `LOCALMEM_SHOW_WIZARD=1` forces the
            // setup wizard open; `LOCALMEM_INITIAL_SECTION` (screenshot mode)
            // suppresses the first-run wizard so a specific section is visible.
            let env = ProcessInfo.processInfo.environment
            if env["LOCALMEM_SHOW_WIZARD"] == "1" {
                wizardMode = .firstRun
                showSetupWizard = true
            } else if env["LOCALMEM_INITIAL_SECTION"] != nil {
                // stay on the requested section; skip the auto wizard
            } else if !seenWizard {
                wizardMode = .firstRun
                showSetupWizard = true
            }
        }
        .task(id: query) { await memoryVM?.search(query) }
        // An import finishing while a search is active would file the new
        // memories behind a filter that hides them. Clear it and refresh.
        .onChange(of: connectorsVM?.completedBatches ?? 0) { _, _ in
            query = ""
            Task {
                await memoryVM?.search("")
                await statusVM?.refresh()
            }
        }
        .task {
            // The summary needs folder counts, so it waits for the first load
            // rather than firing in `.onAppear`. Nothing to report when the
            // migration filed everything into Inbox, so stay silent there.
            guard !seenFolderMigrationSummary, let memoryVM else { return }
            await memoryVM.loadFoldersAndAgents()
            if !migratedSourceFolders(memoryVM).isEmpty {
                showMigrationSummary = true
            } else {
                seenFolderMigrationSummary = true
            }
        }
        .task {
            // Status + memory-list polling — auto-cancels on view disappear.
            // Memories are also written by the separate localmem-mcp process when
            // an agent stores one, so the list must pick up out-of-process changes
            // without an app restart. Re-run the current search whenever the total
            // memory count changes (a new agent write), which the status refresh
            // already computes — cheap, and avoids clobbering the list every tick.
            guard let statusVM else { return }
            var lastCount = -1
            while !Task.isCancelled {
                await statusVM.refresh()
                if statusVM.memoryCount != lastCount {
                    if lastCount != -1 { await memoryVM?.search(query) }
                    lastCount = statusVM.memoryCount
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Returning to the app after an agent session is the common case; refresh
        // immediately on focus rather than waiting for the next poll tick. Also
        // catches in-place edits an agent made (which don't change the count).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await memoryVM?.search(query)
                await statusVM?.refresh()
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView(isPresented: $showSetupWizard, mode: wizardMode) {
                seenWizard = true
                Task { await statusVM?.refresh() }
            }
        }
        .sheet(isPresented: $showMigrationSummary) {
            if let memoryVM {
                MigrationSummaryView(
                    folders: migratedSourceFolders(memoryVM),
                    counts: memoryVM.folderCounts,
                    inboxCount: memoryVM.folderCounts[Self.inboxFolderID] ?? 0,
                    onShowFolders: {
                        seenFolderMigrationSummary = true
                        showMigrationSummary = false
                        selectedComingSoon = nil
                        section = .memories
                    },
                    onDismiss: {
                        seenFolderMigrationSummary = true
                        showMigrationSummary = false
                    }
                )
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .newMemory(let initialFolderID):
                if let memoryVM {
                    MemoryEditorView(mode: .new, initialFolderID: initialFolderID, vm: memoryVM) { newID in
                        memorySelection = newID
                        selectedComingSoon = nil
                        section = .memories
                    }
                }
            case .editMemory(let memory):
                if let memoryVM {
                    MemoryEditorView(mode: .edit(memory), initialFolderID: memory.folderID, vm: memoryVM) { updatedID in
                        memorySelection = updatedID
                        selectedComingSoon = nil
                    }
                }
            }
        }
        .alert(item: $portabilityAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Import / Export

    /// Prompts for a destination and writes every memory as a portable JSON
    /// archive. The save panel runs modally before the async encode so the user
    /// picks a location up front; a write failure surfaces as an alert.
    private func exportMemories() {
        guard let memoryVM else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Self.defaultExportFilename()
        panel.title = "Export Memories"
        panel.message = "Save a portable copy of every memory as JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await memoryVM.exportArchive()
                try data.write(to: url, options: .atomic)
            } catch {
                portabilityAlert = PortabilityAlert(
                    title: "Export Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Prompts for a Localmem JSON export and merges it into the vault, skipping
    /// memories whose ids already exist. Reports the result (or the parse error)
    /// as an alert.
    private func importMemories() {
        guard let memoryVM else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Memories"
        panel.message = "Choose a Localmem JSON export to import."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                let summary = try await memoryVM.importArchive(data)
                await statusVM?.refresh()
                portabilityAlert = PortabilityAlert(
                    title: "Import Complete",
                    message: Self.importSummaryMessage(summary)
                )
            } catch {
                portabilityAlert = PortabilityAlert(
                    title: "Import Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private static func defaultExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "localmem-export-\(formatter.string(from: Date())).json"
    }

    private static func importSummaryMessage(_ summary: ImportSummary) -> String {
        let added = "\(summary.imported) " + (summary.imported == 1 ? "memory" : "memories")
        guard summary.skipped > 0 else { return "Imported \(added)." }
        return "Imported \(added) (\(summary.skipped) duplicate\(summary.skipped == 1 ? "" : "s") skipped)."
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
                // Unshipped features sit inline as ordinary rows with a "Soon"
                // badge — a disclosure group is too much chrome for so few.
                ForEach(ComingSoonFeature.allCases) { feature in
                    ComingSoonNavItem(feature: feature, isActive: selectedComingSoon == feature) {
                        selectedComingSoon = feature
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

/// A sidebar row for a not-yet-shipped feature: styled like `NavItem`, plus a
/// "Soon" pill. Opens the feature's coming-soon detail page.
struct ComingSoonNavItem: View {
    let feature: ComingSoonFeature
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: feature.symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(feature.sidebarTitle)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Soon")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
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

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            LocalmemMark(size: 38)
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

/// The Localmem brand mark: a dark rounded tile with a bracket-`m` glyph in the
/// house gradient. Matches `logo.svg` on the marketing site (a 160-unit
/// artboard scaled to `size`).
struct LocalmemMark: View {
    var size: CGFloat

    /// House gradient: #4d8dff → #35d0e0 (55%) → #a07dff, top-left to bottom-right.
    static let gradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.302, green: 0.553, blue: 1.0), location: 0),
            .init(color: Color(red: 0.208, green: 0.816, blue: 0.878), location: 0.55),
            .init(color: Color(red: 0.627, green: 0.490, blue: 1.0), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        let radius = size * (37.0 / 160.0)
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(red: 0.047, green: 0.055, blue: 0.083)) // #0c0e15
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
            BracketsShape()
                .stroke(
                    Self.gradient,
                    style: StrokeStyle(lineWidth: size * (9.0 / 160.0), lineCap: .round, lineJoin: .round)
                )
            Text("m")
                .font(.system(size: size * (52.0 / 160.0), weight: .heavy))
                .foregroundStyle(Self.gradient)
                .offset(y: -size * (2.0 / 160.0))
        }
        .frame(width: size, height: size)
    }

    /// The mark rendered to an `NSImage` for use as the Dock/app icon. Lets
    /// dev runs of the bare SwiftPM executable show the brand instead of the
    /// generic tool icon; packaged `.app` builds use `AppIcon.icns`.
    ///
    /// The mark rendered to an `NSImage`, inset within a transparent canvas.
    /// macOS Dock/app icons aren't full-bleed; the `inset` controls how much of
    /// the tile the mark fills. Callers use a fuller value for the Dock tile and
    /// a smaller one for `applicationIconImage` so the Cmd-Tab selection glow
    /// (drawn at a fixed inset) shows around the icon rather than behind it.
    @MainActor static func dockIcon(inset: CGFloat = 0.85) -> NSImage? {
        let canvas: CGFloat = 512
        let content = LocalmemMark(size: canvas * inset)
            .frame(width: canvas, height: canvas)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// Two square brackets `[ ]` drawn on the 160-unit brand artboard.
private struct BracketsShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 160 * rect.width,
                    y: rect.minY + y / 160 * rect.height)
        }
        var path = Path()
        // Left bracket:  M62 50 H48 V110 H62
        path.move(to: p(62, 50)); path.addLine(to: p(48, 50))
        path.addLine(to: p(48, 110)); path.addLine(to: p(62, 110))
        // Right bracket: M98 50 H112 V110 H98
        path.move(to: p(98, 50)); path.addLine(to: p(112, 50))
        path.addLine(to: p(112, 110)); path.addLine(to: p(98, 110))
        return path
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

/// A one-off success/failure message for the Import/Export flow, surfaced via
/// `.alert(item:)`.
struct PortabilityAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct TopToolbar: View {
    @Binding var query: String
    let sidebarCollapsed: Bool
    let onToggleSidebar: () -> Void
    let onNewMemory: () -> Void
    let onLock: () -> Void
    let onExport: () -> Void
    let onImport: () -> Void
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

            Menu {
                Button("Export Memories…", action: onExport)
                Button("Import Memories…", action: onImport)
            } label: {
                Label("Import / Export", systemImage: "tray.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Import or export memories")

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
    let connectorsVM: ConnectorsViewModel?
    let selectedComingSoon: ComingSoonFeature?
    @Binding var memorySelection: Memory.ID?
    @Binding var selectedFolderID: UUID?
    let isSearching: Bool
    let onEditMemory: (Memory) -> Void

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
                        selectedFolderID: $selectedFolderID,
                        isSearching: isSearching,
                        onEdit: onEditMemory,
                        onShowAuditTrail: onShowAuditTrail
                    )
                case .agents:
                    if let memoryVM {
                        AgentsView(
                            vm: memoryVM,
                            onReconfigureAgents: onReconfigureAgents
                        )
                    } else {
                        Text("Memory store unavailable")
                    }
                case .audit:
                    AuditLogView(memoryFilter: $auditMemoryFilter, onOpenMemory: onOpenAuditMemory)
                case .connectors:
                    ConnectorsCatalogView(vm: connectorsVM)
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
                    // Dev-only affordance to replay the first-run wizard; not
                    // shipped in release builds.
                    #if DEBUG
                    Button {
                        onTestWizard()
                    } label: {
                        Label("Test Setup Wizard", systemImage: "wand.and.stars")
                    }
                    #endif
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
    // Connectors graduated from this "Coming Soon" group to its own section
    // (AppSection.connectors); the catalog page hosts the still-coming sources.
    case syncCompanion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .syncCompanion: "iCloud sync + companion app"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .syncCompanion: "iCloud + Companion"
        }
    }

    var subtitle: String {
        switch self {
        case .syncCompanion: "Private sync across your devices."
        }
    }

    var symbol: String {
        switch self {
        case .syncCompanion: "icloud.and.arrow.up"
        }
    }

    var details: String {
        switch self {
        case .syncCompanion:
            return "Sync your Localmem vault through iCloud and capture memories from a lightweight companion app while keeping the human in control of approval and access."
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
            StatCard(value: "\(statusVM?.configuredAgents ?? 0)",
                     label: "Agents configured")
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
                SourceIcon(source: memory.source, size: 16)
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
    @Binding var selectedFolderID: UUID?
    let isSearching: Bool
    let onEdit: (Memory) -> Void
    let onShowAuditTrail: (Memory) -> Void

    @AppStorage("lastSelectedFolderID") private var lastSelectedFolderID = ""

    private var selected: Memory? {
        guard let selection else { return nil }
        return vm?.loadedMemories[selection] ?? vm?.memories.first { $0.id == selection }
    }

    /// `nil` folder means "All Memories" — the unfiltered vault.
    private var visibleMemories: [Memory] {
        let all = vm?.memories ?? []
        guard let selectedFolderID else { return all }
        return all.filter { $0.folderID == selectedFolderID }
    }

    private var selectedFolder: Folder? {
        guard let selectedFolderID else { return nil }
        return vm?.folders.first { $0.id == selectedFolderID }
    }

    var body: some View {
        HStack(spacing: 0) {
            FolderTreePane(
                folders: vm?.folders ?? [],
                memories: vm?.memories ?? [],
                counts: vm?.folderCounts ?? [:],
                isSearching: isSearching,
                selection: $selection,
                selectedFolderID: $selectedFolderID,
                vm: vm,
                onDelete: { memory in
                    Task {
                        try? await vm?.delete(memory.id)
                        if selection == memory.id { selection = nil }
                    }
                }
            )
                .frame(width: 300)
                .background(.background.secondary)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.separator).frame(width: 1)
                }

            Divider()

            // The right pane is contextual: picking a folder shows its
            // settings, picking a memory shows the memory. Selecting a folder
            // clears the memory selection, so the two never compete.
            if selection == nil, let folder = selectedFolder, let vm {
                FolderSettingsPane(
                    folder: folder,
                    count: vm.folderCounts[folder.id] ?? 0,
                    agents: vm.agents,
                    vm: vm,
                    onDeleted: { selectedFolderID = nil }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
        .task {
            await vm?.loadFoldersAndAgents()
            // Restore the folder from the last session, but only if it still
            // exists — a deleted or merged folder must not strand the pane on
            // an empty selection.
            if selectedFolderID == nil,
               let restored = UUID(uuidString: lastSelectedFolderID),
               vm?.folders.contains(where: { $0.id == restored }) == true {
                selectedFolderID = restored
            }
        }
        .onChange(of: selectedFolderID) { _, newValue in
            lastSelectedFolderID = newValue?.uuidString ?? ""
        }
        .task(id: selection) {
            if let selection {
                await vm?.loadFullMemoryIfNeeded(selection)
            }
        }
        // Screenshot/testing hook: `LOCALMEM_SELECT_MEMORY` (a title substring,
        // or "first") pre-selects a memory once the list has loaded.
        .task {
            guard selection == nil,
                  let want = ProcessInfo.processInfo.environment["LOCALMEM_SELECT_MEMORY"]
            else { return }
            for _ in 0..<40 {
                if let vm, !vm.memories.isEmpty {
                    let match = want == "first"
                        ? vm.memories.first
                        : vm.memories.first { ($0.title ?? "").localizedCaseInsensitiveContains(want) }
                    selection = (match ?? vm.memories.first)?.id
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// The Memories navigator: a Finder/VS Code style tree — folders at the top
/// level, their memories nested beneath. Sensitivity is marked on the folder
/// row itself, so a restricted folder reads at a glance without opening
/// settings. Clicking a folder shows its settings; clicking a memory shows
/// the memory.
/// A drag that has landed and is awaiting confirmation. Dragging is an
/// organising gesture, but in this design moving something between folders is
/// also how its visibility changes — so the dialog states the access outcome,
/// not just the counts.
struct PendingDrop: Identifiable {
    enum Payload {
        case memory(Memory)
        case folder(Folder, memoryCount: Int)
    }
    let payload: Payload
    let destination: Folder
    var id: String {
        switch payload {
        case .memory(let m): return "m-\(m.id)-\(destination.id)"
        case .folder(let f, _): return "f-\(f.id)-\(destination.id)"
        }
    }

    var title: String {
        switch payload {
        case .memory(let m):
            return "Move “\(m.title ?? m.headline ?? "memory")” to “\(destination.name)”?"
        case .folder(let f, _):
            return destination.kind == .default
                ? "Move “\(f.name)” into Inbox?"
                : "Merge “\(f.name)” into “\(destination.name)”?"
        }
    }

    /// Only ever mentions access when access actually changes — a move that
    /// stays on one side of the boundary should read as pure organisation.
    var message: String {
        switch payload {
        case .memory(let m):
            _ = m
            if sourceSensitive == destination.isSensitive { return "" }
            return destination.isSensitive
                ? "It takes “\(destination.name)”'s setting and becomes hidden from agents set to non-sensitive only."
                : "It takes “\(destination.name)”'s setting and becomes readable by every agent."
        case .folder(let f, let count):
            var lines: [String] = []
            lines.append("\(count) memories move. “\(f.name)” is removed; no memory is deleted.")
            // The destination's rule wins, in both directions — the same rule
            // that applies to a single memory. The destination's own setting is
            // never rewritten, so this only ever describes what happens to the
            // memories being moved.
            if f.isSensitive != destination.isSensitive {
                lines.append(destination.isSensitive
                    ? "They take “\(destination.name)”'s setting and become hidden from agents set to non-sensitive only."
                    : "They take “\(destination.name)”'s setting and become readable by every agent.")
            }
            return lines.joined(separator: "\n\n")
        }
    }

    /// Sensitivity of where the dragged item came from.
    var sourceSensitive: Bool = false
}

struct FolderTreePane: View {
    let folders: [Folder]
    let memories: [Memory]
    let counts: [UUID: Int]
    let isSearching: Bool
    @Binding var selection: Memory.ID?
    @Binding var selectedFolderID: UUID?
    let vm: MemoryStoreViewModel?
    let onDelete: (Memory) -> Void

    @State private var expanded: Set<UUID> = []
    @State private var hoveredRow: UUID?
    @State private var dropTarget: UUID?
    @State private var pendingDrop: PendingDrop?
    @State private var hoverExpandTask: Task<Void, Never>?
    @State private var folderPendingDelete: Folder?
    @State private var memoryPendingDelete: Memory?
    // Persisted as a comma-joined list; the companion flag distinguishes
    // "never opened the app" from "deliberately collapsed everything".
    @AppStorage("expandedFolderIDs") private var expandedFolderIDs = ""
    @AppStorage("hasFolderExpansionState") private var hasFolderExpansionState = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var newFolderSensitive = false

    private static let inboxID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Inbox first, then the rest alphabetically — the default folder is where
    /// unfiled memories land, so it earns the fixed position.
    private var ordered: [Folder] {
        let inbox = folders.filter { $0.id == Self.inboxID }
        let rest = folders.filter { $0.id != Self.inboxID }.sorted { $0.name < $1.name }
        return inbox + rest
    }

    /// While a search is active the tree mirrors the results, so counts and
    /// children both reflect matches. Otherwise it lists the folder's real
    /// contents, loaded on expand.
    private func children(of folder: Folder) -> [Memory] {
        if isSearching { return memories.filter { $0.folderID == folder.id } }
        return vm?.folderChildren[folder.id] ?? []
    }

    private func displayCount(_ folder: Folder) -> Int {
        isSearching
            ? memories.filter { $0.folderID == folder.id }.count
            : (counts[folder.id] ?? 0)
    }

    private var visibleFolders: [Folder] { ordered }

    private func hasMatches(_ folder: Folder) -> Bool {
        !isSearching || displayCount(folder) > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memories").font(.headline)
                Spacer()
                Text("\(memories.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    newFolderName = ""
                    newFolderSensitive = false
                    showNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New folder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleFolders) { folder in
                        folderRow(folder)

                        if (isSearching && hasMatches(folder)) || (!isSearching && expanded.contains(folder.id)) {
                            let kids = children(of: folder)
                            if kids.isEmpty {
                                Text("Empty")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 38)
                                    .padding(.vertical, 3)
                            } else {
                                ForEach(kids) { memory in
                                    memoryRow(memory)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
        }
        .onAppear {
            if hasFolderExpansionState {
                expanded = Set(
                    expandedFolderIDs
                        .split(separator: ",")
                        .compactMap { UUID(uuidString: String($0)) }
                )
            } else if let selection,
                      let owner = memories.first(where: { $0.id == selection })?.folderID {
                expanded.insert(owner)
            } else {
                // Cold start with no history: open Inbox so the tree never
                // appears fully collapsed and empty.
                expanded.insert(Self.inboxID)
            }
            if let selectedFolderID { expanded.insert(selectedFolderID) }
            for id in expanded {
                Task { await vm?.loadChildren(of: id) }
            }
        }
        .onChange(of: expanded) { _, newValue in
            hasFolderExpansionState = true
            expandedFolderIDs = newValue.map(\.uuidString).joined(separator: ",")
        }
        .onChange(of: selectedFolderID) { _, newValue in
            // The folder selection is restored asynchronously after folders
            // load, which can land after this view appeared — reveal it then.
            guard let newValue else { return }
            expanded.insert(newValue)
            Task { await vm?.loadChildren(of: newValue) }
        }
        .confirmationDialog(
            folderPendingDelete.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { folderPendingDelete != nil },
                                 set: { if !$0 { folderPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let folder = folderPendingDelete {
                    if selectedFolderID == folder.id { selectedFolderID = nil }
                    Task { try? await vm?.deleteFolder(id: folder.id) }
                }
                folderPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDelete = nil }
        } message: {
            Text("Its memories move to Inbox. No memory is deleted.")
        }
        .confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(get: { memoryPendingDelete != nil },
                                 set: { if !$0 { memoryPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let memory = memoryPendingDelete { onDelete(memory) }
                memoryPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { memoryPendingDelete = nil }
        } message: {
            Text(memoryPendingDelete?.title ?? memoryPendingDelete?.headline ?? "")
        }
        .confirmationDialog(
            pendingDrop?.title ?? "",
            isPresented: Binding(get: { pendingDrop != nil },
                                 set: { if !$0 { pendingDrop = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingDrop.map { drop in
                if case .folder = drop.payload {
                    return drop.destination.kind == .default ? "Move" : "Merge"
                }
                return "Move"
            } ?? "Move") {
                if let drop = pendingDrop { commitDrop(drop) }
                pendingDrop = nil
            }
            Button("Cancel", role: .cancel) { pendingDrop = nil }
        } message: {
            Text(pendingDrop?.message ?? "")
        }
        .sheet(isPresented: $showNewFolder) {
            NewFolderSheet(
                name: $newFolderName,
                sensitive: $newFolderSensitive,
                onCancel: { showNewFolder = false },
                onCreate: {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        try? await vm?.createFolder(name: name, isSensitive: newFolderSensitive)
                        showNewFolder = false
                    }
                }
            )
        }
    }


    // MARK: - Drag and drop

    /// Dragging is the single gesture for both jobs: a memory onto a folder
    /// reclassifies it, a folder onto a folder merges them. Both land here.
    private func handleDrop(_ providers: [NSItemProvider], onto folder: Folder) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String else { return }
            Task { @MainActor in
                stageDrop(raw, onto: folder)
            }
        }
        return true
    }

    @MainActor
    private func stageDrop(_ raw: String, onto folder: Folder) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return }

        switch parts[0] {
        case "memory":
            guard let memory = memories.first(where: { $0.id == id })
                    ?? vm?.folderChildren.values.flatMap({ $0 }).first(where: { $0.id == id }),
                  memory.folderID != folder.id else { return }
            let from = vm?.folders.first { $0.id == memory.folderID }
            pendingDrop = PendingDrop(payload: .memory(memory), destination: folder,
                                      sourceSensitive: from?.isSensitive ?? false)
        case "folder":
            // Dropping a folder on itself is a no-op, not an error.
            guard id != folder.id, let source = vm?.folders.first(where: { $0.id == id }) else { return }
            pendingDrop = PendingDrop(payload: .folder(source, memoryCount: counts[source.id] ?? 0),
                                      destination: folder,
                                      sourceSensitive: source.isSensitive)
        default:
            return
        }
    }

    @MainActor
    private func commitDrop(_ drop: PendingDrop) {
        Task {
            switch drop.payload {
            case .memory(let memory):
                try? await vm?.moveMemories(ids: [memory.id], toFolder: drop.destination.id)
            case .folder(let source, _):
                if drop.destination.kind == .default {
                    // Merging into Inbox is exactly delete: contents go to
                    // Inbox and the folder disappears.
                    try? await vm?.deleteFolder(id: source.id)
                } else {
                    try? await vm?.mergeFolders(ids: [source.id], intoName: drop.destination.name)
                }
                if selectedFolderID == source.id { selectedFolderID = drop.destination.id }
            }
        }
    }

    private func targetBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { dropTarget == id },
            set: { isTargeted in
                dropTarget = isTargeted ? id : (dropTarget == id ? nil : dropTarget)
                hoverExpandTask?.cancel()
                guard isTargeted, !expanded.contains(id) else { return }
                // Hovering a collapsed folder opens it, so a memory can be
                // dropped into a folder whose contents aren't showing.
                hoverExpandTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, dropTarget == id else { return }
                    expanded.insert(id)
                    await vm?.loadChildren(of: id)
                }
            }
        )
    }

    @ViewBuilder
    private func dropHighlight(for id: UUID) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(dropTarget == id ? 1 : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        let isSelected = selectedFolderID == folder.id && selection == nil
        // A search opens the folders that matched — hiding hits behind a
        // chevron defeats the search — but leaves the rest shut.
        let isOpen = (isSearching && hasMatches(folder)) || (!isSearching && expanded.contains(folder.id))

        HStack(spacing: 4) {
            Button {
                if isOpen {
                    expanded.remove(folder.id)
                } else {
                    expanded.insert(folder.id)
                    Task { await vm?.loadChildren(of: folder.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                selectedFolderID = folder.id
                selection = nil
                if !isOpen {
                    expanded.insert(folder.id)
                    Task { await vm?.loadChildren(of: folder.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: folder.isSensitive ? "lock.fill" : "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.white : (folder.isSensitive ? Color.orange : Color.accentColor))
                        .frame(width: 15)
                    Text(folder.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    Spacer(minLength: 4)
                    Text("\(displayCount(folder))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    if folder.kind != .default {
                        RowDeleteButton(
                            visible: hoveredRow == folder.id,
                            help: "Delete folder"
                        ) { folderPendingDelete = folder }
                    } else {
                        Color.clear.frame(width: 16)
                    }
                }
                .contentShape(Rectangle())
                .opacity(hasMatches(folder) ? 1 : 0.4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .onHover { hoveredRow = $0 ? folder.id : (hoveredRow == folder.id ? nil : hoveredRow) }
        .overlay(dropHighlight(for: folder.id))
        // Inbox is never a drag source — it cannot be deleted, and a merge
        // consumes the folder being dragged. An empty provider makes the drag
        // simply not start.
        .onDrag {
            folder.kind == .default
                ? NSItemProvider()
                : NSItemProvider(object: "folder:\(folder.id.uuidString)" as NSString)
        }
        .onDrop(of: [.text], isTargeted: targetBinding(folder.id)) { providers in
            handleDrop(providers, onto: folder)
        }
        .help(folder.isSensitive ? "\(folder.name) — sensitive" : folder.name)
    }

    @ViewBuilder
    private func memoryRow(_ memory: Memory) -> some View {
        let isSelected = selection == memory.id
        Button {
            selection = memory.id
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(memory.title ?? memory.headline ?? "Untitled")
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    if let headline = memory.headline, memory.title != nil, !headline.isEmpty {
                        Text(headline)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                RowDeleteButton(
                    visible: hoveredRow == memory.id,
                    help: "Delete memory"
                ) { memoryPendingDelete = memory }
            }
            .padding(.leading, 32)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hoveredRow = $0 ? memory.id : (hoveredRow == memory.id ? nil : hoveredRow) }
        .onDrag { NSItemProvider(object: "memory:\(memory.id.uuidString)" as NSString) }
        .contextMenu {
            Button("Delete", role: .destructive) { memoryPendingDelete = memory }
        }
    }
}

struct NewFolderSheet: View {
    @Binding var name: String
    @Binding var sensitive: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New folder")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 14) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                Toggle(isOn: $sensitive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sensitive")
                        Text("Agents set to non-sensitive only cannot read this folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 18)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 380)
    }
}

/// Right pane when a folder is selected. Inbox's controls are disabled rather
/// than hidden — a missing control reads as a bug — and the helper text says
/// what to do instead, so the dead end has an exit.
struct FolderSettingsPane: View {
    let folder: Folder
    let count: Int
    let agents: [Agent]
    let vm: MemoryStoreViewModel
    let onDeleted: () -> Void

    @State private var draftName: String = ""
    @State private var showDeleteConfirm = false

    private var isInbox: Bool { folder.kind == .default }

    private var restrictedAgentNames: [String] {
        KnownAgents.all
            .filter { known in agents.first(where: { $0.id == known.id })?.status == .nonSensitiveOnly }
            .map(\.displayName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: folder.isSensitive ? "lock.fill" : "folder.fill")
                        .font(.title2)
                        .foregroundStyle(folder.isSensitive ? .orange : .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name).font(.title2.weight(.semibold))
                        Text("\(count) memories").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if folder.isSensitive { Pill(text: "Sensitive", color: .orange) }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME")
                        .font(.system(size: 9, weight: .medium)).kerning(0.8)
                        .foregroundStyle(.tertiary)
                    if isInbox {
                        HStack(spacing: 6) {
                            Text(folder.name)
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .onSubmit { commitName() }
                    }
                }

                if let root = folder.projectRoot {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROJECT")
                            .font(.system(size: 9, weight: .medium)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Text(root).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("WHO CAN READ THIS")
                        .font(.system(size: 9, weight: .medium)).kerning(0.8)
                        .foregroundStyle(.tertiary)

                    Picker("", selection: Binding(
                        get: { folder.isSensitive },
                        set: { newVal in
                            Task { try? await vm.updateFolder(id: folder.id, name: folder.name, isSensitive: newVal) }
                        }
                    )) {
                        Text("All agents").tag(false)
                        Text("Trusted only").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .disabled(isInbox)

                    if isInbox {
                        Text("Inbox is always readable by every agent. To restrict these memories, move them to another folder.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if folder.isSensitive {
                        let names = restrictedAgentNames
                        Text(names.isEmpty
                             ? "No agent is currently restricted, so this folder is still readable by all of them. Set an agent to non-sensitive only on the Agents page."
                             : "Hidden from \(names.joined(separator: ", ")).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Every agent can read this folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !isInbox {
                    Divider()
                    HStack {
                        Button("Delete Folder...", role: .destructive) { showDeleteConfirm = true }
                        Spacer()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { draftName = folder.name }
        .onChange(of: folder.id) { _, _ in draftName = folder.name }
        .alert("Delete “\(folder.name)”?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    try? await vm.deleteFolder(id: folder.id)
                    onDeleted()
                }
            }
        } message: {
            Text("Its \(count) memories move to Inbox. No memory is deleted.")
        }
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != folder.name else { return }
        Task { try? await vm.updateFolder(id: folder.id, name: trimmed, isSensitive: folder.isSensitive) }
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

                        MetadataStrip(memory: memory, folder: vm?.folders.first { $0.id == memory.folderID })

                        if let supersededBy = memory.supersededBy, !supersededBy.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.headline)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Superseded Memory")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                    Text("Replaced by a newer version.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }

                        if let supersedes = memory.supersedes, !supersedes.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.headline)
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Superseding Memory")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.green)
                                    Text("This entry replaces an older version.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Content")
                                .font(.headline)
                            if vm?.loadedMemories[memory.id] == nil {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading full memory body...")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                            } else {
                                Text(memory.content)
                                    .font(.body)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
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

                        // The actions flow with the content rather than
                        // pinning to the pane's bottom edge: a two-line memory
                        // in a tall window otherwise strands its buttons
                        // hundreds of points below the thing they act on.
                        Divider()
                            .padding(.top, 4)

                        HStack(spacing: 10) {
                            Button("Edit") { onEdit(memory) }
                                .disabled(vm?.loadedMemories[memory.id] == nil)
                            Button("Delete", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                            .tint(.red)
                            Button("Audit trail") { onShowAuditTrail(memory) }
                            Spacer()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
    var folder: Folder?

    var body: some View {
        HStack(spacing: 8) {
            if let folder {
                Image(systemName: folder.isSensitive ? "lock.fill" : "folder.fill")
                    .font(.caption)
                    .foregroundStyle(folder.isSensitive ? .orange : .secondary)
                Text(folder.name)
                    .foregroundStyle(folder.isSensitive ? .orange : .secondary)
                    .lineLimit(1)
                Bullet()
            }
            SourceIcon(source: memory.source, size: 14)
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
    @State private var folderID: UUID
    @State private var saveError: String?

    init(mode: Mode, initialFolderID: UUID?, vm: MemoryStoreViewModel, onSaved: @escaping (Memory.ID) -> Void) {
        self.mode = mode
        self.vm = vm
        self.onSaved = onSaved
        
        // Inbox is a fixed sentinel, so fall back to it directly rather than
        // hunting for it by name — before `vm.folders` has loaded, a name lookup
        // finds nothing and a random UUID would fail the folder foreign key on
        // save with a raw SQL error.
        let folder = initialFolderID ?? MemoryStore.inboxFolderID
        
        _folderID = State(initialValue: folder)
        
        switch mode {
        case .new:
            _title = State(initialValue: "")
            _type = State(initialValue: .note)
            _content = State(initialValue: "")
            _tagsInput = State(initialValue: "")
        case .edit(let memory):
            _title = State(initialValue: memory.title ?? "")
            _type = State(initialValue: memory.type)
            _content = State(initialValue: memory.content)
            _tagsInput = State(initialValue: memory.tags.joined(separator: ", "))
            _folderID = State(initialValue: memory.folderID)
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

                            HStack(spacing: 10) {
                                Text("Folder").foregroundStyle(.secondary)
                                Picker("", selection: $folderID) {
                                    ForEach(vm.folders) { f in
                                        Text(f.name).tag(f.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()
                                Spacer()
                            }
                            .padding(.leading, 5)

                            TextField("Tags — optional, comma separated (help search find this later)", text: $tagsInput)
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
        .frame(width: 560)
        .frame(minHeight: 520)
        .frame(maxHeight: 720)
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
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Memory details are required."
        }
        return nil
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
                    folderID: folderID
                )
                onSaved(newID)
            case .edit(let memory):
                let updated = try await vm.update(
                    id: memory.id,
                    title: cleanTitle,
                    type: type,
                    content: cleanedContent,
                    tags: cleanedTags,
                    folderID: folderID
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

// MARK: - Agents & Folders page (replaces old per-memory Access Roster)

struct AgentsView: View {
    let vm: MemoryStoreViewModel
    let onReconfigureAgents: () -> Void
    @State private var showingResetConfirmation = false
    @State private var resetInProgress = false
    @State private var resetMessage: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var newFolderSensitive = false
    @State private var folderError: String?
    @State private var folderToDelete: Folder?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Agents",
                    subtitle: "Choose what each agent is allowed to read."
                ) {
                    Button("Reconfigure...", action: onReconfigureAgents)
                        .buttonStyle(.borderedProminent)
                }

                // ───── Agent status section ─────
                VStack(alignment: .leading, spacing: 12) {
                    Text("An agent set to **non-sensitive only** cannot read memories in folders marked sensitive. Mark a folder sensitive in **Memories**.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ForEach(KnownAgents.all, id: \.id) { known in
                        let dbAgent = vm.agents.first(where: { $0.id == known.id })
                        let status = dbAgent?.status ?? .all
                        AgentStatusRow(known: known, status: status, vm: vm)
                    }
                }

                Divider()

                // ───── Reset section ─────
                if let resetMessage {
                    Text(resetMessage).font(.footnote).foregroundStyle(.secondary)
                }

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
        .task { await vm.loadFoldersAndAgents() }
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
        .sheet(isPresented: $showNewFolder) {
            VStack(spacing: 16) {
                Text("New Folder").font(.headline)
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                Toggle("Sensitive", isOn: $newFolderSensitive)
                HStack {
                    Button("Cancel") { showNewFolder = false }
                    Spacer()
                    Button("Create") {
                        Task {
                            do {
                                try await vm.createFolder(name: newFolderName, isSensitive: newFolderSensitive)
                                showNewFolder = false
                            } catch {
                                folderError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
        .confirmationDialog(
            "Delete folder \"\(folderToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let folder = folderToDelete {
                    Task {
                        do {
                            try await vm.deleteFolder(id: folder.id)
                        } catch {
                            folderError = error.localizedDescription
                        }
                        folderToDelete = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("Memories in this folder will be moved to Inbox.")
        }
    }
}

struct FolderRow: View {
    let folder: Folder
    let count: Int
    let vm: MemoryStoreViewModel
    let onDelete: () -> Void

    @State private var editSensitive: Bool

    init(folder: Folder, count: Int, vm: MemoryStoreViewModel, onDelete: @escaping () -> Void) {
        self.folder = folder
        self.count = count
        self.vm = vm
        self.onDelete = onDelete
        _editSensitive = State(initialValue: folder.isSensitive)
    }

    private var isInbox: Bool { folder.name.lowercased() == "inbox" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.isSensitive ? "lock.folder.fill" : "folder.fill")
                .font(.title3)
                .foregroundStyle(folder.isSensitive ? .orange : .accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(count) memories").font(.caption).foregroundStyle(.secondary)
                    if folder.kind == .project, let root = folder.projectRoot {
                        Text("·").foregroundStyle(.tertiary)
                        Text(root).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer()

            if folder.isSensitive {
                Pill(text: "Sensitive", color: .orange)
            }

            if !isInbox {
                Toggle("Sensitive", isOn: Binding(
                    get: { folder.isSensitive },
                    set: { newVal in
                        Task { try? await vm.updateFolder(id: folder.id, name: folder.name, isSensitive: newVal) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete folder")
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AgentStatusRow: View {
    let known: KnownAgent
    let status: Agent.Status
    let vm: MemoryStoreViewModel

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(agentID: known.id, symbol: known.symbol, size: 20)
                .foregroundStyle(SourcePalette.color(for: known.id) ?? .gray)
            Text(known.displayName).font(.callout.weight(.medium))
            Text(known.id).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: Binding(
                get: { status },
                set: { newStatus in
                    Task { try? await vm.setAgentStatus(id: known.id, status: newStatus) }
                }
            )) {
                Text("All folders").tag(Agent.Status.all)
                Text("Non-sensitive only").tag(Agent.Status.nonSensitiveOnly)
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
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
    // activity id → memories that read touched (search/recent), so per-memory
    // filtering can attribute reads, which carry no single `memoryID`.
    private(set) var memoryLinks: [UUID: Set<Memory.ID>] = [:]
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
            let recentResult = try await memoryStore.recent(limit: 500)
            all = try await activityRows
            memories = recentResult.memories
            memoryLinks = try await store.memoryLinks(activityIDs: all.map(\.id))
            loadError = nil
        }
        catch { loadError = String(describing: error) }
    }

    var actors: [String] { Array(Set(all.compactMap(\.actorID))).sorted() }

    var memoryChoices: [MemoryChoice] {
        let indexed = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        // Memories that appear directly on a write/block row, plus those a read
        // touched via the join — so the filter lists memories that were only read.
        var ids = Set(all.compactMap(\.memoryID))
        for linked in memoryLinks.values { ids.formUnion(linked) }
        // Live memories only: a deleted memory's history is still reachable
        // (its rows stay in the log, and arriving via a stale filter shows the
        // "Deleted memory …" fallback tag), but dozens of tombstone entries
        // must not crowd the picker.
        return ids.compactMap { id -> MemoryChoice? in
            guard let memory = indexed[id] else { return nil }
            return MemoryChoice(id: id, title: memory.title ?? String(memory.content.prefix(40)))
        }.sorted { $0.title < $1.title }
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
            guard actorFilter == nil || a.actorID == actorFilter else { return false }
            guard let memoryFilter else { return true }
            // A row matches the memory filter if it names the memory directly
            // (write/block) or a read touched it (join link).
            return a.memoryID == memoryFilter
                || memoryLinks[a.id]?.contains(memoryFilter) == true
        }
    }

    // Classification logic lives in LocalmemCore (OperationCategory) so it can be
    // unit-tested headlessly; this maps the core bucket to the UI-facing Category
    // (which also carries the `.all` filter case and display labels).
    nonisolated static func category(of op: String) -> Category {
        switch OperationCategory.classify(op) {
        case .reads:  return .reads
        case .writes: return .writes
        case .access: return .access
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
                // Changing either filter swaps the row set under the list, which
                // would otherwise keep the old scroll offset and land the user
                // mid-list. A filter-derived identity recreates the list at the
                // top instead.
                .id("audit-\(memoryFilter?.uuidString ?? "all")-\(vm.actorFilter ?? "all")")
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
                    SourceIcon(source: event.actorID, size: 14)
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
