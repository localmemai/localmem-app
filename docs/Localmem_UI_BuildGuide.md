# Localmem UI — Step-by-step build & learning guide

A phased path from "never written SwiftUI" to "shippable Localmem app". Each phase
introduces a small set of SwiftUI concepts and uses them to build one slice of
the app described in [Localmem_UI_Design.md](Localmem_UI_Design.md).

Work top to bottom. Don't skip ahead — later phases assume the state model from
earlier ones. Expect 1–2 evenings per phase if you're new to SwiftUI.

---

## Phase 0 — Setup (30 min)

**Goal:** Xcode open, a new `localmem-app` target booting an empty window.

**Tools.**
- Install **Xcode 16+** from the Mac App Store.
- Install the SF Symbols app (free from Apple) — you'll browse icons there.

**Steps.**
1. From the repo root: `open Package.swift`. Xcode opens the package — no `.xcodeproj` needed.
2. In `Package.swift`, add a new executable target `localmem-app`:

   ```swift
   // products
   .executable(name: "localmem-app", targets: ["localmem-app"]),

   // targets
   .executableTarget(
       name: "localmem-app",
       dependencies: ["LocalmemCore"],
       path: "Sources/localmem-app"
   ),
   ```
3. Create `Sources/localmem-app/LocalmemApp.swift`:

   ```swift
   import SwiftUI
   import AppKit

   @main
   struct LocalmemApp: App {
       init() {
           // SwiftPM executables aren't .app bundles, so macOS defaults the
           // process to a background-only app and the window never appears.
           // Force regular foreground policy so we get a window, Dock icon,
           // and menu bar. We'll replace this with a proper Xcode app target
           // when we're ready to ship.
           //
           // Use NSApplication.shared, not NSApp: NSApp is nil before SwiftUI's
           // runtime bootstraps the application — `App.init()` runs first.
           NSApplication.shared.setActivationPolicy(.regular)
           NSApplication.shared.activate()
       }

       var body: some Scene {
           WindowGroup {
               Text("Hello Localmem")
           }
       }
   }
   ```
4. In Xcode's scheme dropdown (top-left), pick `localmem-app` → My Mac, hit ⌘R. A window opens.

**You'll learn.**
- How a Swift Package becomes an Xcode-runnable app.
- The `@main`-annotated `App` protocol and `Scene` (`WindowGroup`).
- The Xcode canvas — open any `.swift` file with a `View` and hit ⌥⌘P to start the preview.

**Done when.** ⌘R opens a window saying "Hello Localmem" and the canvas preview renders the same.

---

## Phase 1 — The shell (1 evening)

**Goal:** A three-pane window with a toolbar and a status bar — no real data yet.

**Concepts.**
- **View composition.** SwiftUI views are structs; you compose them by nesting.
- **Modifiers.** `.padding()`, `.frame()`, `.background()` return new views; order matters.
- `NavigationSplitView` — Apple's built-in three-column layout (sidebar / content / detail). For Localmem we use it as two-column (sidebar + detail).
- `.toolbar { ToolbarItem { … } }` — declarative toolbar.
- `.safeAreaInset(edge: .bottom)` — how to pin a status bar without it scrolling.

**Build.**
1. Split `ContentView` into three child views:

   ```swift
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
       var body: some View { Text("Select a memory") }
   }

   struct StatusBarView: View {
       var body: some View {
           HStack {
               Circle().fill(.green).frame(width: 8, height: 8)
               Text("Connected").font(.footnote)
               Spacer()
           }
           .padding(.horizontal, 12).padding(.vertical, 6)
           .background(.regularMaterial)
       }
   }
   ```
2. Compose them in `ContentView`. Two non-obvious choices here:
   - `.searchable()` (not a raw `TextField`) for the search slot — that gets the magnifying glass and proper macOS search styling for free; Phase 6 swaps `.constant("")` for real state.
   - The status bar lives in a `VStack` *outside* the `NavigationSplitView` (not inside its safe area). This lets the sidebar's rounded bottom corner end above the status bar, matching how Finder/Mail/Notes draw their footers.

   ```swift
   struct ContentView: View {
       var body: some View {
           VStack(spacing: 0) {
               NavigationSplitView {
                   SidebarView()
               } detail: {
                   DetailView()
                       .toolbar {
                           ToolbarItem(placement: .navigation) {
                               Button { /* Phase 10 */ } label: {
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
   ```
