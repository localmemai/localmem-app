import SwiftUI
import AppKit

@main
struct LocalmemApp: App {
    init() {
        // SwiftPM executables aren't .app bundles, so macOS defaults the
        // process to a background-only app. Force regular foreground policy
        // so the window appears and we get a Dock icon + menu bar.
        // Use NSApplication.shared (not NSApp) — the latter is nil before
        // the SwiftUI runtime bootstraps the app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Fake model (Phase 3 swaps this for LocalmemCore.Memory)

struct MemoryListItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
}

let sampleItems: [MemoryListItem] = [
    .init(title: "Coffee preference"),
    .init(title: "Localmem brand casing"),
    .init(title: "Modern frameworks preference"),
]

struct ContentView: View {
    // The selection lives here because two children need to see it:
    // SidebarView writes to it, DetailView reads from it.
    @State private var selection: MemoryListItem.ID?

    private var selectedItem: MemoryListItem? {
        sampleItems.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(items: sampleItems, selection: $selection)
            } detail: {
                DetailView(item: selectedItem)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                // Settings — Phase 10.
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("New", systemImage: "plus") {}
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .searchable(text: .constant(""), placement: .toolbar, prompt: "Search memories…")

            StatusBarView()
        }
    }
}

struct SidebarView: View {
    let items: [MemoryListItem]
    @Binding var selection: MemoryListItem.ID?

    var body: some View {
        List(items, selection: $selection) { item in
            SidebarRow(item: item)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }
}

struct SidebarRow: View {
    let item: MemoryListItem
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.blue).frame(width: 10, height: 10)
            Text(item.title).lineLimit(1)
        }
    }
}

struct DetailView: View {
    let item: MemoryListItem?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.title2.weight(.semibold))
                Text("Body coming in Phase 4.").foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView("Select a memory", systemImage: "doc.text")
        }
    }
}

struct StatusBarView: View {
    var body: some View {
        HStack {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text("Connected").font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}
