import SwiftUI

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
    @State private var setupConnector: ConnectorType?

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Connectors",
                    subtitle: "Bring existing context in from your files and apps — extracted on-device, privately."
                )

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(connectorCatalog) { connector in
                        ConnectorCard(connector: connector) { setupConnector = connector }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(item: $setupConnector) { ConnectorSetupPlaceholder(connector: $0) }
    }
}

private struct ConnectorCard: View {
    let connector: ConnectorType
    let onConnect: () -> Void

    private var available: Bool { connector.status == .available }

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

            if available {
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

/// Interim setup surface until the guided import wizard + extraction backends
/// land. Explains what the connector does and how setup will work, so the
/// "Available" card leads somewhere honest.
private struct ConnectorSetupPlaceholder: View {
    let connector: ConnectorType
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: connector.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name).font(.title3.weight(.semibold))
                    Text("Set up file import").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text("When you connect a source, Localmem will:").font(.callout)

            VStack(alignment: .leading, spacing: 10) {
                step("cpu", "Use Apple's on-device model — nothing leaves your Mac.")
                step("person.2", "If it isn't available, ask which configured agent to use.")
                step("folder", "Let you pick a folder or file (Text, Markdown, or PDF).")
                step("sparkles", "Extract the key facts and keep them updated as files change.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            Label("Guided setup is arriving in an upcoming update.", systemImage: "clock.badge")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