3. Point `LocalmemApp.body` at `ContentView()` instead of the `Text` placeholder from Phase 0.

**You'll learn.** How real apps are made of nested views, how SwiftUI lays them out, where the toolbar lives.

**Done when.** The window matches the layout in §2 of the design doc, even with fake content.

---

## Phase 2 — State and the sidebar list (1 evening)

**Goal:** A working sidebar that shows fake memories, lets you click one, and updates the detail pane.

**Concepts.**
- `@State` — local mutable state owned by one view.
- `@Binding` — passing mutable state down to a child view.
- `List(selection:)` and `Identifiable` — how SwiftUI tracks rows.
- `ForEach` — iterating over collections.

**Build.**
1. Define a fake row model and seed array — don't touch the DB yet:

   ```swift
   struct MemoryListItem: Identifiable, Hashable {
       let id: UUID
       let title: String
       let sourceColor: Color
   }

   let sampleItems: [MemoryListItem] = [
       .init(id: UUID(), title: "Coffee preference",   sourceColor: .blue),
       .init(id: UUID(), title: "Localmem casing",     sourceColor: .orange),
       .init(id: UUID(), title: "Modern frameworks",   sourceColor: .purple),
   ]
   ```
2. In `ContentView`, own the selection and pass it down:

   ```swift
   struct ContentView: View {
       @State private var selection: MemoryListItem.ID?
       let items = sampleItems

       var body: some View {
           NavigationSplitView {
               SidebarView(items: items, selection: $selection)
           } detail: {
               DetailView(item: items.first { $0.id == selection })
           }
       }
   }
   ```
3. Render the list with a row view that uses the source color:

   ```swift
   struct SidebarView: View {
       let items: [MemoryListItem]
       @Binding var selection: MemoryListItem.ID?

       var body: some View {
           List(items, selection: $selection) { item in
               HStack(spacing: 8) {
                   Circle().fill(item.sourceColor).frame(width: 10, height: 10)
                   Text(item.title).lineLimit(1)
               }
           }
       }
   }
   ```
4. `DetailView` reads the optional item:

   ```swift
   struct DetailView: View {
       let item: MemoryListItem?
       var body: some View {
           if let item {
               VStack(alignment: .leading) {
                   Text(item.title).font(.title2.weight(.semibold))
                   Text("Body coming in Phase 4.").foregroundStyle(.secondary)
                   Spacer()
               }
               .padding()
           } else {
               ContentUnavailableView("Select a memory", systemImage: "doc.text")
           }
       }
   }
   ```

**You'll learn.** SwiftUI's one-way data flow: state owns the truth, bindings let children write back, the view rebuilds when state changes.

**Done when.** Clicking a sidebar row updates the detail pane title in real time.

---

## Phase 3 — Real data from `LocalmemCore` (1 evening)

**Goal:** The sidebar shows actual memories from the SQLite DB.

**Concepts.**
- `@Observable` (the modern macro, replaces `ObservableObject`).
- View model pattern in SwiftUI — a class that owns the data, views observe it.
- `Task { }` and async/await inside `.task { … }`.

**Build.**
1. Create `MemoryStoreViewModel`:

   ```swift
   import LocalmemCore
   import Observation

   @Observable @MainActor
   final class MemoryStoreViewModel {
       private(set) var memories: [Memory] = []
       private let store: MemoryStore

       init() throws { self.store = try MemoryStore() }

       func load(limit: Int = 50) async {
           do { memories = try await store.recent(limit: limit) }
           catch { memories = [] }   // surface a real error UI in Phase 12.
       }
   }
   ```
2. In `ContentView`, own the view model and load on appear:

   ```swift
   struct ContentView: View {
       @State private var vm: MemoryStoreViewModel? = try? MemoryStoreViewModel()
       @State private var selection: Memory.ID?

       var body: some View {
           NavigationSplitView {
               SidebarView(memories: vm?.memories ?? [], selection: $selection)
           } detail: {
               let selected = vm?.memories.first { $0.id == selection }
               DetailView(memory: selected)
           }
           .task { await vm?.load() }
       }
   }
   ```
