import SwiftUI
import AppKit
import LocalmemCore

// MARK: - View model

/// Owns the connected file sources and the background extraction queue.
/// Imports are non-blocking: files are queued and processed two at a time;
/// the UI reads live per-source state and can Stop between files.
@Observable @MainActor
final class ConnectorsViewModel {
    private let memoryStore: MemoryStore
    private let sourceStore: SourceStore
    private let engine: ExtractionEngine

    private(set) var sources: [ImportSource] = []
    private(set) var states: [UUID: SourceFileState] = [:]
    private(set) var processing: Set<UUID> = []
    var loadError: String?
    /// Whether the Connectors section shows the file-detail split view or the
    /// catalog. Lives here (not view @State) so navigating to another section
    /// and back restores exactly what the user was looking at.
    var showingDetail = false

    private var queue: [(source: ImportSource, force: Bool)] = []
    private var worker: Task<Void, Never>?

    init() throws {
        let db = try LocalmemDatabase()
        self.memoryStore = MemoryStore(database: db)
        self.sourceStore = SourceStore(database: db)
        self.engine = ExtractionEngine(memoryStore: memoryStore, sourceStore: sourceStore)
    }

    var isRunning: Bool { worker != nil }
    /// Files still to be touched by the current run (queued + in flight).
    var remainingCount: Int { queue.count + processing.count }
    var factCount: Int { states.values.reduce(0) { $0 + $1.factCount } }

    /// Whether a source is part of the current run — queued or extracting.
    /// The UI shows a spinner for the whole window, not just the in-flight
    /// slice, so a queued file never looks stalled.
    func isBusy(_ id: UUID) -> Bool {
        processing.contains(id) || queue.contains { $0.source.id == id }
    }

    func refresh() async {
        do {
            let latest = try await sourceStore.list()
            var next: [UUID: SourceFileState] = [:]
            for source in latest {
                next[source.id] = try await sourceStore.listFileStates(sourceID: source.id).first
            }
            // Only publish real changes — refresh is now polled every 2s, and
            // reassigning identical values would re-render the section per tick.
            if latest != sources { sources = latest }
            if next != states { states = next }
        } catch is CancellationError {
            // A cancelled refresh (Stop pressed) is not an error to surface.
        } catch {
            loadError = String(describing: error)
        }
    }

    /// One source per picked file; re-picking an already-imported file
    /// reprocesses it instead of creating a duplicate. Returns immediately —
    /// extraction continues in the background.
    func importFiles(urls: [URL], backend: ExtractionBackend) async {
        var batch: [ImportSource] = []
        for url in urls.prefix(ConnectorLimits.maxFilesPerBatch) {
            if let existing = sources.first(where: { $0.path == url.path }) {
                batch.append(existing)
                continue
            }
            let source = ImportSource(name: url.lastPathComponent, path: url.path, backend: backend)
            do {
                try await sourceStore.add(source)
                batch.append(source)
            } catch {
                loadError = String(describing: error)
            }
        }
        await refresh()
        enqueue(batch, force: true)
    }

    func reprocess(_ source: ImportSource) {
        enqueue([source], force: true)
    }

    /// Stop scheduling further files; the file currently extracting finishes.
    func stop() {
        queue.removeAll()
        worker?.cancel()
    }

    /// Removing a file removes the memories it produced — an imported memory
    /// without its file has no provenance, so there is no keep-memories option.
    func remove(_ source: ImportSource) async {
        queue.removeAll { $0.source.id == source.id }
        let ids = (try? await sourceStore.allMemoryIDs(sourceID: source.id)) ?? []
        try? await sourceStore.deleteMemories(ids: ids, actorKind: .cli, actorID: "user")
        try? await sourceStore.delete(id: source.id)
        states[source.id] = nil
        await refresh()
    }

