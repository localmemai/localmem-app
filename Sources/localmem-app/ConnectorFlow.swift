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

    /// Dry-run: extract proposals for review without writing anything.
    func preview(_ source: ImportSource, force: Bool) async -> ExtractionPreview {
        guard !running.contains(source.id) else { return ExtractionPreview() }
        running.insert(source.id)
        progress[source.id] = ExtractionProgress(filesTotal: 0, filesDone: 0, factsAdded: 0, currentFile: nil)
        let extractor = ConnectorBackends.extractor(for: source.backend)
        let id = source.id
        let result = await engine.preview(source: source, extractor: extractor, force: force) { p in
            Task { @MainActor in self.progress[id] = p }
        }
        running.remove(source.id)
        return result
    }

    /// Persist the user-approved subset of a preview.
    @discardableResult
    func commit(_ source: ImportSource, preview: ExtractionPreview, approved: Set<UUID>) async -> ExtractionRunSummary {
        let summary = await engine.commit(source: source, preview: preview, approvedIDs: approved)
        lastSummary[source.id] = summary
        await refresh()
        return summary
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
        case chooseBackend
        case ready(ExtractionBackend)
        case previewing
        case review
        case committing
        case done
        case blocked(String)
    }

    @State private var step: Step = .detecting
    @State private var backendChoices: [BackendChoice] = []
    @State private var source: ImportSource?
    @State private var preview = ExtractionPreview()
    @State private var selected: Set<UUID> = []
    @State private var summary: ExtractionRunSummary?
    @State private var committed = false

    private struct BackendChoice: Identifiable, Equatable {
        let backend: ExtractionBackend
        let title: String
        let detail: String
        let symbol: String
        let agentID: String?
        var id: String { backend.storageValue }
    }
    private static let cliAgents = [("claude-code", "Claude Code"), ("codex", "Codex")]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.weight(.semibold))
            content
            if hasFooter {
                Divider()
                footer
            }
        }
        .padding(24)
        .frame(width: stepWidth)
        .task { await detect() }
    }

    private var stepWidth: CGFloat {
        switch step { case .review, .done: return 540; default: return 480 }
    }

    private var hasFooter: Bool {
        switch step { case .previewing, .committing: return false; default: return true }
    }

    private var title: String {
        switch step {
        case .previewing: return "Reading files…"
        case .review:     return "Review memories"
        case .committing: return "Adding memories…"
        case .done:       return "Import complete"
        default:          return "Connect a folder or file"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .detecting:
            row("hourglass", "Checking for the on-device model…")

        case .chooseBackend:
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose how to extract memories from your files:")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(backendChoices) { choice in
                    Button { step = .ready(choice.backend) } label: {
                        HStack(spacing: 10) {
                            if let agentID = choice.agentID {
                                AgentIcon(agentID: agentID, symbol: choice.symbol, size: 22)
                            } else {
                                Image(systemName: choice.symbol)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 22)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title).fontWeight(.medium)
                                Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
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
                Text("Choose a folder or file (Text, Markdown, or PDF). You'll review what's found before anything is saved.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { chooseAndRun(backend: backend) } label: {
                    Label("Choose folder or file…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }

        case .previewing:
            progressView

        case .review:
            reviewView

        case .committing:
            VStack(alignment: .leading, spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Saving \(selected.count) to your vault…").font(.callout).foregroundStyle(.secondary)
            }

        case .done:
            doneView

        case .blocked(let message):
            row("xmark.octagon", message)
        }
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        switch step {
        case .review:
            HStack {
                Button("Cancel") { cancelBeforeCommit() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(addLabel) { Task { await addApproved() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .done:
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        default:
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
    }

    private var addLabel: String {
        selected.isEmpty ? "Finish" : "Add \(selected.count) \(selected.count == 1 ? "memory" : "memories")"
    }

    // MARK: - Step views

    private var progressView: some View {
        let p = source.flatMap { vm.progress[$0.id] }
        return VStack(alignment: .leading, spacing: 12) {
            if let p, p.filesTotal > 0 {
                ProgressView(value: Double(p.filesDone), total: Double(p.filesTotal)) {
                    Text("Reading & extracting memories…")
                }
                Text("\(p.filesDone) of \(p.filesTotal) files · \(p.factsAdded) found")
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

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if preview.facts.isEmpty {
                row("info.circle", "No memories were found in these files.")
            } else {
                FactReviewList(facts: preview.facts, selected: $selected)
            }
            if !preview.failedFiles.isEmpty || !preview.skippedFiles.isEmpty {
                outcomeNote
            }
        }
    }

    private var outcomeNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(preview.failedFiles, id: \.relPath) { f in
                Label("\(f.relPath) — \(f.error ?? "couldn't be read")", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if !preview.skippedFiles.isEmpty {
                Label("^[\(preview.skippedFiles.count) file](inflect: true) skipped (unsupported type or too large).",
                      systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                chip("\(summary?.factsAdded ?? 0) memories added", .accentColor)
                if (summary?.filesSkipped ?? 0) > 0 { chip("\(summary!.filesSkipped) skipped", .orange) }
                if (summary?.filesFailed ?? 0) > 0 { chip("\(summary!.filesFailed) failed", .red) }
            }
            if (summary?.factsAdded ?? 0) > 0 {
                row("checkmark.seal.fill", "Saved to your vault. Manage this source from the Connectors page.")
            } else {
                row("info.circle", "No memories were added.")
            }
        }
    }

    // MARK: - Actions

    private func detect() async {
        guard step == .detecting else { return }
        var choices: [BackendChoice] = []

        if ConnectorBackends.appleAvailable {
            choices.append(BackendChoice(
                backend: .apple,
                title: "On-device model",
                detail: "Runs entirely on your Mac — fully private. Best for notes and short documents.",
                symbol: "apple.logo", agentID: nil))
        }
        let installed = await ConnectorBackends.availableAgents(catalog: Self.cliAgents)
        for agent in installed {
            choices.append(BackendChoice(
                backend: .agent(agent.id),
                title: agent.name,
                detail: "Reads your files with \(agent.name) — more thorough on tables and complex documents. Uses your \(agent.name) plan.",
                symbol: "terminal", agentID: agent.id))
        }

        backendChoices = choices
        if choices.isEmpty {
            step = .blocked("No on-device model, and no supported agent is available. Turn on Apple Intelligence, or connect Claude Code or Codex, then try again.")
        } else if choices.count == 1 {
            step = .ready(choices[0].backend)
        } else {
            step = .chooseBackend
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

    /// Create the source, dry-run the extraction, and land on the review step.
    /// Nothing is written to the vault yet — the user approves in `addApproved`.
    private func runOn(url: URL, backend: ExtractionBackend) async {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let kind: ImportSource.Kind = isDir ? .folder : .file
        guard let created = await vm.createSource(
            name: url.lastPathComponent, kind: kind, path: url.path, bookmark: nil, backend: backend)
        else {
            step = .blocked(vm.loadError ?? "Couldn't create the source.")
            return
        }
        source = created
        step = .previewing
        let result = await vm.preview(created, force: true)
        preview = result
        selected = Set(result.facts.map(\.id))
        step = .review
    }

    private func addApproved() async {
        guard let source else { return }
        step = .committing
        summary = await vm.commit(source, preview: preview, approved: selected)
        committed = true
        step = .done
    }

    /// Backing out before committing removes the source we speculatively created
    /// so we don't leave an empty connected source behind.
    private func cancelBeforeCommit() {
        if let source, !committed {
            Task { await vm.remove(source, deleteMemories: true); dismiss() }
        } else {
            dismiss()
        }
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

// MARK: - Memory review

/// A per-file grouped, checkbox list of proposed memories. The caller owns the
/// `selected` set — unchecked facts are excluded when the source is committed.
struct FactReviewList: View {
    let facts: [PreviewFact]
    @Binding var selected: Set<UUID>

    private var relPaths: [String] {
        var seen = Set<String>(); var order: [String] = []
        for f in facts where seen.insert(f.relPath).inserted { order.append(f.relPath) }
        return order
    }
    private var showHeaders: Bool { relPaths.count > 1 }
    private var allSelected: Bool { !facts.isEmpty && selected.count == facts.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Review what was found").font(.callout.weight(.medium))
                Spacer()
                Button(allSelected ? "Deselect all" : "Select all") {
                    selected = allSelected ? [] : Set(facts.map(\.id))
                }
                .buttonStyle(.link).font(.caption)
            }
            Text("Uncheck anything that's wrong or you don't want to keep, then add the rest.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(relPaths, id: \.self) { rel in
                        if showHeaders {
                            Label(rel, systemImage: "doc")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).padding(.top, 2)
                        }
                        ForEach(facts.filter { $0.relPath == rel }) { fact in row(fact) }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(height: 300)
        }
    }

    private func row(_ fact: PreviewFact) -> some View {
        let isOn = Binding(
            get: { selected.contains(fact.id) },
            set: { on in if on { selected.insert(fact.id) } else { selected.remove(fact.id) } })
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    MemoryTypePill(type: fact.type)
                    Text(fact.title).font(.callout.weight(.medium))
                }
                Text(fact.content).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
    }
}

/// A small colored capsule naming a memory's type (fact/preference/decision/…).
struct MemoryTypePill: View {
    let type: MemoryType
    var body: some View {
        Text(type.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch type {
        case .fact:       return .blue
        case .preference: return .purple
        case .decision:   return .green
        case .project:    return .orange
        case .note:       return .secondary
        }
    }
}

// MARK: - Reprocess review sheet

/// Re-scans an already-connected source and lets the user review the proposed
/// memories before they replace what's there. Same approve-then-write contract
/// as the connect wizard.
struct SourceReviewSheet: View {
    let vm: ConnectorsViewModel
    let source: ImportSource
    var onFinished: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private enum Step { case previewing, review, committing, done }
    @State private var step: Step = .previewing
    @State private var preview = ExtractionPreview()
    @State private var selected: Set<UUID> = []
    @State private var summary: ExtractionRunSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleText).font(.title3.weight(.semibold))
            content
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 540)
        .task { await load() }
    }

    private var titleText: String {
        switch step {
        case .previewing: return "Reprocessing “\(source.name)”…"
        case .review:     return "Review changes"
        case .committing: return "Saving…"
        case .done:       return "Reprocessed"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .previewing:
            let p = vm.progress[source.id]
            VStack(alignment: .leading, spacing: 12) {
                if let p, p.filesTotal > 0 {
                    ProgressView(value: Double(p.filesDone), total: Double(p.filesTotal)) {
                        Text("Reading & extracting memories…")
                    }
                    Text("\(p.filesDone) of \(p.filesTotal) files · \(p.factsAdded) found")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Reading files…").font(.callout).foregroundStyle(.secondary)
                }
            }
        case .review:
            VStack(alignment: .leading, spacing: 12) {
                if preview.facts.isEmpty {
                    Label("No memories were found. Applying will clear this source's existing memories.",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    FactReviewList(facts: preview.facts, selected: $selected)
                    Text("Applying replaces this source's current memories with the checked ones.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .committing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving \(selected.count) to your vault…").font(.callout).foregroundStyle(.secondary)
            }
        case .done:
            HStack(spacing: 14) {
                Text("\(summary?.factsAdded ?? 0) memories").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                if (summary?.filesFailed ?? 0) > 0 {
                    Text("\(summary!.filesFailed) failed").font(.callout.weight(.semibold)).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch step {
        case .review:
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(selected.isEmpty ? "Apply" : "Apply \(selected.count) \(selected.count == 1 ? "memory" : "memories")") {
                    Task { await apply() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        case .done:
            HStack { Spacer(); Button("Done") { onFinished(); dismiss() }.keyboardShortcut(.defaultAction) }
        default:
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
    }

    private func load() async {
        let result = await vm.preview(source, force: true)
        preview = result
        selected = Set(result.facts.map(\.id))
        step = .review
    }

    private func apply() async {
        step = .committing
        summary = await vm.commit(source, preview: preview, approved: selected)
        step = .done
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
    @State private var reprocessing = false

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
                Button { reprocessing = true } label: {
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
        .sheet(isPresented: $reprocessing) {
            SourceReviewSheet(vm: vm, source: source, onFinished: { Task { await reload() } })
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