3. Update the row view to take a real `Memory`:

   ```swift
   struct SidebarRow: View {
       let memory: Memory
       var body: some View {
           HStack(spacing: 8) {
               Circle().fill(.blue).frame(width: 10, height: 10)  // real palette in Phase 5
               Text(memory.title ?? String(memory.content.prefix(40))).lineLimit(1)
           }
       }
   }
   ```

**You'll learn.** How SwiftUI re-renders when observed properties change. The difference between `.task`, `.onAppear`, and `.onChange`.

**Done when.** Memories you've added via the CLI show up in the sidebar when you launch the app.

---

## Phase 4 — Detail pane, real content (half evening)

**Goal:** Selecting a memory shows its full content, metadata, and tags.

**Concepts.**
- Computed properties on views.
- Conditional content with `if let`.
- `DateFormatter.relativeDateTimeFormatter` (or `Date.RelativeFormatStyle`) for "3 days ago".

**Build.**

```swift
struct DetailView: View {
    let memory: Memory?

    var body: some View {
        guard let memory else {
            return AnyView(ContentUnavailableView("Select a memory", systemImage: "doc.text"))
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                Text(memory.title ?? "Untitled").font(.title2.weight(.semibold))

                HStack(spacing: 8) {
                    Circle().fill(.blue).frame(width: 8, height: 8)
                    Text(memory.type.rawValue)
                    Text("·").foregroundStyle(.tertiary)
                    Text(memory.createdAt, format: .relative(presentation: .named))
                }
                .font(.subheadline).foregroundStyle(.secondary)

                Text(memory.content).textSelection(.enabled)

                if !memory.tags.isEmpty {
                    HStack {
                        ForEach(memory.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.footnote)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }

                Spacer()

                HStack {
                    Button("Edit") {}
                    Button("Delete", role: .destructive) {}
                    Button("Audit trail") {}
                    Button("Access…") {}.disabled(true)
                }
            }
            .padding()
        )
    }
}
```

**You'll learn.** How to read derived values without storing them in state, how to format dates Apple-style.

**Done when.** Clicking different memories cleanly swaps the detail pane content.

---

## Phase 5 — Source palette and color dots (half evening)

**Goal:** The colored dots actually mean something.

**Concepts.**
- Enums with associated colors.
- Extracting reusable views into their own files.

**Build.**

```swift
import SwiftUI

enum SourcePalette {
    static func color(for source: String?) -> Color? {
        switch source {
        case ".user":                     return .accentColor
        case "claude-code", "claude-desktop": return .orange
        case "cursor":                    return .purple
        case "codex":                     return .green
        case "antigravity":               return .pink
        case nil, "":                     return nil      // hollow ring
        default:                          return .gray
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
```

Use `SourceDot(source: memory.source)` in the sidebar row and the detail metadata strip.

**You'll learn.** How to extract reusable presentation primitives. How SwiftUI views close over their inputs.

**Done when.** Memories written by the CLI (`source = ".user"`) show blue; memories from `claude-code` show orange; unknown sources show a hollow gray ring.

---

## Phase 6 — Search and the toolbar field (1 evening)

**Goal:** Typing in the search field filters the sidebar live.

**Concepts.**
- `@State` for the query string.
- Computed `filteredMemories` on the view model.
- `.searchable(text:)` — Apple's built-in search modifier.
- Debouncing (`.task(id:)` pattern).

**Build.**
1. Add the search method to the view model:

   ```swift
   extension MemoryStoreViewModel {
       func search(_ query: String) async {
           let trimmed = query.trimmingCharacters(in: .whitespaces)
           do {
               memories = trimmed.isEmpty
                   ? try await store.recent(limit: 50)
                   : try await store.search(query: trimmed, limit: 50)
           } catch {
               memories = []
           }
       }
   }
   ```