    /// The memories this source's file produced, oldest first.
    func memories(for source: ImportSource) async -> [Memory] {
        let rel = URL(fileURLWithPath: source.path).lastPathComponent
        let ids = (try? await sourceStore.memoryIDs(sourceID: source.id, relPath: rel)) ?? []
        var out: [Memory] = []
        for id in ids {
            if let memory = try? await memoryStore.get(id: id) { out.append(memory) }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    func deleteMemory(_ id: UUID) async {
        try? await sourceStore.deleteMemories(ids: [id], actorKind: .cli, actorID: "user")
        await refresh()
    }

    // MARK: - Run queue

    private func enqueue(_ batch: [ImportSource], force: Bool) {
        for source in batch
        where !processing.contains(source.id) && !queue.contains(where: { $0.source.id == source.id }) {
            queue.append((source, force))
        }
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { await drain() }
    }

    /// Two files at a time (keeps the on-device model / CLI stable). Stop
    /// cancels the worker: queued files are dropped, in-flight ones finish.
    private func drain() async {
        async let first: Void = workerLoop()
        async let second: Void = workerLoop()
        _ = await (first, second)
        worker = nil
        // Fresh task: refresh must run even when the worker was cancelled.
        Task { await refresh() }
    }

    private func workerLoop() async {
        while !Task.isCancelled, let next = dequeue() {
            processing.insert(next.source.id)
            let extractor = ConnectorBackends.extractor(for: next.source.backend)
            let verifier = ConnectorBackends.verifier(for: next.source.backend)
            if let state = await engine.process(
                source: next.source, extractor: extractor, verifier: verifier, force: next.force) {
                states[next.source.id] = state
            }
            processing.remove(next.source.id)
        }
    }

    private func dequeue() -> (source: ImportSource, force: Bool)? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

// MARK: - Detail view (split pane)

/// The management view for the Files connector: flat file list on the left
/// (VS Code-explorer style, live status per row), detail for the selected file
/// on the right. Reached both by Manage and immediately after an import — the
/// whole page stays interactive while extraction runs.
struct ConnectorDetailView: View {
    let vm: ConnectorsViewModel
    let onBack: () -> Void
    let onAddFiles: () -> Void

    @State private var selection: UUID?

    private var selected: ImportSource? {
        vm.sources.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                fileList
                    .frame(width: 280)
                    .background(.background.secondary)
                Divider()
                if let selected {
                    FileDetailPane(vm: vm, source: selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView(
                        "No file selected",
                        systemImage: "doc",
                        description: Text(vm.sources.isEmpty
                            ? "Import files to extract memories from them."
                            : "Select a file to see its status and memories.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            // Poll while visible — auto-cancels on view disappear. File states
            // are also written by other Localmem processes sharing the DB
            // (a second app instance, future CLI-driven imports), and a
            // one-shot refresh leaves those stale until the user re-navigates.
            // Same pattern as the memory-list polling in LocalmemApp;
            // in-instance updates stay immediate via @Observable.
            await vm.refresh()
            if selection == nil { selection = vm.sources.first?.id }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await vm.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Connectors", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
            Text("Files").font(.headline)

            Spacer()

            if vm.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("^[Importing \(vm.remainingCount) file](inflect: true)…")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Stop") { vm.stop() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(vm.sources) { source in
                        FileRow(
                            source: source,
                            state: vm.states[source.id],
                            isBusy: vm.isBusy(source.id),
                            isSelected: selection == source.id
                        ) { selection = source.id }
                    }
                    if vm.sources.isEmpty {
                        Text("No files imported yet.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }
                }
                .padding(8)
            }
            Divider()
            // Footer height matches the detail pane's action bar so the two
            // bottom bars sit on one line across the split.
            Button(action: onAddFiles) {
                Label("Add files…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 10)
            .frame(height: 56)
        }
    }
}

private struct FileRow: View {
    let source: ImportSource
    let state: SourceFileState?
    let isBusy: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.mini).frame(width: 16)
                } else {
                    Image(systemName: FileStatusStyle.symbol(state?.status))
                        .foregroundStyle(FileStatusStyle.color(state?.status))
                        .frame(width: 16)
                }
                Text(source.name)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let facts = state?.factCount, facts > 0 {
                    Text("\(facts)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shared status → icon/color mapping for the file list and detail pane.
/// A source with no recorded state yet reads as pending.
enum FileStatusStyle {
    static func symbol(_ status: SourceFileState.Status?) -> String {
        switch status {
        case .processed:   return "checkmark.circle.fill"
        case .partial:     return "checkmark.circle"
        case .skipped:     return "minus.circle"
        case .failed:      return "exclamationmark.triangle.fill"
        case .pending, nil: return "clock"
        }
    }

    static func color(_ status: SourceFileState.Status?) -> Color {
        switch status {
        case .processed, .partial: return .green
        case .skipped:             return .orange
        case .failed:              return .red
        case .pending, nil:        return .secondary
        }
    }

    static func label(_ status: SourceFileState.Status?) -> String {
        switch status {
        case .processed:   return "Processed"
        case .partial:     return "Partially processed"
        case .skipped:     return "Skipped"
        case .failed:      return "Failed"
        case .pending, nil: return "Pending"
        }
    }
}

// MARK: - Right pane

private struct FileDetailPane: View {
    let vm: ConnectorsViewModel
    let source: ImportSource

    @State private var memories: [Memory] = []
    @State private var confirmingRemove = false

    private var state: SourceFileState? { vm.states[source.id] }
    private var isBusy: Bool { vm.isBusy(source.id) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "doc")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).font(.title3.weight(.semibold))
                        Text(source.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Pill(text: ConnectorBackends.displayName(for: source.backend),
                         color: source.backend.isOnDevice ? .green : .secondary)
                }

                if isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Extracting memories…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    statusGrid
                }

                Divider()

                HStack {
                    Text("Memories from this file").font(.headline)
                    Spacer()
                    if !memories.isEmpty {
                        Text("\(memories.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(memories) { memory in memoryRow(memory) }
                        if memories.isEmpty && !isBusy {
                            Text(state?.reasonCode == "no_facts"
                                 ? "No personal facts were found in this file."
                                 : "No memories yet.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 16)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            // Pinned action bar — same 56pt as the file list's footer so the
            // two bottom bars align across the split.
            HStack(spacing: 10) {
                Button {
                    vm.reprocess(source)
                } label: {
                    Label("Reprocess", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
                Spacer()
                Button(role: .destructive) { confirmingRemove = true } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .task(id: taskKey) { memories = await vm.memories(for: source) }
        .confirmationDialog(
            "Remove “\(source.name)”?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove File & Memories", role: .destructive) {
                Task { await vm.remove(source) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(memories.isEmpty
                 ? "The file will be removed from Localmem."
                 : "^[\(memories.count) memory](inflect: true) imported from this file will be deleted from your vault.")
        }
    }

    /// Reload the memories list when the selection changes or a run finishes.
    private var taskKey: String {
        "\(source.id)-\(state?.processedAt?.timeIntervalSince1970 ?? 0)-\(state?.factCount ?? 0)"
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: FileStatusStyle.symbol(state?.status))
                        .foregroundStyle(FileStatusStyle.color(state?.status))
                    Text(FileStatusStyle.label(state?.status))
                }
            }
            if let error = state?.error {
                GridRow {
                    Text("Reason").foregroundStyle(.secondary)
                    Text(error).foregroundStyle(FileStatusStyle.color(state?.status))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                Text("Last processed").foregroundStyle(.secondary)
                Text(state?.processedAt.map(Self.relative) ?? "—")
            }
            // "N extracted → M kept" — the verify pass's transparency line.
            // Trust feature; also surfaces an over-aggressive verifier
            // immediately. Absent on rows processed before the pass shipped.
            if let extracted = state?.extractedCount, let kept = state?.keptCount {
                GridRow {
                    Text("Curation").foregroundStyle(.secondary)
                    Text("\(extracted) extracted → \(kept) kept")
                }
            }
        }
        .font(.callout)
    }

    private func memoryRow(_ memory: Memory) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MemoryTypePill(type: memory.type)
            VStack(alignment: .leading, spacing: 3) {
                if let title = memory.title {
                    Text(title).font(.callout.weight(.medium))
                }
                Text(memory.content)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                Task {
                    await vm.deleteMemory(memory.id)
                    memories.removeAll { $0.id == memory.id }
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete this memory")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
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
