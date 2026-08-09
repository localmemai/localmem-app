import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalmemCore

// MARK: - Connectors catalog

/// A connector *type* shown in the Connectors catalog. v1 ships exactly one
/// *available* type (Files); the rest are coming-soon cards that advertise the
/// roadmap in-product.
private struct ConnectorType: Identifiable {
    enum Status { case available, comingSoon }
    let id: String
    let name: String
    let symbol: String
    let blurb: String
    let status: Status
    var fileTypes: [String] = []          // shown as chips on the available card
}

private let connectorCatalog: [ConnectorType] = [
    ConnectorType(
        id: "files",
        name: "Files",
        symbol: "folder",
        blurb: "Pick the files you want and Localmem pulls out the key facts on your Mac, turning them into memories.",
        status: .available,
        fileTypes: ["TXT", "Markdown", "PDF"]
    ),
    ConnectorType(id: "apple-notes", name: "Apple Notes", symbol: "note.text",
                  blurb: "Import notes straight from Apple Notes.", status: .comingSoon),
    ConnectorType(id: "obsidian", name: "Obsidian", symbol: "book.closed",
                  blurb: "Connect an Obsidian vault of Markdown notes.", status: .comingSoon),
    ConnectorType(id: "notion", name: "Notion", symbol: "doc.text",
                  blurb: "Bring in pages and databases from Notion.", status: .comingSoon),
]