2. Wire the search field into `ContentView`:

   ```swift
   struct ContentView: View {
       @State private var vm: MemoryStoreViewModel? = try? MemoryStoreViewModel()
       @State private var selection: Memory.ID?
       @State private var query = ""

       var body: some View {
           NavigationSplitView { /* sidebar */ } detail: { /* detail */ }
               .searchable(text: $query, placement: .toolbar, prompt: "Search memories…")
               .task(id: query) { await vm?.search(query) }
       }
   }
   ```

`.task(id: query)` cancels and restarts the search whenever `query` changes — no manual debounce needed for typical typing speed.

**You'll learn.** Built-in toolbar slots like `.searchable`, automatic task cancellation, and how to wire reactive search without manually debouncing.

**Done when.** Typing "coffee" instantly narrows the sidebar.

---

## Phase 7 — Add memory sheet (1 evening)

**Goal:** The `+ New` button opens a modal sheet that writes to the DB.

**Concepts.**
- `.sheet(isPresented:)` modifier.
- `@State` for form fields, `@Environment(\.dismiss)` to close.
- `Form { Section { … } }` for native-styled forms.
- `disabled(_:)` for the Save button.

**Build.**
1. Add a `create` method to the view model:

   ```swift
   extension MemoryStoreViewModel {
       func create(title: String?, type: MemoryType, content: String, tags: [String]) async throws {
           _ = try await store.add(
               content: content,
               type: type,
               title: title?.isEmpty == false ? title : nil,
               tags: tags,
               actorKind: .cli,
               actorID: ".user"
           )
           await load()
       }
   }
   ```
2. Build the sheet:

   ```swift
   struct AddMemoryView: View {
       @Environment(\.dismiss) private var dismiss
       let vm: MemoryStoreViewModel

       @State private var title = ""
       @State private var type: MemoryType = .note
       @State private var content = ""
       @State private var tags: [String] = []

       var body: some View {
           Form {
               Section {
                   TextField("Title", text: $title)
                   Picker("Type", selection: $type) {
                       ForEach(MemoryType.allCases, id: \.self) { t in
                           Text(t.rawValue).tag(t)
                       }
                   }
                   TextEditor(text: $content).frame(minHeight: 160)
               }
               DisclosureGroup("Access control — coming soon") { EmptyView() }
                   .disabled(true)
           }
           .formStyle(.grouped)
           .frame(minWidth: 560, minHeight: 480)
           .toolbar {
               ToolbarItem(placement: .cancellationAction) {
                   Button("Cancel") { dismiss() }
               }
               ToolbarItem(placement: .confirmationAction) {
                   Button("Save") {
                       Task {
                           try? await vm.create(title: title, type: type, content: content, tags: tags)
                           dismiss()
                       }
                   }
                   .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
                   .keyboardShortcut("s", modifiers: .command)
               }
           }
       }
   }
   ```
3. Wire the toolbar button in `ContentView`:

   ```swift
   @State private var showingAddMemory = false
   // ...
   Button("New", systemImage: "plus") { showingAddMemory = true }
       .keyboardShortcut("n", modifiers: .command)
   // attach to the NavigationSplitView (or DetailView):
   .sheet(isPresented: $showingAddMemory) {
       if let vm { AddMemoryView(vm: vm) }
   }
   ```

**You'll learn.** Modal presentation, form construction, environment values, keyboard shortcuts.

**Done when.** ⌘N opens the sheet, saving adds a row to the sidebar without restarting the app.

---

## Phase 8 — Status bar and the daemon popover (1 evening)

**Goal:** The bottom status bar shows live daemon state and opens a popover.

**Concepts.**
- `.popover(isPresented:)` — anchored popups, macOS sweet spot.
- `Timer.publish` and `.onReceive` for periodic refresh.
- Reading `ActivityStore` from `LocalmemCore`.

**Build.**
1. The polling view model:

   ```swift
   @Observable @MainActor
   final class DaemonStatusViewModel {
       private(set) var healthy = true
       private(set) var connectedClients: [String] = []
       private(set) var lastAccess: Date?
       private(set) var memoryCount = 0

       private let activity: ActivityStore
       private let store: MemoryStore

       init() throws {
           self.activity = try ActivityStore()
           self.store    = try MemoryStore()
       }

       func refresh() async {
           let rows = (try? await activity.recent(limit: 10)) ?? []
           connectedClients = Array(Set(rows.compactMap(\.actorID))).sorted()
           lastAccess       = rows.first?.occurredAt
           memoryCount      = (try? await store.count()) ?? 0
       }
   }
   ```
