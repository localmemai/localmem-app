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

struct ContentView: View {
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                DetailView()
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
    var body: some View {
        List {
            Text("Memory 1")
            Text("Memory 2")
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }
}

struct DetailView: View {
    var body: some View {
        Text("Select a memory")
    }
}

struct StatusBarView: View {
    var body: some View {
        HStack {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text("Connected").font(.footnote)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}
