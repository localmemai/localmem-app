import SwiftUI
import LocalmemCore

// MARK: - Connectors catalog

/// A connector *type* shown in the Connectors catalog. v1 ships exactly one
/// *available* type (Files & Folders); the rest are coming-soon cards that
/// advertise the roadmap in-product. Each available type can later host one or
/// more *sources* (the specific folders/files a user connects through it).
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
        name: "Files & Folders",
        symbol: "folder",
        blurb: "Point Localmem at a folder or file and it pulls out the key facts on your Mac, turning them into memories.",
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
    @State private var vm: ConnectorsViewModel? = try? ConnectorsViewModel()
    @State private var showWizard = false
    @State private var showManage = false

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 16, alignment: .top)]

    private var filesSourceCount: Int { vm?.sources.count ?? 0 }
    private var filesFactCount: Int {
        guard let vm else { return 0 }
        return vm.sources.reduce(0) { $0 + (vm.stats[$1.id]?.factCount ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    title: "Connectors",
                    subtitle: "Bring existing context in from your files and apps — extracted on-device, privately."
                )

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(connectorCatalog) { connector in
                        if connector.id == "files" {
                            ConnectorCard(
                                connector: connector,
                                sourceCount: filesSourceCount,
                                factCount: filesFactCount,
                                onConnect: { showWizard = true },
                                onManage: { showManage = true }
                            )
                        } else {
                            ConnectorCard(connector: connector, onConnect: { showWizard = true })
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await vm?.refresh() }
        .sheet(isPresented: $showWizard) {
            if let vm { ConnectorWizardView(vm: vm) }
        }
        .sheet(isPresented: $showManage) {
            if let vm { ConnectorManageView(vm: vm) }
        }
    }
}

private struct ConnectorCard: View {
    let connector: ConnectorType
    var sourceCount: Int = 0
    var factCount: Int = 0
    let onConnect: () -> Void
    var onManage: () -> Void = {}

    private var available: Bool { connector.status == .available }
    private var connected: Bool { available && sourceCount > 0 }

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
                Text("^[\(sourceCount) source](inflect: true) · \(factCount) facts")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(action: onConnect) { Label("Import…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Button(action: onManage) { Label("Manage", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.bordered)
                }
            } else if available {
                Button(action: onConnect) {
                    Label("Connect…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1))
        .opacity(available ? 1 : 0.65)
    }
}