2. Drive it from the status bar with a 1s timer:

   ```swift
   struct StatusBarView: View {
       let vm: DaemonStatusViewModel
       @State private var showingStatus = false

       var body: some View {
           Button { showingStatus.toggle() } label: {
               HStack(spacing: 12) {
                   Circle().fill(vm.healthy ? .green : .red).frame(width: 8, height: 8)
                   Text("Connected:").foregroundStyle(.secondary)
                   ForEach(vm.connectedClients, id: \.self) { c in SourceDot(source: c) }
                   if let last = vm.lastAccess {
                       Text("last access \(last, format: .relative(presentation: .numeric))")
                           .foregroundStyle(.secondary)
                   }
                   Spacer()
                   Text("\(vm.memoryCount) memories").foregroundStyle(.secondary)
               }
               .font(.footnote)
               .padding(.horizontal, 12).padding(.vertical, 6)
               .background(.regularMaterial)
           }
           .buttonStyle(.plain)
           .popover(isPresented: $showingStatus, arrowEdge: .bottom) {
               StatusPopover(vm: vm)
           }
           .task {
               while !Task.isCancelled {
                   await vm.refresh()
                   try? await Task.sleep(for: .seconds(1))
               }
           }
       }
   }
   ```

`StatusPopover` then renders the §10a content (daemon info, clients, last 10 activity rows) using a `List`.

**You'll learn.** Popovers, timed publishers, how to keep a polling view model cheap.

**Done when.** Writing a memory from the CLI updates the status bar within ~1s.

---

## Phase 9 — Audit trail inspector (half evening)

**Goal:** Clicking "Audit trail" slides in a right inspector showing the selected memory's history.

**Concepts.**
- `.inspector(isPresented:)` — Apple's native right-side panel.
- `Section`s in a `List` for date grouping.

**Build.**
1. The inspector:

   ```swift
   struct AuditInspector: View {
       let memoryID: UUID
       @State private var rows: [Activity] = []
       @State private var confirmingClear = false

       var body: some View {
           List {
               ForEach(grouped(rows), id: \.label) { group in
                   Section(group.label) {
                       ForEach(group.rows) { row in
                           HStack(spacing: 8) {
                               Text(row.occurredAt, format: .dateTime.hour().minute())
                                   .foregroundStyle(.secondary)
                                   .monospacedDigit()
                               SourceDot(source: row.actorID)
                               Text(row.actorID ?? "—")
                               Text("·").foregroundStyle(.tertiary)
                               Text(row.operation)
                           }
                           .font(.callout)
                       }
                   }
               }
           }
           .toolbar {
               Button("Clear log", role: .destructive) { confirmingClear = true }
           }
           .confirmationDialog("Clear audit log for this memory?",
                               isPresented: $confirmingClear, titleVisibility: .visible) {
               Button("Clear", role: .destructive) { /* call store.clearActivity(for: memoryID) */ }
               Button("Cancel", role: .cancel) {}
           }
           .task { /* rows = try? await activity.recent(filterMemoryID: memoryID) */ }
       }

       private func grouped(_ rows: [Activity]) -> [(label: String, rows: [Activity])] {
           // Today / Yesterday / older — left as an exercise; bucket on Calendar.isDateInToday etc.
           [("Today", rows)]
       }
   }
   ```
2. Wire it into `ContentView` via `.inspector`:

   ```swift
   @State private var showingAudit = false
   // toolbar/detail button: Button("Audit trail") { showingAudit = true }
   .inspector(isPresented: $showingAudit) {
       if let id = selection { AuditInspector(memoryID: id) }
   }
   ```

**You'll learn.** `.inspector` (newer SwiftUI API), confirmation dialogs, grouped lists.

**Done when.** Audit panel slides in, shows the right rows, closes cleanly.

---

## Phase 10 — Settings scene (1 evening)