struct ConnectorsCatalogView: View {
    /// Injected from the app shell. The VM outlives this view on purpose —
    /// it owns the import queue and in-flight state, so navigating away and
    /// back must not reset it (the spinner keeps spinning).
    let vm: ConnectorsViewModel?
    @State private var detecting = false
    @State private var backendChoices: [BackendChoice] = []
    @State private var choosingBackend = false
    @State private var pendingBackend: ExtractionBackend?
    @State private var blockedMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 16, alignment: .top)]

    var body: some View {
        Group {
            if let vm, vm.showingDetail {
                ConnectorDetailView(
                    vm: vm,
                    onBack: { vm.showingDetail = false },
                    onAddFiles: startImport
                )
            } else {
                catalog
            }
        }
        .sheet(isPresented: $choosingBackend, onDismiss: {
            // The open panel must not start until the sheet is fully torn
            // down: runModal() spins a nested run loop, and entering it
            // mid-dismissal wedges the window's sheet state so the next
            // presentation renders collapsed (#19).
            guard let backend = pendingBackend else { return }
            pendingBackend = nil
            pickFiles(backend: backend)
        }) {
            BackendChoiceSheet(choices: backendChoices) { backend in
                pendingBackend = backend
                choosingBackend = false
            }
        }
        .alert("Can't import", isPresented: Binding(
            get: { blockedMessage != nil },
            set: { if !$0 { blockedMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Connectors",
                    // Not "extracted on-device, privately": that is only true of
                    // the Apple backend. It read as an unconditional promise
                    // exactly where it was least true — a Mac without Apple
                    // Intelligence has no on-device option at all, so the
                    // agent backend is the only one it can offer.
                    subtitle: "Bring existing context in from your files and apps — you choose how each import is extracted, before any file is read."
                )

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(connectorCatalog) { connector in
                        if connector.id == "files" {
                            ConnectorCard(
                                connector: connector,
                                fileCount: vm?.sources.count ?? 0,
                                factCount: vm?.factCount ?? 0,
                                importing: vm?.isRunning ?? false,
                                importDisabled: detecting,
                                onImport: startImport,
                                onManage: { vm?.showingDetail = true }
                            )
                        } else {
                            ConnectorCard(connector: connector)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await vm?.refresh() }
    }

    // MARK: - Import flow

    /// Backend first (so the user knows up front whether anything leaves the
    /// Mac), then the file panel, then straight into the detail view while
    /// extraction runs in the background.
    private func startImport() {
        guard !detecting else { return }
        detecting = true
        Task {
            var choices: [BackendChoice] = []
            if ConnectorBackends.appleAvailable {
                choices.append(BackendChoice(
                    backend: .apple,
                    title: "On-device model",
                    detail: "Runs entirely on your Mac — fully private. Best for notes and short documents.",
                    symbol: "apple.logo", agentID: nil))
            }
            for agent in await ConnectorBackends.availableAgents() {
                choices.append(BackendChoice(
                    backend: .agent(agent.id),
                    title: agent.name,
                    // "Reads your files with X" was ambiguous in the direction
                    // that flattered us — it can be read as "runs the X binary
                    // locally". Name the egress: this is the one path in
                    // Localmem where user content leaves the Mac.
                    detail: "Sends the text of your files to \(agent.name) — more thorough on tables and complex documents. Uses your \(agent.name) plan.",
                    symbol: "terminal", agentID: agent.id))
            }
            detecting = false

            if choices.isEmpty {
                blockedMessage = "No extraction backend is available. "
                    + ConnectorBackends.appleUnavailableReason
                    + " Turn on Apple Intelligence, or connect Claude Code or Codex, then try again."
            } else if choices.count == 1 {
                pickFiles(backend: choices[0].backend)
            } else {
                backendChoices = choices
                choosingBackend = true
            }
        }
    }

    private func pickFiles(backend: ExtractionBackend) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.allowedTypes
        panel.prompt = "Import"
        panel.message = "Choose the files to import memories from (Text, Markdown, or PDF)."
        guard panel.runModal() == .OK, !panel.urls.isEmpty, let vm else { return }
        Task { await vm.importFiles(urls: panel.urls, backend: backend) }
        vm.showingDetail = true
    }

    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.plainText, .pdf]
        for ext in ConnectorLimits.supportedExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}

// MARK: - Backend choice

struct BackendChoice: Identifiable {
    let backend: ExtractionBackend
    let title: String
    let detail: String
    let symbol: String
    let agentID: String?
    var id: String { backend.storageValue }
}

/// One-shot picker shown only when more than one backend is available.
struct BackendChoiceSheet: View {
    let choices: [BackendChoice]
    let onPick: (ExtractionBackend) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose how to extract memories").font(.title3.weight(.semibold))
            Text("This choice applies to the files you're about to import.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(choices) { choice in
                    Button { onPick(choice.backend) } label: {
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

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        // Height floor so a degenerate first layout can't present the sheet
        // collapsed (see AgentDetailsSheet for the same macOS sheet-sizing
        // guard). Two choice rows plus chrome comfortably exceed this.
        .frame(width: 480)
        .frame(minHeight: 240)
    }
}

// MARK: - Card

private struct ConnectorCard: View {
    let connector: ConnectorType
    var fileCount: Int = 0
    var factCount: Int = 0
    var importing: Bool = false
    var importDisabled: Bool = false
    var onImport: () -> Void = {}
    var onManage: () -> Void = {}

    private var available: Bool { connector.status == .available }
    private var connected: Bool { available && fileCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: connector.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(available ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
                    .background((available ? Color.accentColor : Color.secondary).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(connector.name).font(.headline)
                    Pill(text: available ? "Available" : "Coming soon",
                         color: available ? .green : .secondary)
                }
                Spacer(minLength: 0)
            }

            Text(connector.blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !connector.fileTypes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(connector.fileTypes, id: \.self) { type in
                        Text(type)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if connected {
                if importing {
                    // A run is in flight (possibly started before the user
                    // navigated away) — surface it on the catalog too, so the
                    // animated indicator is visible the whole time, not just
                    // inside the detail view.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Importing…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("^[\(fileCount) file](inflect: true) · \(factCount) facts")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button(action: onImport) { Label("Import…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .disabled(importDisabled)
                    Button(action: onManage) { Label("Manage", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.bordered)
                }
            } else if available {
                Button(action: onImport) {
                    Label("Import…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importDisabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        .opacity(available ? 1 : 0.65)
    }
}
