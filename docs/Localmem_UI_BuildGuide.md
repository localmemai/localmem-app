# Localmem UI — Step-by-step build & learning guide

A phased path from "never written SwiftUI" to "shippable Localmem app". Each phase
introduces a small set of SwiftUI concepts and uses them to build one slice of
the app described in the [Localmem vault prototype](../localmem-vault-ui/index.html).

Work top to bottom. Don't skip ahead — later phases assume the state model from
earlier ones. Expect 1–2 evenings per phase if you're new to SwiftUI.

> **What survives from earlier iterations of this guide:** the LocalmemCore work
> (`MemoryStore`, `ActivityStore`, SQLite + FTS), the source palette, the search
> behavior, the `@Observable` view-model pattern, and the polling-task pattern for
> the status bar. **What gets rebuilt:** the shell. The new layout is a left rail
> + top toolbar + content router + bottom status bar — not a `NavigationSplitView`.
> Memories becomes one of seven tabs.

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
           WindowGroup("Localmem") {
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

**Goal:** The 3-zone window layout the vault uses: **left rail** with the brand
and nav items, **top toolbar** with search + global actions, **content area**
showing a placeholder, **bottom status bar**. No real switching yet.

**Concepts.**
- **View composition.** SwiftUI views are structs; you compose them by nesting `HStack` / `VStack`.
- **Modifiers.** `.padding()`, `.frame()`, `.background()` return new views; order matters.
- `.windowStyle(.hiddenTitleBar)` — removes the standard macOS title bar so our top toolbar reads as the only bar.
- `.safeAreaInset(edge:)` — pins a status bar without it scrolling.

**Build.**
1. Replace the `Text("Hello Localmem")` body with a `ContentView()` and a min frame:

   ```swift
   WindowGroup("Localmem") {
       ContentView()
           .frame(minWidth: 1100, minHeight: 700)
   }
   .windowStyle(.hiddenTitleBar)
   ```
2. Three subviews, one shell:

   ```swift
   struct ContentView: View {
       var body: some View {
           HStack(spacing: 0) {
               SidebarRail()
                   .frame(width: 244)

               VStack(spacing: 0) {
                   TopToolbar()
                       .frame(height: 56)

                   ContentArea()
                       .frame(maxWidth: .infinity, maxHeight: .infinity)

                   StatusBar()
                       .frame(height: 42)
               }
           }
       }
   }

   struct SidebarRail: View {
       var body: some View {
           VStack(alignment: .leading, spacing: 16) {
               BrandHeader()
               NavList()
               Spacer()
           }
           .padding(.horizontal, 13)
           .padding(.vertical, 15)
           .background(.regularMaterial)
       }
   }

   struct TopToolbar: View {
       var body: some View {
           HStack(spacing: 12) {
               Button { } label: { Image(systemName: "sidebar.left") }
                   .buttonStyle(.plain)
               SearchField(text: .constant(""))
                   .frame(maxWidth: 420)
               Spacer()
               Button("Setup Wizard") { }
               Button("Import") { }
               Button("Export") { }
               Button("+ New Memory") { }
                   .buttonStyle(.borderedProminent)
           }
           .padding(.horizontal, 16)
           .background(.regularMaterial)
       }
   }

   struct ContentArea: View {
       var body: some View {
           Text("Overview placeholder").foregroundStyle(.secondary)
       }
   }

   struct StatusBar: View {
       var body: some View {
           HStack(spacing: 24) {
               Label("Unlocked", systemImage: "lock.open").foregroundStyle(.secondary)
               Spacer()
               Text("4 agents · last activity 2 min ago").foregroundStyle(.secondary)
           }
           .font(.footnote)
           .padding(.horizontal, 16)
           .background(.regularMaterial)
       }
   }
   ```
3. Add a `BrandHeader`, `NavList`, and a small `SearchField` (rounded HStack with
   magnifying glass + `TextField(_, text:)` on a `.background(.tertiary, in: ...)` capsule).
   Leave the nav items as static `Button`s with hardcoded labels for now —
   wiring is Phase 2.

**You'll learn.** How real apps are made of nested views, how SwiftUI lays them out, what `.frame(width:)` vs `.frame(maxWidth:)` actually does.

**Done when.** The window renders the same three zones as the prototype, with the rail collapsing to a fixed width and the toolbar/status bar pinned top/bottom.

---

## Phase 2 — Navigation between sections (1 evening)

**Goal:** The 7 nav items on the left actually switch the content area between
seven view stubs.

**Concepts.**
- `@State` — local mutable state owned by a view.
- `enum` + `Hashable` + `CaseIterable` — modeling the section set.
- `@ViewBuilder` and `switch` inside `body`.
- Driving styling off an equality check (`isActive = section == current`).

**Build.**
1. Define the section enum next to `ContentView`:

   ```swift
   enum AppSection: String, CaseIterable, Hashable {
       case overview, memories, agents, access, audit, sync, connectors

       var label: String {
           switch self {
           case .overview:   "Overview"
           case .memories:   "Memories"
           case .agents:     "Agents"
           case .access:     "Access Rules"
           case .audit:      "Audit Log"
           case .sync:       "Sync & Devices"
           case .connectors: "Connectors"
           }
       }

       var symbol: String {
           switch self {
           case .overview:   "square.grid.2x2"
           case .memories:   "doc.text"
           case .agents:     "person.crop.square"
           case .access:     "lock.shield"
           case .audit:      "list.bullet.rectangle"
           case .sync:       "icloud"
           case .connectors: "arrow.left.arrow.right"
           }
       }
   }
   ```
2. `ContentView` owns the selection and passes it to the rail and the content area:

   ```swift
   struct ContentView: View {
       @State private var section: AppSection = .overview

       var body: some View {
           HStack(spacing: 0) {
               SidebarRail(section: $section).frame(width: 244)
               VStack(spacing: 0) {
                   TopToolbar()
                       .frame(height: 56)
                   ContentArea(section: section)
                   StatusBar()
                       .frame(height: 42)
               }
           }
       }
   }
   ```
3. `SidebarRail` renders one button per case:

   ```swift
   struct NavList: View {
       @Binding var section: AppSection

       var body: some View {
           VStack(alignment: .leading, spacing: 4) {
               ForEach(AppSection.allCases, id: \.self) { item in
                   NavItem(item: item, isActive: item == section) {
                       section = item
                   }
               }
           }
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
                   Spacer()
               }
               .padding(.horizontal, 10)
               .frame(height: 36)
               .background(isActive ? Color.accentColor.opacity(0.14) : .clear,
                           in: RoundedRectangle(cornerRadius: 8))
           }
           .buttonStyle(.plain)
       }
   }
   ```
4. `ContentArea` routes the current section to a stub view:

   ```swift
   struct ContentArea: View {
       let section: AppSection

       var body: some View {
           Group {
               switch section {
               case .overview:   OverviewView()
               case .memories:   MemoriesView()
               case .agents:     AgentsView()
               case .access:     AccessRulesView()
               case .audit:      AuditLogView()
               case .sync:       SyncDevicesView()
               case .connectors: ConnectorsView()
               }
           }
           .frame(maxWidth: .infinity, maxHeight: .infinity)
       }
   }
   ```
   Make each `*View()` a one-liner `Text("Overview")` etc. for now.

**You'll learn.** SwiftUI's one-way data flow: state in the parent, bindings to the child, child writes back, body re-runs. Why an enum is the right model for a fixed set of choices.

**Done when.** Clicking any nav item swaps the content area and highlights the active row.

---

## Phase 3 — Overview page with fake data (1 evening)

**Goal:** Build the Overview view — stats strip + recent memories panel + recent activity panel — entirely with hardcoded sample data.

**Concepts.**
- Panel/card pattern — a recurring view modifier you'll use across every page.
- `LazyVGrid` for the stats strip.
- `ForEach` over arrays of `Identifiable` structs.

**Build.**
1. Make a small `Panel` view modifier:

   ```swift
   struct Panel<Content: View>: View {
       let title: String
       var actionLabel: String? = nil
       var onAction: (() -> Void)? = nil
       @ViewBuilder let content: Content

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
   ```
2. Stats strip — four boxes in an `HStack` (or `LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4))`):

   ```swift
   struct StatsStrip: View {
       var body: some View {
           HStack(spacing: 12) {
               StatCard(value: "128", label: "Memories")
               StatCard(value: "4",   label: "Agents")
               StatCard(value: "22",  label: "Accesses today")
               StatCard(value: "3",   label: "Blocked")
           }
       }
   }

   struct StatCard: View {
       let value: String
       let label: String
       var body: some View {
           VStack(alignment: .leading, spacing: 4) {
               Text(value).font(.system(size: 28, weight: .bold))
               Text(label).font(.caption).foregroundStyle(.secondary)
           }
           .frame(maxWidth: .infinity, alignment: .leading)
           .padding(14)
           .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
       }
   }
   ```
3. Two-column body — fake `OverviewMemoryRow` and `OverviewActivityRow` types
   plus sample arrays. Inside `OverviewView`:

   ```swift
   ScrollView {
       VStack(spacing: 20) {
           StatsStrip()
           HStack(alignment: .top, spacing: 20) {
               Panel(title: "Recent Memories") {
                   ForEach(sampleRecentMemories) { row in
                       RecentMemoryRow(row: row)
                   }
               }
               Panel(title: "Recent Agent Activity") {
                   ForEach(sampleRecentActivity) { row in
                       ActivityRow(row: row)
                   }
               }
           }
       }
       .padding(20)
   }
   ```

**You'll learn.** Generic views with `@ViewBuilder` content, the panel/card design system, how to lay out two equal columns that respect their content height.

**Done when.** Overview renders the same shape as the prototype: stats row, then two columns of cards.

---

## Phase 4 — Memories page: list + detail (1 evening)

**Goal:** The Memories tab — list of memories on the left, detail card on the right.

**Concepts.**
- `HStack` two-pane (we no longer use `NavigationSplitView` — the shell already provides one).
- `List(selection:)` and `Identifiable`.
- Conditional content with `if let`.

**Build.**
1. Reuse the `MemoryListItem` style from the destination prototype:

   ```swift
   struct SampleMemory: Identifiable, Hashable {
       let id = UUID()
       let title: String
       let type: String
       let source: String
       let body: String
       let tags: [String]
       let updated: String
       let isPrivate: Bool
   }
   ```
2. `MemoriesView` is its own two-pane container:

   ```swift
   struct MemoriesView: View {
       @State private var selection: SampleMemory.ID? = sampleMemories.first?.id
       private var selected: SampleMemory? {
           sampleMemories.first { $0.id == selection }
       }

       var body: some View {
           HStack(spacing: 0) {
               MemoryList(memories: sampleMemories, selection: $selection)
                   .frame(width: 320)
                   .background(.background.secondary)
               MemoryDetail(memory: selected)
                   .frame(maxWidth: .infinity, maxHeight: .infinity)
           }
       }
   }
   ```
3. `MemoryList` is a `List(_, selection:)` with custom rows. `MemoryDetail` shows
   the title, a `SourceDot` + metadata strip, body, tags, and an "Agent Access"
   sub-panel (use the same `Panel` from Phase 3).

**You'll learn.** Two-pane layout without `NavigationSplitView`, where to draw the line between "page" and "sub-view", how `List(selection:)` ties to `Identifiable`.

**Done when.** Memories tab shows the prototype's split, clicking rows updates the detail card.

---

## Phase 5 — Connect LocalmemCore (1 evening)

**Goal:** Replace the sample arrays with a real `@Observable` view model backed by `MemoryStore`.

**Concepts.**
- `@Observable` (the macro that replaces `ObservableObject`).
- View model pattern — a `class` that owns mutable data; views observe it.
- `.task { … }` for async loads on appear.

**Build.**
1. The view model:

   ```swift
   import LocalmemCore
   import Observation

   @Observable @MainActor
   final class MemoryStoreViewModel {
       private(set) var memories: [Memory] = []
       private let store: MemoryStore

       init() throws { self.store = try MemoryStore() }

       func load(limit: Int = 50) async {
           memories = (try? await store.recent(limit: limit)) ?? []
       }
   }
   ```
2. Share it across `OverviewView` and `MemoriesView`. Two ways: pass via parameter,
   or via `.environment(\.memoryStoreVM, vm)` and an `@Environment` lookup. Start
   with parameter passing for clarity:

   ```swift
   struct ContentView: View {
       @State private var vm: MemoryStoreViewModel? = try? MemoryStoreViewModel()
       @State private var section: AppSection = .overview

       var body: some View {
           HStack(spacing: 0) {
               SidebarRail(section: $section).frame(width: 244)
               VStack(spacing: 0) {
                   TopToolbar()
                   ContentArea(section: section, vm: vm)
                   StatusBar()
               }
           }
           .task { await vm?.load() }
       }
   }
   ```
3. Replace `sampleRecentMemories` and `sampleMemories` with `vm.memories`. Update
   `RecentMemoryRow` and the memory list row to take a real `LocalmemCore.Memory`.

**You'll learn.** How an `@Observable` class lets multiple views observe the same data, why view models live as classes (identity persists across `body` re-runs).

**Done when.** Memories added via the CLI (`localmem add ...`) show up in both Overview's "Recent Memories" panel and the Memories tab on launch.

---

## Phase 6 — Source palette + private memories (half evening)

**Goal:** Colored dots actually mean something; private memories show a lock affordance.

**Concepts.**
- Enums with associated colors.
- Conditional view content for the lock badge.
- SF Symbols' `.symbolRenderingMode(.hierarchical)`.

**Build.**
1. `SourcePalette` mapping `Memory.source` → `Color?`. `nil` = hollow ring for unknown
   provenance; other sources get a saturated hue:

   ```swift
   enum SourcePalette {
       static func color(for source: String?) -> Color? {
           switch source {
           case ".user":                          return .accentColor
           case "claude-code", "claude-desktop":  return .orange
           case "cursor":                         return .purple
           case "codex":                          return .green
           case "antigravity", "antigravity-client": return .pink
           case "phone":                          return .cyan
           case nil, "":                          return nil
           default:                               return .gray
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
2. Extend `LocalmemCore.Memory` with `isPrivate: Bool` (requires a v2 migration in
   `Migrations.swift` — a single `ALTER TABLE memories ADD COLUMN is_private INTEGER NOT NULL DEFAULT 0`).
3. In the memory row + detail, render a `LockBadge` when `memory.isPrivate`:

   ```swift
   if memory.isPrivate {
       Image(systemName: "lock.fill")
           .foregroundStyle(.yellow)
           .symbolRenderingMode(.hierarchical)
   }
   ```

**You'll learn.** Extracting reusable presentation primitives, how `nil` propagates through optional binding, how a small `if` in `body` cleanly handles binary states.

**Done when.** `.user` memories show blue, `claude-code` shows orange, `phone` shows cyan, private memories carry a lock icon in both the list and detail.

---

## Phase 7 — Search across pages (1 evening)

**Goal:** Typing in the top toolbar's search field filters both Overview's "Recent Memories" panel and the Memories tab's list, live.

**Concepts.**
- Shared `@State` lifted to `ContentView`.
- `.task(id:)` — SwiftUI auto-cancels the previous task when the id changes.
- FTS-backed search via `MemoryStore.search(query:)`.

**Build.**
1. Hoist a `query` string into `ContentView`:

   ```swift
   @State private var query = ""
   ```
2. Add a `search(_ q: String)` method to the view model that calls `store.recent`
   on empty input and `store.search(query:)` otherwise:

   ```swift
   func search(_ query: String, limit: Int = 50) async {
       let trimmed = query.trimmingCharacters(in: .whitespaces)
       memories = trimmed.isEmpty
           ? (try? await store.recent(limit: limit)) ?? []
           : (try? await store.search(query: trimmed, limit: limit)) ?? []
   }
   ```
3. Replace the load-on-appear with a single `.task(id: query)`:

   ```swift
   .task(id: query) { await vm?.search(query) }
   ```

   This fires once on first appear (with `query == ""`, which falls through to
   `recent`) and again on every keystroke.
4. Bind the toolbar's `SearchField(text:)` to `$query`.

**You'll learn.** Why `.task(id:)` is the right tool for live search (no manual debounce), how shared state in the parent lets unrelated children stay in sync.

**Done when.** Typing "coffee" in the toolbar narrows both Overview's recent panel and Memories' list.

---

## Phase 8 — Add / Edit memory modal (1 evening)

**Goal:** The **+ New Memory** button opens a modal form. The detail's **Edit**
button reuses the same modal pre-filled.

**Concepts.**
- `.sheet(isPresented:)` and `.sheet(item:)`.
- `@Environment(\.dismiss)` for self-closing.
- Form fields with placeholder behavior.
- `MemoryStoreViewModel.create()` / `update()` async methods.

**Build.**
1. Add `create(...)` and `update(...)` to the view model. `create` calls
   `store.add`; `update` calls a new `store.update(...)` method you'll add to
   `LocalmemCore` (insert + tag-diff + activity row in a single transaction).
2. The modal is a single struct that handles both modes:

   ```swift
   struct MemoryModalView: View {
       enum Mode { case new, edit(Memory) }
       let mode: Mode
       let vm: MemoryStoreViewModel
       let onSaved: (Memory.ID) -> Void

       @Environment(\.dismiss) private var dismiss
       @State private var title = ""
       @State private var type: MemoryType = .note
       @State private var content = ""
       @State private var tagsInput = ""
       @State private var requireTouchID = false

       var body: some View {
           VStack(spacing: 0) {
               // ... header, form fields, action row ...
           }
           .frame(width: 560, height: 540)
           .onAppear { populateForEditIfNeeded() }
       }
   }
   ```
3. In `ContentView`, drive presentation via `@State private var sheet: SheetKind?`
   where `SheetKind: Identifiable` enumerates the modal types (`.newMemory`,
   `.editMemory(Memory)`, `.agentConfig(Agent)`, etc.). One `.sheet(item:)`
   modifier handles them all.

**You'll learn.** Modal presentation, when to use `.sheet(isPresented:)` vs `.sheet(item:)`, dismissing via the environment.

**Done when.** **+ New Memory** opens an empty form, **Edit** opens it pre-filled, both write to the store and refresh the list.

---

## Phase 9 — Agents page (1 evening)

**Goal:** A card grid of each known agent showing status, access level, and
read/write counts; a configure modal for each.

**Concepts.**
- `LazyVGrid` with adaptive columns.
- Reading agent state from registrar files (the same files `localmem setup` writes).
- Pill components (we'll reuse these on multiple pages).

**Build.**
1. Model:

   ```swift
   struct AgentSnapshot: Identifiable {
       let id: String           // "claude-code", "cursor", …
       let displayName: String
       let symbol: String       // SF Symbol
       let isConnected: Bool
       let lastAccess: Date?
       let access: AccessLevel
       let reads: Int
       let writes: Int
   }

   enum AccessLevel: String, CaseIterable {
       case noAccess = "No Access"
       case askFirst = "Ask First"
       case readOnly = "Read"
       case readWrite = "Read + Write"
   }
   ```
2. `AgentsViewModel` reads registrar state (via `ClientRegistrar.isRegistered()`) +
   counts from `ActivityStore` per agent + an in-memory `AccessLevel` (Phase 10
   will persist these).
3. `AgentsView` uses `LazyVGrid` with `GridItem(.adaptive(minimum: 240))` so the
   grid reflows. Each `AgentCard` is `Panel`-styled with the symbol/name/status/
   pill/counts/configure button.
4. A small `Pill` view:

   ```swift
   struct Pill: View {
       let text: String
       let color: Color
       var body: some View {
           Text(text)
               .font(.caption.weight(.semibold))
               .padding(.horizontal, 8).padding(.vertical, 3)
               .background(color.opacity(0.18), in: Capsule())
               .foregroundStyle(color)
       }
   }
   ```

**You'll learn.** `LazyVGrid`, reusing presentation primitives across pages, reading and composing data from multiple sources (registrar + activity store).

**Done when.** Each agent shows its current connection state and registered access level; the grid reflows when you resize the window.

---

## Phase 10 — Access Rules (1 evening)

**Goal:** The matrix table — category × agent → access level — and the
"Ask First Queue" of pending approvals.

**Concepts.**
- `Grid` (macOS 14+) for typed-row tables.
- `Picker(_, selection:)` bound to per-cell state.
- A new `AccessControlStore` that persists category-level defaults and per-memory overrides.

**Build.**
1. New `LocalmemCore` types:

   ```swift
   public enum MemoryCategory: String, CaseIterable, Codable, Sendable {
       case preferences, projects, personal, `private`
   }

   public struct AccessRule: Codable, Sendable {
       public let category: MemoryCategory
       public let agentID: String
       public var level: AccessLevel
   }
   ```
2. A `Grid` with rows per category, columns per agent. Each cell is a
   `Picker("", selection: …)` with the four levels.

   ```swift
   Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
       GridRow {
           Text("Category").font(.subheadline.weight(.semibold))
           ForEach(agents) { Text($0.displayName) }
       }
       ForEach(MemoryCategory.allCases, id: \.self) { category in
           GridRow {
               Text(category.rawValue.capitalized)
               ForEach(agents) { agent in
                   AccessPicker(
                       level: vm.binding(for: category, agentID: agent.id)
                   )
               }
           }
       }
   }
   ```
3. Below the matrix, an `AskFirstQueue` `Panel` lists pending requests with
   **Deny** / **Allow** buttons.

**You'll learn.** `Grid` for keep-aligned tabular layouts, persisting structured config to disk (use a small JSON file at `~/.localmem/access.json` for now).

**Done when.** Changing a cell persists and is reflected on the Agents page; allowing a queued request writes an activity row.

---

## Phase 11 — Audit Log full page (half evening)

**Goal:** The complete activity log, filterable by status (Allowed / Blocked / Needs Review) and by actor.

**Concepts.**
- `List` for long collections with separators.
- `Picker` toolbar filters bound to a `@State` filter struct.
- `.searchable` on a per-page basis.

**Build.**
1. `AuditLogViewModel` exposes `var rows: [ActivityRowView.Model]`, reads from
   `ActivityStore.recent(limit: 500)`, and applies a filter struct in-memory.
2. `AuditLogView` is a `VStack` of `[FilterBar, List]`. Each row uses a small
   `EventDot` (green/red/yellow) and a `Pill` with the result label.

**You'll learn.** Hosting `List` inside a custom page (vs as the only view in a column), keeping filter state out of the row view.

**Done when.** The full activity log is browseable, filters narrow it live.

---

## Phase 12 — Bottom status bar (half evening)

**Goal:** Real data in all five segments — vault lock state · connected agents · cloud sync · companion app · last activity.

**Concepts.**
- A second `@Observable` view model dedicated to status.
- `.task { while !Task.isCancelled { … Task.sleep … } }` — the polling pattern.
- Reading from multiple stores in one refresh.

**Build.**
1. The view model:

   ```swift
   @Observable @MainActor
   final class VaultStatusViewModel {
       private(set) var locked = false
       private(set) var connectedAgents: [String] = []
       private(set) var cloudSyncOn = false
       private(set) var companionConnected = false
       private(set) var lastActivity: Date?

       private let activity: ActivityStore
       init() throws { self.activity = try ActivityStore() }

       func refresh() async {
           let rows = (try? await activity.recent(limit: 20)) ?? []
           connectedAgents = Array(Set(rows.compactMap(\.actorID))).sorted()
           lastActivity    = rows.first?.occurredAt
           // CloudKit + Companion state come from Phases 13.
       }
   }
   ```
2. Status bar consumes it:

   ```swift
   StatusBar(vm: statusVM)
       .task {
           while !Task.isCancelled {
               await statusVM.refresh()
               try? await Task.sleep(for: .seconds(1))
           }
       }
   ```

**You'll learn.** Why polling lives in `.task` (auto-cancellation), how to keep status reads cheap.

**Done when.** Writing a memory from the CLI updates the bar within ~1s; the segments wire to real data sources or stable mocks.

---

## Phase 13 — Touch ID gating for private memories (1 evening)

**Goal:** Opening a private memory triggers a Touch ID prompt; until it succeeds, the body/tag list is replaced by a "Locked" placeholder.

**Concepts.**
- The **LocalAuthentication** framework (`LAContext`).
- An `async` API surface wrapped in a Swift task.
- View modifier that gates content.

**Build.**
1. A small Touch ID helper:

   ```swift
   import LocalAuthentication

   enum BiometryError: Error { case unavailable, cancelled, failed(Error) }

   actor BiometryGate {
       func authenticate(reason: String) async throws {
           let ctx = LAContext()
           var error: NSError?
           guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
               throw BiometryError.unavailable
           }
           do {
               try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
           } catch { throw BiometryError.failed(error) }
       }
   }
   ```
2. `PrivacyShield` view modifier:

   ```swift
   struct PrivacyShield<Content: View>: View {
       let isPrivate: Bool
       @ViewBuilder let content: () -> Content
       @State private var unlocked = false

       var body: some View {
           if !isPrivate || unlocked {
               content()
           } else {
               VStack(spacing: 12) {
                   Image(systemName: "lock.fill").font(.title)
                   Text("Private memory — unlock with Touch ID")
                       .foregroundStyle(.secondary)
                   Button("Unlock") {
                       Task {
                           do {
                               try await BiometryGate().authenticate(reason: "View private memory")
                               unlocked = true
                           } catch { }
                       }
                   }
                   .buttonStyle(.borderedProminent)
               }
               .padding()
               .frame(maxWidth: .infinity, maxHeight: .infinity)
           }
       }
   }
   ```
3. Wrap the body + tags in `MemoryDetail` with `PrivacyShield(isPrivate: memory.isPrivate) { … }`.

**You'll learn.** Bridging Apple's older callback APIs into Swift Concurrency, scoping state to a view modifier so per-memory unlock doesn't leak.

**Done when.** Opening a private memory shows the lock screen first; passing Touch ID reveals the content for that memory only.

---

## Phase 14 — Sync & Devices (1 evening)

**Goal:** Show CloudKit sync status, last sync time, and the device list (this Mac + iPhone companion + iPad placeholder). No real CloudKit syncing in V1 — we render *state*, not behavior.

**Concepts.**
- `CKContainer.default()` for account status reads.
- A side-tab pattern for grouping settings (Devices, CloudKit, Conflicts).
- Optional features behind capability checks.

**Build.**
1. A thin `SyncStatusViewModel` that asks `CKContainer.default().accountStatus()`
   for the iCloud state and persists a last-sync timestamp to UserDefaults.
2. `SyncDevicesView` uses two side-by-side `Panel`s — Devices on the left,
   CloudKit on the right.
3. Hard-code the companion device for now; Phase 16 of "iPhone companion" lives
   outside this guide.

**You'll learn.** Reading from system frameworks, gracefully degrading when a capability isn't available.

**Done when.** The Sync tab renders the prototype's content with real iCloud account status.

---

## Phase 15 — Connectors (1 evening)

**Goal:** The connector grid. **Obsidian** (Pro), **Markdown Folder** (Free), and **JSON Backup** (Free) are real; **Notion / Apple Notes / Google Drive** are visual placeholders.

**Concepts.**
- `NSOpenPanel` for folder picking (via `NSOpenPanel` directly — SwiftUI lacks a first-class folder picker on macOS).
- File I/O via `FileManager`.
- `Codable` for JSON export.

**Build.**
1. `ConnectorRegistry` enumerates available connectors with their state.
2. **JSON Backup**: `await store.recent(limit: .max)` → `JSONEncoder` → file.
3. **Markdown Folder**: pick a folder via `NSOpenPanel`, write one `.md` per memory.
4. **Obsidian**: same as Markdown but uses an Obsidian-friendly frontmatter block.

**You'll learn.** Calling AppKit panels from SwiftUI, structuring file-system writes through Swift Concurrency.

**Done when.** You can export the store as a folder of Markdown files and re-import them via Markdown Folder.

---

## Phase 16 — First-run wizard (1–2 evenings)

**Goal:** A modal 5-step flow on first launch — Welcome → Protect Vault → Connect Agents → Cloud Sync → Connectors.

**Concepts.**
- `.fullScreenCover` for setup flows.
- Multi-step state machines: enum + `@State`.
- `@AppStorage` for the "seen wizard" flag.

**Build.**
1. Step enum:

   ```swift
   enum WizardStep: Int, CaseIterable {
       case welcome, protect, agents, sync, connectors
   }
   ```
2. `WizardView` has a step rail on the left (numbered stages) and a body that
   switches on the current step.
3. Trigger on first launch by checking `@AppStorage("seenWizard") var seen = false`.

**You'll learn.** State-machine UIs in SwiftUI, persistent settings, sequential flows that gate by step completion.

**Done when.** Deleting the `seenWizard` UserDefault and relaunching walks through the 5 steps.

---

## Phase 17 — Polish (ongoing)

These are the things that take a competent SwiftUI app and make it feel like Apple shipped it.

- **Materials & vibrancy.** `.background(.regularMaterial)` on the rail, toolbar, and status bar (you've already started this in Phase 1).

  ```swift
  .background(.regularMaterial)
  ```
- **Accent colors.** Add a custom accent color asset in Assets.xcassets; the system handles light/dark automatically. Reference it with `Color.accentColor`.
- **SF Symbols.** Always use `Image(systemName:)`. Open the SF Symbols app to browse — copy the exact symbol name.

  ```swift
  Image(systemName: "lock.shield").symbolRenderingMode(.hierarchical)
  ```
- **Keyboard shortcuts.** Wire ⌘N to + New Memory, ⌘F to focus the search field, ⌘1–⌘7 to switch sections:

  ```swift
  Button("New") { ... }
      .keyboardShortcut("n", modifiers: .command)
  ```
- **Empty states.** Use the built-in `ContentUnavailableView` (macOS 14+):

  ```swift
  ContentUnavailableView("No memories yet", systemImage: "tray",
                         description: Text("Press ⌘N to add your first one."))
  ```
- **Animations.** Wrap state changes:

  ```swift
  withAnimation(.snappy) { section = .memories }
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