**Goal:** ⌘, opens a real macOS Settings window with tabs.

**Concepts.**
- The `Settings { … }` scene — a sibling to `WindowGroup` in your `App` body.
- `TabView` with `Label` items.
- `@AppStorage` — bind a SwiftUI view to a `UserDefaults` key.

**Build.**
1. Add a `Settings` scene as a sibling of `WindowGroup`:

   ```swift
   @main
   struct LocalmemApp: App {
       var body: some Scene {
           WindowGroup { ContentView() }
           Settings { SettingsView() }
       }
   }
   ```
2. Tab-based settings view:

   ```swift
   struct SettingsView: View {
       var body: some View {
           TabView {
               GeneralSettings()
                   .tabItem { Label("General", systemImage: "gearshape") }
               Text("Access control").tabItem { Label("Access", systemImage: "lock") }
               Text("Data").tabItem { Label("Data", systemImage: "externaldrive") }
               Text("Clients").tabItem { Label("Clients", systemImage: "app.connected.to.app.below.fill") }
               Text("About").tabItem { Label("About", systemImage: "info.circle") }
           }
           .frame(width: 520, height: 360)
       }
   }

   struct GeneralSettings: View {
       @AppStorage("launchAtLogin") private var launchAtLogin = false
       @AppStorage("theme") private var theme = "system"

       var body: some View {
           Form {
               Toggle("Launch at login", isOn: $launchAtLogin)
               Picker("Theme", selection: $theme) {
                   Text("System").tag("system")
                   Text("Light").tag("light")
                   Text("Dark").tag("dark")
               }
               Button("Re-run setup wizard…") { /* set showingWizard = true */ }
           }
           .formStyle(.grouped)
           .padding()
       }
   }
   ```

⌘, opens Settings automatically once the scene exists.

**You'll learn.** Multi-scene apps, persistent settings, when to reach for `@AppStorage` vs `@State`.

**Done when.** ⌘, opens Settings, toggles persist across launches.

---

## Phase 11 — First-run wizard (1–2 evenings)

**Goal:** The 5-step setup flow described in §3 of the design doc.

**Concepts.**
- `.fullScreenCover` vs `.sheet` on macOS (sheet is the right call here).
- Multi-step state machines in SwiftUI: an enum + `@State`.
- `TimelineView` or simple polling for the "Test it works" live state.

**Build.**
1. The step enum and wizard shell:

   ```swift
   enum WizardStep: Int, CaseIterable {
       case welcome, dataLocation, connectAgents, test, done
   }

   struct WizardView: View {
       @State private var step: WizardStep = .welcome

       var body: some View {
           VStack(spacing: 0) {
               Group {
                   switch step {
                   case .welcome:       WelcomeStep()
                   case .dataLocation:  DataLocationStep()
                   case .connectAgents: ConnectAgentsStep()
                   case .test:          TestStep()
                   case .done:          DoneStep()
                   }
               }
               .frame(maxWidth: .infinity, maxHeight: .infinity)

               Divider()
               HStack {
                   Button("Back") { advance(by: -1) }
                       .disabled(step == .welcome)
                   Spacer()
                   Button(step == .done ? "Finish" : "Continue") { advance(by: 1) }
                       .keyboardShortcut(.defaultAction)
               }
               .padding()
           }
           .frame(width: 640, height: 480)
       }

       private func advance(by delta: Int) {
           let next = step.rawValue + delta
           guard let s = WizardStep(rawValue: next) else { return }
           step = s
       }
   }
   ```
2. The reusable detector belongs in `LocalmemCore` so Settings → Clients can reuse it:

   ```swift
   // Sources/LocalmemCore/ClientDetector.swift
   public struct DetectedClient: Sendable {
       public let name: String
       public let configURL: URL
       public let installed: Bool
   }

   public enum ClientDetector {
       public static func detectAll(
           homeDir: URL = FileManager.default.homeDirectoryForCurrentUser
       ) -> [DetectedClient] {
           let candidates: [(String, String)] = [
               ("Claude Desktop", "Library/Application Support/Claude/claude_desktop_config.json"),
               ("Claude Code",    ".claude.json"),
               ("Cursor",         ".cursor/mcp.json"),
               ("Codex",          ".codex/config.toml"),
               ("Antigravity",    ".gemini/config/mcp_config.json"),
           ]
           return candidates.map { name, rel in
               let url = homeDir.appendingPathComponent(rel)
               return DetectedClient(name: name, configURL: url,
                                     installed: FileManager.default.fileExists(atPath: url.path))
           }
       }
   }
   ```
