import SwiftUI
import AppKit
import LocalmemCore

// MARK: - View model

@Observable @MainActor
final class ConnectorsViewModel {
    private let sourceStore: SourceStore
    private let engine: ExtractionEngine

    var sources: [ImportSource] = []
    var stats: [UUID: SourceStats] = [:]
    var running: Set<UUID> = []
    var progress: [UUID: ExtractionProgress] = [:]
    var lastSummary: [UUID: ExtractionRunSummary] = [:]
    var loadError: String?

    init() throws {
        let db = try LocalmemDatabase()
        let store = SourceStore(database: db)
        self.sourceStore = store
        self.engine = ExtractionEngine(memoryStore: MemoryStore(database: db), sourceStore: store)
    }

    func refresh() async {
        do {
            let list = try await sourceStore.list()
            sources = list
            var s: [UUID: SourceStats] = [:]
            for src in list { s[src.id] = (try? await sourceStore.stats(sourceID: src.id)) ?? SourceStats() }
            stats = s
        } catch {
            loadError = String(describing: error)
        }
    }

    func createSource(name: String, kind: ImportSource.Kind, path: String, bookmark: Data?, backend: ExtractionBackend) async -> ImportSource? {
        let source = ImportSource(name: name, kind: kind, path: path, bookmark: bookmark, backend: backend)
        do { try await sourceStore.add(source) } catch { loadError = String(describing: error); return nil }
        await refresh()
        return source
    }

    func run(_ source: ImportSource, force: Bool) async {
        guard !running.contains(source.id) else { return }
        running.insert(source.id)
        progress[source.id] = ExtractionProgress(filesTotal: 0, filesDone: 0, factsAdded: 0, currentFile: nil)
        let extractor = ConnectorBackends.extractor(for: source.backend)
        let id = source.id
        let summary = await engine.run(source: source, extractor: extractor, force: force) { p in
            Task { @MainActor in self.progress[id] = p }
        }
        running.remove(source.id)
        lastSummary[source.id] = summary
        await refresh()
    }

    func remove(_ source: ImportSource, deleteMemories: Bool) async {
        if deleteMemories {
            let ids = (try? await sourceStore.allMemoryIDs(sourceID: source.id)) ?? []
            try? await sourceStore.deleteMemories(ids: ids)
        }
        try? await sourceStore.delete(id: source.id)
        await refresh()
    }

    func setDisconnected(_ source: ImportSource, _ disconnected: Bool) async {
        var s = source
        s.status = disconnected ? .disconnected : .active
        try? await sourceStore.update(s)
        if !disconnected { await run(s, force: false) }   // Reconnect → catch-up scan
        await refresh()
    }

    func fileStates(_ source: ImportSource) async -> [SourceFileState] {
        (try? await sourceStore.listFileStates(sourceID: source.id)) ?? []
    }
}

// MARK: - Connect wizard

struct ConnectorWizardView: View {
    let vm: ConnectorsViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case detecting
        case chooseAgent
        case ready(ExtractionBackend)
        case running
        case done
        case blocked(String)
    }

    @State private var step: Step = .detecting
    @State private var appleReason = ""
    @State private var agents: [AgentChoice] = []
    @State private var sourceID: UUID?
    @State private var summary: ExtractionRunSummary?
    @State private var failedFiles: [SourceFileState] = []

    private struct AgentChoice: Identifiable, Equatable { let id: String; let name: String }
    private static let cliAgents = [("claude-code", "Claude Code"), ("codex", "Codex")]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.weight(.semibold))
            content
            if step != .running {
                Divider()
                HStack {
                    Spacer()
                    Button(isDone ? "Done" : "Cancel") { dismiss() }
                        .keyboardShortcut(isDone ? .defaultAction : .cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await detect() }
    }

    private var isDone: Bool { if case .done = step { return true }; return false }

    private var title: String {
        switch step {
        case .running: return "Importing…"
        case .done:    return "Import complete"
        default:       return "Connect a folder or file"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .detecting:
            row("hourglass", "Checking for the on-device model…")

        case .chooseAgent:
            VStack(alignment: .leading, spacing: 12) {
                row("exclamationmark.triangle", appleReason)
                Text("Choose an agent to extract facts. Files in this source will be read by it (using its model and your plan):")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(agents) { agent in
                    Button { step = .ready(.agent(agent.id)) } label: {
                        HStack(spacing: 10) {
                            AgentIcon(agentID: agent.id, symbol: "terminal", size: 20)
                            Text(agent.name)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

        case .ready(let backend):
            VStack(alignment: .leading, spacing: 12) {
                if backend.isOnDevice {
                    row("checkmark.seal.fill", "On-device model ready — extraction runs entirely on your Mac.")
                } else {
                    row("person.2.fill", "Using \(backendName(backend)) to extract. Files are read by its model.")
                }
                Text("Choose a folder or file (Text, Markdown, or PDF).")
                    .font(.callout).foregroundStyle(.secondary)
                Button { chooseAndRun(backend: backend) } label: {
                    Label("Choose folder or file…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }

        case .running:
            runningView

        case .done:
            doneView

        case .blocked(let message):
            row("xmark.octagon", message)
        }
    }

    private var runningView: some View {
        let p = sourceID.flatMap { vm.progress[$0] }
        return VStack(alignment: .leading, spacing: 12) {
            if let p, p.filesTotal > 0 {
                ProgressView(value: Double(p.filesDone), total: Double(p.filesTotal)) {
                    Text("Extracting memories…")
                }
                Text("\(p.filesDone) of \(p.filesTotal) files · \(p.factsAdded) facts")
                    .font(.callout).foregroundStyle(.secondary)
                if let f = p.currentFile {
                    Text(f).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Reading files…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                chip("\(summary?.filesProcessed ?? 0) files", .green)
                chip("\(summary?.factsAdded ?? 0) facts", .accentColor)
                if (summary?.filesSkipped ?? 0) > 0 { chip("\(summary!.filesSkipped) skipped", .orange) }
                if (summary?.filesFailed ?? 0) > 0 { chip("\(summary!.filesFailed) failed", .red) }
            }

            if !failedFiles.isEmpty {
                Text("Some files couldn't be processed:").font(.callout.weight(.medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(failedFiles) { file in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red).font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.relPath).font(.caption.weight(.medium))
                                    if let e = file.error {
                                        Text(e).font(.caption2).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
            } else if (summary?.factsAdded ?? 0) == 0 {
                row("info.circle", "No memories were found in these files.")
            } else {
                row("checkmark.seal.fill", "Added \(summary?.factsAdded ?? 0) memories. Manage this source from the Connectors page.")
            }
        }
    }

    // MARK: - Actions

    private func detect() async {
        guard step == .detecting else { return }
        if ConnectorBackends.appleAvailable {
            step = .ready(.apple)
        } else {
            appleReason = ConnectorBackends.appleUnavailableReason
            let installed = await ConnectorBackends.availableAgents(catalog: Self.cliAgents)
            if installed.isEmpty {
                step = .blocked("No on-device model, and no supported agent is available. Turn on Apple Intelligence, or connect Claude Code or Codex, then try again.")
            } else {
                agents = installed.map { AgentChoice(id: $0.id, name: $0.name) }
                step = .chooseAgent
            }
        }
    }

    private func chooseAndRun(backend: ExtractionBackend) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect"
        panel.message = "Choose a folder or file to import memories from."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runOn(url: url, backend: backend) }
    }

    private func runOn(url: URL, backend: ExtractionBackend) async {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let kind: ImportSource.Kind = isDir ? .folder : .file
        guard let source = await vm.createSource(
            name: url.lastPathComponent, kind: kind, path: url.path, bookmark: nil, backend: backend)
        else {
            step = .blocked(vm.loadError ?? "Couldn't create the source.")
            return
        }
        sourceID = source.id
        step = .running
        await vm.run(source, force: true)
        summary = vm.lastSummary[source.id]
        failedFiles = (await vm.fileStates(source)).filter { $0.status == .failed }
        step = .done
    }

    private func backendName(_ backend: ExtractionBackend) -> String {
        if case .agent(let id) = backend {
            return Self.cliAgents.first { $0.0 == id }?.1 ?? id
        }
        return "the on-device model"
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.callout.weight(.semibold)).foregroundStyle(color)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

// MARK: - Connected source row

struct ConnectedSourceRow: View {
    let vm: ConnectorsViewModel
    let source: ImportSource
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: source.kind == .folder ? "folder.fill" : "doc.fill")
                    .foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).fontWeight(.medium)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if vm.running.contains(source.id) {
                    ProgressView().controlSize(.small)
                } else if source.status == .disconnected {
                    Pill(text: "Disconnected", color: .secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        if vm.running.contains(source.id), let p = vm.progress[source.id] {
            return "Processing \(p.filesDone)/\(p.filesTotal)…"
        }
        let s = vm.stats[source.id] ?? SourceStats()
        var parts = ["\(s.filesProcessed) files", "\(s.factCount) facts"]
        if let last = s.lastProcessed {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
            parts.append(f.localizedString(for: last, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Manage (sources of one connector)

struct ConnectorManageView: View {
    let vm: ConnectorsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var landingSource: ImportSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files & Folders").font(.title3.weight(.semibold))
                    Text("^[\(vm.sources.count) connected source](inflect: true)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Divider()
            if vm.sources.isEmpty {
                Text("No sources connected yet.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(vm.sources) { source in
                            ConnectedSourceRow(vm: vm, source: source) { landingSource = source }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .task { await vm.refresh() }
        .sheet(item: $landingSource) { source in
            SourceLandingView(vm: vm, source: source)
        }
    }
}

// MARK: - Landing page

struct SourceLandingView: View {
    let vm: ConnectorsViewModel
    let source: ImportSource
    @Environment(\.dismiss) private var dismiss

    @State private var files: [SourceFileState] = []
    @State private var confirmingRemove = false

    private var stats: SourceStats { vm.stats[source.id] ?? SourceStats() }
    private var isRunning: Bool { vm.running.contains(source.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: source.kind == .folder ? "folder" : "doc")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.title3.weight(.semibold))
                    Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Pill(text: backendLabel, color: source.backend.isOnDevice ? .green : .secondary)
            }

            HStack(spacing: 24) {
                stat("Files processed", "\(stats.filesProcessed)")
                stat("Facts generated", "\(stats.factCount)")
                if stats.filesSkipped > 0 { stat("Skipped", "\(stats.filesSkipped)", .orange) }
                if stats.filesFailed > 0 { stat("Failed", "\(stats.filesFailed)", .red) }
                stat("Last processed", stats.lastProcessed.map(Self.relative) ?? "—")
            }

            if isRunning, let p = vm.progress[source.id] {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p.filesTotal > 0 ? Double(p.filesDone) / Double(p.filesTotal) : 0)
                    Text("Processing \(p.filesDone)/\(p.filesTotal) — \(p.factsAdded) facts\(p.currentFile.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Files").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in fileRow(file) }
                    if files.isEmpty { Text("No files processed yet.").foregroundStyle(.secondary).font(.callout) }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)

            Divider()
            HStack(spacing: 10) {
                Button { Task { await vm.run(source, force: true); await reload() } } label: {
                    Label("Reprocess", systemImage: "arrow.clockwise")
                }
                .disabled(isRunning)
                if source.status == .active {
                    Button { Task { await vm.setDisconnected(source, true) } } label: { Label("Disconnect", systemImage: "pause") }
                } else {
                    Button { Task { await vm.setDisconnected(source, false); await reload() } } label: { Label("Reconnect", systemImage: "play") }
                }
                Button(role: .destructive) { confirmingRemove = true } label: { Label("Remove", systemImage: "trash") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await reload() }
        .onChange(of: isRunning) { _, now in if !now { Task { await reload() } } }
        .confirmationDialog("Remove “\(source.name)”?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove & keep memories") { Task { await vm.remove(source, deleteMemories: false); dismiss() } }
            Button("Remove & delete its memories", role: .destructive) { Task { await vm.remove(source, deleteMemories: true); dismiss() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func reload() async { files = await vm.fileStates(source) }

    private var backendLabel: String {
        source.backend.isOnDevice ? "On-device" : { if case .agent(let id) = source.backend { return id }; return "Agent" }()
    }

    private func stat(_ label: String, _ value: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fileRow(_ file: SourceFileState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol(file.status)).foregroundStyle(statusColor(file.status)).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.relPath).font(.callout).lineLimit(1).truncationMode(.middle)
                if let err = file.error { Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if file.factCount > 0 { Text("\(file.factCount) facts").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
    }

    private func statusSymbol(_ s: SourceFileState.Status) -> String {
        switch s {
        case .processed: return "checkmark.circle.fill"
        case .partial:   return "checkmark.circle"
        case .skipped:   return "minus.circle"
        case .failed:    return "exclamationmark.triangle.fill"
        case .pending:   return "clock"
        }
    }

    private func statusColor(_ s: SourceFileState.Status) -> Color {
        switch s {
        case .processed: return .green
        case .partial:   return .green
        case .skipped:   return .orange
        case .failed:    return .red
        case .pending:   return .secondary
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