3. Trigger the wizard on first launch:

   ```swift
   .sheet(isPresented: $showingWizard) { WizardView() }
   .task {
       let count = (try? await MemoryStore().count()) ?? 0
       let anyClient = ClientDetector.detectAll().contains(where: \.installed)
       showingWizard = (count == 0 && !anyClient)
   }
   ```

**You'll learn.** State machines in SwiftUI, file-system detection, and the difference between writing logic in views vs in the core library.

**Done when.** Deleting `~/.localmem` and relaunching the app walks through the wizard end-to-end.

---

## Phase 12 — Polish (ongoing)

These are the things that take a competent SwiftUI app and make it feel like Apple shipped it.

- **Materials & vibrancy.** Use `.background(.regularMaterial)` on the toolbar and status bar. Sidebars get vibrancy for free inside `NavigationSplitView`.

  ```swift
  .safeAreaInset(edge: .bottom) {
      StatusBarView(vm: status).background(.regularMaterial)
  }
  ```
- **Accent colors.** Add a custom accent color asset in Assets.xcassets; the system handles light/dark automatically. Reference it with `Color.accentColor`.
- **SF Symbols.** Always use `Image(systemName:)`. Open the SF Symbols app to browse — copy the exact symbol name.

  ```swift
  Image(systemName: "gearshape").symbolRenderingMode(.hierarchical)
  ```
- **Keyboard shortcuts.** Per §11 of the design doc:

  ```swift
  Button("New") { showingAddMemory = true }
      .keyboardShortcut("n", modifiers: .command)
  ```
- **Empty states.** Use the built-in `ContentUnavailableView` (macOS 14+):

  ```swift
  ContentUnavailableView("No memories yet", systemImage: "tray",
                         description: Text("Press ⌘N to add your first one."))
  ```
- **Animations.** Wrap state changes:

  ```swift
  withAnimation(.snappy) { selection = newID }
  ```
- **Dark mode QA.** Toggle in Xcode's preview canvas and in System Settings. Every custom color should adapt — never hard-code a hex.

  ```swift
  #Preview("Dark") { ContentView().preferredColorScheme(.dark) }
  ```

---

## How to study SwiftUI alongside this

You don't need to read a book first. The fastest path:

1. **Apple's "SwiftUI Tutorials"** (developer.apple.com/tutorials/swiftui) — do the first 4 chapters before Phase 2. Skip the rest.
2. **Hacking with Swift's "100 Days of SwiftUI"** — Paul Hudson's free course. Use it as a reference, not a curriculum; look up specific topics as they come up here.
3. **WWDC sessions to watch in order:** "SwiftUI essentials" (WWDC 2024), "Migrate to the new Observable" (WWDC 2023), "Build great list views with SwiftUI" (WWDC 2024). 15–20 min each.
4. **Read Apple's docs for the API you're using before reading a tutorial about it.** The docs are unusually good for SwiftUI.

When you get stuck, the question to ask yourself is almost always one of:
- *Who owns this state?* (`@State` in the view, `@Observable` class shared across views, `@AppStorage` for persistence)
- *Am I trying to imperatively change a view?* (You shouldn't — change the state, the view follows.)
- *Did I forget a `@Binding`?* (If a child needs to mutate a parent's state, yes.)

---

## Checkpoint after each phase

Before moving on:

- [ ] Run the app (⌘R) and verify the new behavior end-to-end.
- [ ] Open the SwiftUI preview canvas and confirm the new views render there too — previews are your fast-iteration tool.
- [ ] If you added view-model logic, add a unit test in `Tests/LocalmemAppTests/` (create the target on first need).
- [ ] Commit. Small commits per phase make it easy to retreat when an experiment doesn't work.
