import SwiftUI
import LocalmemCore

// MARK: - Setup wizard
//
// Drives the real setup flow: detects which agents are installed, lets the
// user choose which to connect, then runs `localmem setup` (via
// AgentConfigurationInspector) and prunes any agent the user left unchecked.
//
// Interim mechanism: `localmem setup` connects *every* installed agent
// all-or-nothing, so selective control is done by running setup and then
// disconnecting the unchecked agents. This will be replaced by per-agent
// in-process registrars once the setup engine is extracted into a shared
// library (see docs/Setup_Wizard_Plan discussion).

enum SetupWizardMode {
    case firstRun
    case reconfigure
}

enum SetupWizardStep: Int, CaseIterable, Identifiable {
    case welcome, protectVault, review, run, access
    var id: Int { rawValue }

    var railTitle: String {
        switch self {
        case .welcome:      return "Welcome"
        case .protectVault: return "Protect vault"
        case .review:       return "Connect agents"
        case .run:          return "Set up"
        case .access:       return "Access control"
        }
    }

    var symbol: String {
        switch self {
        case .welcome:      return "sparkles"
        case .protectVault: return "lock.shield"
        case .review:       return "person.2"
        case .run:          return "gearshape.2"
        case .access:       return "lock.rectangle.on.rectangle"
        }
    }
}

struct WizardAgent: Identifiable {
    let id: String
    let displayName: String
    let symbol: String
    var isInstalled: Bool
    var selected: Bool
    /// Was this agent already connected before the wizard ran? Drives the
    /// reconfigure diff (unchecking a connected agent → disconnect) and the
    /// connected/already-connected labelling.
    var wasConnected: Bool
}

enum WizardRunOutcome {
    case connected
    case alreadyConnected
    case disconnected
    case skipped
    case failed(String)
    case instructionsInstalled
    case importAdded

    var symbol: String {
        switch self {
        case .connected, .instructionsInstalled, .importAdded: return "checkmark.circle.fill"
        case .alreadyConnected: return "arrow.triangle.2.circlepath"
        case .disconnected:     return "minus.circle.fill"
        case .skipped:          return "minus.circle"
        case .failed:           return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connected, .instructionsInstalled, .importAdded: return .green
        case .alreadyConnected: return .secondary
        case .disconnected:     return .orange
        case .skipped:          return .secondary
        case .failed:           return .red
        }
    }

    var label: String {
        switch self {
        case .connected:             return "Connected"
        case .alreadyConnected:      return "Already connected"
        case .disconnected:          return "Disconnected"
        case .skipped:               return "Not connected"
        case .instructionsInstalled: return "Instructions installed"
        case .importAdded:           return "Import line added"
        case .failed(let why):       return "Failed — \(why)"
        }
    }
}

struct WizardRunRow: Identifiable {
    enum Kind { case agent, instruction }
    enum State { case pending, running, done(WizardRunOutcome) }

    let id: String
    let name: String
    let symbol: String
    let colorID: String?
    let kind: Kind
    var state: State = .pending
}

@MainActor
@Observable
final class SetupWizardModel {
    enum TouchIDState { case idle, authenticating, enabled, failed }

    let mode: SetupWizardMode
    var stepIndex = 0
    var touchIDState: TouchIDState = .idle
    var agents: [WizardAgent] = []
    var runRows: [WizardRunRow] = []
    var isRunning = false
    var runComplete = false

    init(mode: SetupWizardMode) {
        self.mode = mode
        detect()
    }

    var steps: [SetupWizardStep] {
        mode == .firstRun
            ? [.welcome, .protectVault, .review, .run, .access]
            : [.review, .run]
    }

    var currentStep: SetupWizardStep {
        steps[min(max(stepIndex, 0), steps.count - 1)]
    }

    var canGoBack: Bool { stepIndex > 0 && !isRunning && touchIDState != .authenticating }
    var touchIDEnabled: Bool { touchIDState == .enabled }

    // MARK: Detection

    /// Rebuild the agent list from the current on-disk state. Selection defaults
    /// to every installed agent on first run, and to the currently-connected set
    /// when reconfiguring.
    func detect() {
        agents = KnownAgents.all.map { known in
            let snapshot = AgentSnapshot(
                id: known.id, displayName: known.displayName, symbol: known.symbol,
                isConnected: false, lastAccess: nil, reads: 0, writes: 0
            )
            let state = AgentConfigurationInspector.state(for: snapshot)
            let connected = state.isRegistered
            return WizardAgent(
                id: known.id,
                displayName: known.displayName,
                symbol: known.symbol,
                isInstalled: state.isInstalled,
                selected: mode == .reconfigure ? connected : state.isInstalled,
                wasConnected: connected && state.isInstalled
            )
        }
    }

    private func isRegistered(_ agentID: String) -> Bool {
        guard let known = KnownAgents.all.first(where: { $0.id == agentID }) else { return false }
        let snapshot = AgentSnapshot(
            id: known.id, displayName: known.displayName, symbol: known.symbol,
            isConnected: false, lastAccess: nil, reads: 0, writes: 0
        )
        return AgentConfigurationInspector.state(for: snapshot).isRegistered
    }

    private func hasImport(_ agentID: String) -> Bool {
        guard let known = KnownAgents.all.first(where: { $0.id == agentID }) else { return false }
        let snapshot = AgentSnapshot(
            id: known.id, displayName: known.displayName, symbol: known.symbol,
            isConnected: false, lastAccess: nil, reads: 0, writes: 0
        )
        return AgentConfigurationInspector.state(for: snapshot).hasInstructionImport == true
    }

    // MARK: Touch ID

    /// Fire the real Touch ID prompt. Falls back to a simulated success when
    /// biometrics aren't available (unsigned dev build / no hardware) so the
    /// flow stays walkable.
    func enableTouchID() {
        guard touchIDState != .authenticating, touchIDState != .enabled else { return }
        touchIDState = .authenticating
        Task { @MainActor in
            let ok: Bool
            if BiometryGate.available {
                ok = await BiometryGate.authenticate(reason: "Enable Touch ID for your Localmem vault")
            } else {
                try? await Task.sleep(for: .milliseconds(700))
                ok = true
            }
            touchIDState = ok ? .enabled : .failed
        }
    }

    // MARK: Navigation

    func next() {
        if stepIndex < steps.count - 1 { stepIndex += 1 }
    }

    func back() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        if currentStep != .run { resetRun() }
    }

    private func resetRun() {
        isRunning = false
        runComplete = false
        runRows = []
    }

    // MARK: Run pass

    func startRun() {
        guard !isRunning, !runComplete else { return }
        let connectAgents = agents.filter { $0.selected && $0.isInstalled }
        let disconnectAgents = agents.filter { !$0.selected && $0.isInstalled }
        runRows = buildRows(connect: connectAgents, disconnect: disconnectAgents)
        guard !runRows.isEmpty else { runComplete = true; return }

        isRunning = true
        Task { @MainActor in
            // Connect + instruction rows spin during the single setup call.
            for index in runRows.indices where runRows[index].id.hasPrefix("reg-")
                || runRows[index].kind == .instruction {
                runRows[index].state = .running
            }

            var setupError: String?
            if !connectAgents.isEmpty {
                do { _ = try await AgentConfigurationInspector.repairAll() }
                catch { setupError = error.localizedDescription }
            }
            await finalizeConnectRows(connectAgents, error: setupError)

            // Prune the agents the user left unchecked (setup connects them all).
            for agent in disconnectAgents {
                update(rowID: "rm-\(agent.id)") { $0.state = .running }
                var removeError: String?
                do { try await AgentConfigurationInspector.removeConnection(agentID: agent.id) }
                catch { removeError = error.localizedDescription }
                try? await Task.sleep(for: .milliseconds(150))
                let outcome: WizardRunOutcome = removeError.map { .failed($0) }
                    ?? (agent.wasConnected ? .disconnected : .skipped)
                update(rowID: "rm-\(agent.id)") { $0.state = .done(outcome) }
            }

            detect()
            isRunning = false
            runComplete = true
        }
    }

    private func buildRows(connect: [WizardAgent], disconnect: [WizardAgent]) -> [WizardRunRow] {
        var rows: [WizardRunRow] = []
        for a in connect {
            rows.append(.init(id: "reg-\(a.id)", name: a.displayName, symbol: a.symbol,
                              colorID: a.id, kind: .agent))
        }
        for a in disconnect {
            rows.append(.init(id: "rm-\(a.id)", name: a.displayName, symbol: a.symbol,
                              colorID: a.id, kind: .agent))
        }
        if !connect.isEmpty {
            rows.append(.init(id: "canonical", name: "~/.localmem/AGENTS.md", symbol: "doc.text",
                              colorID: nil, kind: .instruction))
            for a in connect {
                rows.append(.init(id: "imp-\(a.id)", name: a.displayName, symbol: a.symbol,
                                  colorID: a.id, kind: .instruction))
            }
        }
        return rows
    }

    private func finalizeConnectRows(_ connect: [WizardAgent], error: String?) async {
        for agent in connect {
            let registered = isRegistered(agent.id)
            let outcome: WizardRunOutcome = registered
                ? (agent.wasConnected ? .alreadyConnected : .connected)
                : .failed(error ?? "registration did not complete")
            try? await Task.sleep(for: .milliseconds(150))
            update(rowID: "reg-\(agent.id)") { $0.state = .done(outcome) }
            update(rowID: "imp-\(agent.id)") {
                $0.state = .done(self.hasImport(agent.id) ? .importAdded : .failed("import line missing"))
            }
        }
        update(rowID: "canonical") {
            $0.state = .done(error == nil ? .instructionsInstalled : .failed("setup failed"))
        }
    }

    private func update(rowID: String, _ transform: (inout WizardRunRow) -> Void) {
        if let index = runRows.firstIndex(where: { $0.id == rowID }) { transform(&runRows[index]) }
    }

    // MARK: Summary

    private func outcome(_ row: WizardRunRow) -> WizardRunOutcome? {
        if case .done(let o) = row.state { return o }
        return nil
    }

    var connectedCount: Int {
        runRows.filter { row in
            guard row.kind == .agent, let o = outcome(row) else { return false }
            switch o { case .connected, .alreadyConnected: return true; default: return false }
        }.count
    }
    var disconnectedCount: Int {
        runRows.filter { if case .disconnected? = outcome($0) { return true }; return false }.count
    }
    var failedCount: Int {
        runRows.filter { if case .failed? = outcome($0) { return true }; return false }.count
    }
}

// MARK: - Container

struct SetupWizardView: View {
    @Binding var isPresented: Bool
    let onFinish: () -> Void
    @State private var model: SetupWizardModel

    init(isPresented: Binding<Bool>, mode: SetupWizardMode = .firstRun, onFinish: @escaping () -> Void = {}) {
        self._isPresented = isPresented
        self.onFinish = onFinish
        self._model = State(initialValue: SetupWizardModel(mode: mode))
    }

    var body: some View {
        HStack(spacing: 0) {
            stepRail
            Divider()
            bodyColumn
        }
        .frame(width: 680, height: 520)
    }

    private func finish() {
        onFinish()
        isPresented = false
    }

    // MARK: Left rail

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Get started").font(.headline).padding(.bottom, 4)
            ForEach(model.steps) { step in
                let isCurrent = step == model.currentStep
                let isDone = (model.steps.firstIndex(of: step) ?? 0) < model.stepIndex
                HStack(spacing: 10) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : step.symbol)
                        .foregroundStyle(isCurrent ? Color.accentColor : (isDone ? .green : .secondary))
                        .frame(width: 20)
                    Text(step.railTitle)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 190, alignment: .leading)
        .background(.background.secondary)
    }

    // MARK: Right column

    private var bodyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch model.currentStep {
                case .welcome:      WizardWelcomeScreen()
                case .protectVault: WizardProtectScreen(model: model)
                case .review:       WizardReviewScreen(model: model)
                case .run:          WizardRunScreen(model: model)
                case .access:       WizardAccessScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            if model.canGoBack {
                Button("Back") { withAnimation(.snappy) { model.back() } }
            }
            Spacer()
            secondaryButton
            primaryButton
        }
        .padding(20)
    }

    @ViewBuilder private var secondaryButton: some View {
        switch model.currentStep {
        case .protectVault where !model.touchIDEnabled && model.touchIDState != .authenticating:
            Button("Not now") { withAnimation(.snappy) { model.next() } }
        case .access:
            Button("Set up access later") { finish() }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        Button(primaryLabel) { primaryAction() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(primaryDisabled)
    }

    private var primaryLabel: String {
        switch model.currentStep {
        case .welcome:      return "Get Started"
        case .protectVault:
            switch model.touchIDState {
            case .idle:           return "Enable Touch ID"
            case .authenticating: return "Waiting for Touch ID…"
            case .enabled:        return "Continue"
            case .failed:         return "Try Again"
            }
        case .review:       return model.mode == .reconfigure ? "Apply Changes" : "Set Up Agents"
        case .run:
            if model.isRunning { return "Setting up…" }
            return model.mode == .firstRun ? "Continue" : "Done"
        case .access:       return "Open Localmem"
        }
    }

    private var primaryDisabled: Bool {
        if model.currentStep == .run, !model.runComplete { return true }
        if model.currentStep == .protectVault, model.touchIDState == .authenticating { return true }
        return false
    }

    private func primaryAction() {
        switch model.currentStep {
        case .protectVault where !model.touchIDEnabled:
            model.enableTouchID()
        case .run where model.runComplete && model.mode == .reconfigure:
            finish()
        case .access:
            finish()
        default:
            withAnimation(.snappy) { model.next() }
        }
    }
}

// MARK: - Shared hero

private struct WizardHero: View {
    let symbol: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Screens

private struct WizardWelcomeScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WizardHero(symbol: "brain.head.profile")
            Text("Welcome to Localmem")
                .font(.largeTitle.weight(.bold))
            Text("Localmem is a local, private memory your AI agents can read and write — shared across every project, never leaving your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                WizardBullet(symbol: "lock.fill", text: "Everything stays on-device, in a file you own.")
                WizardBullet(symbol: "person.2.fill", text: "Connect Claude, Cursor, Codex and more in one step.")
                WizardBullet(symbol: "slider.horizontal.3", text: "Decide exactly what each agent can see.")
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(28)
    }
}

private struct WizardBullet: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct WizardProtectScreen: View {
    @Bindable var model: SetupWizardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WizardHero(symbol: "lock.shield")
            Text("Protect your vault")
                .font(.largeTitle.weight(.bold))
            Text("Lock Localmem behind Touch ID so only you can open the vault and change what your agents can see. You can toggle this anytime from the status bar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                statusIcon
                Text(statusText)
                    .foregroundStyle(model.touchIDEnabled ? .primary : .secondary)
                if model.touchIDEnabled {
                    Spacer()
                    Button("Turn off") { model.touchIDState = .idle }
                        .buttonStyle(.link)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
        .padding(28)
    }

    @ViewBuilder private var statusIcon: some View {
        switch model.touchIDState {
        case .authenticating:
            ProgressView().controlSize(.small)
        case .enabled:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        case .idle:
            Image(systemName: "touchid").font(.title2).foregroundStyle(Color.accentColor)
        }
    }

    private var statusText: String {
        switch model.touchIDState {
        case .idle:           return "Touch ID is not enabled yet."
        case .authenticating: return "Confirm with Touch ID to continue…"
        case .enabled:        return "Touch ID is on for this vault."
        case .failed:         return "Couldn’t verify. Try again, or skip for now."
        }
    }
}

private struct WizardReviewScreen: View {
    @Bindable var model: SetupWizardModel

    private var installedCount: Int { model.agents.filter(\.isInstalled).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.mode == .reconfigure ? "Reconfigure agents" : "Connect your agents")
                    .font(.largeTitle.weight(.bold))
                Text(model.mode == .reconfigure
                     ? "Uncheck an agent to disconnect it. Localmem removes its import line and MCP entry."
                     : "Every installed agent is connected by default. Uncheck any you’d rather leave out.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if installedCount == 0 {
                ContentUnavailableView(
                    "No supported agents detected",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Install Claude, Cursor, Codex, or Antigravity, then reopen setup.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($model.agents) { $agent in
                            WizardAgentRow(agent: $agent, mode: model.mode)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
    }
}

private struct WizardAgentRow: View {
    @Binding var agent: WizardAgent
    let mode: SetupWizardMode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.symbol)
                .font(.title3)
                .foregroundStyle(SourcePalette.color(for: agent.id) ?? .gray)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).fontWeight(.medium)
                if mode == .reconfigure, agent.wasConnected, !agent.selected {
                    Text("Will be disconnected").font(.caption).foregroundStyle(.orange)
                } else if agent.wasConnected {
                    Text("Currently connected").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if agent.isInstalled {
                Toggle("", isOn: $agent.selected)
                    .toggleStyle(.switch)
                    .labelsHidden()
            } else {
                Pill(text: "Not installed", color: .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .opacity(agent.isInstalled ? 1 : 0.55)
    }
}

private struct WizardRunScreen: View {
    @Bindable var model: SetupWizardModel

    private var agentRows: [WizardRunRow] { model.runRows.filter { $0.kind == .agent } }
    private var instructionRows: [WizardRunRow] { model.runRows.filter { $0.kind == .instruction } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.runComplete ? "Setup complete" : "Setting things up…")
                    .font(.largeTitle.weight(.bold))
                Text(model.runComplete
                     ? "Restart any open Claude, Cursor, Codex, or Antigravity sessions to pick up Localmem."
                     : "Registering Localmem and installing agent instructions.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !agentRows.isEmpty {
                        WizardRunSection(title: "Agents", rows: agentRows)
                    }
                    if !instructionRows.isEmpty {
                        WizardRunSection(title: "Instructions", rows: instructionRows)
                    }
                }
            }

            if model.runComplete {
                HStack(spacing: 14) {
                    summaryChip("\(model.connectedCount) connected", .green)
                    if model.disconnectedCount > 0 { summaryChip("\(model.disconnectedCount) disconnected", .orange) }
                    if model.failedCount > 0 { summaryChip("\(model.failedCount) failed", .red) }
                }
                CLIToolCard()
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .onAppear { model.startRun() }
    }

    private func summaryChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
    }
}

/// Optional card offering to put the bundled `localmem` CLI on the user's PATH.
/// Only shown when the app carries a bundled CLI (i.e. a packaged .app).
private struct CLIToolCard: View {
    @State private var status = CLIToolInstaller.status()
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        if status != .unavailable {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command-line tool").fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(errorText != nil ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var subtitle: String {
        if let errorText { return errorText }
        switch status {
        case .installed:          return "`localmem` is on your PATH."
        case .conflict(let path): return "Another `localmem` is on your PATH (\(path))."
        case .notInstalled:       return "Add `localmem` to your PATH to use it from any terminal."
        case .unavailable:        return ""
        }
    }

    @ViewBuilder private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            switch status {
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .conflict:
                Button("Replace") { install() }
            case .notInstalled:
                Button("Install") { install() }
            case .unavailable:
                EmptyView()
            }
        }
    }

    private func install() {
        busy = true
        errorText = nil
        Task {
            do {
                try await Task.detached { try CLIToolInstaller.install() }.value
            } catch let error as CLIToolInstallError {
                if case .cancelled = error {} else { errorText = error.errorDescription }
            } catch {
                errorText = error.localizedDescription
            }
            status = CLIToolInstaller.status()
            busy = false
        }
    }
}

private struct WizardRunSection: View {
    let title: String
    let rows: [WizardRunRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows) { WizardRunRowView(row: $0) }
        }
    }
}

private struct WizardRunRowView: View {
    let row: WizardRunRow
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .foregroundStyle(SourcePalette.color(for: row.colorID) ?? .gray)
                .frame(width: 22)
            Text(row.name)
            Spacer()
            switch row.state {
            case .pending:
                Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
            case .running:
                ProgressView().controlSize(.small)
            case .done(let outcome):
                HStack(spacing: 6) {
                    Text(outcome.label).font(.callout).foregroundStyle(.secondary)
                    Image(systemName: outcome.symbol).foregroundStyle(outcome.tint)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WizardAccessScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WizardHero(symbol: "lock.rectangle.on.rectangle")
            Text("You’re in control")
                .font(.largeTitle.weight(.bold))
            Text("Every memory is visible to all your agents by default — but you decide the exceptions. Block a sensitive memory from one agent, or hide everything from another.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                accessExample(memory: "AWS root credentials", agent: "Cursor", allowed: false)
                accessExample(memory: "Coffee preference", agent: "Claude Code", allowed: true)
            }
            .padding(.top, 4)

            Text("Manage this anytime from the Agents tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
    }

    private func accessExample(memory: String, agent: String, allowed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 20)
            Text(memory).fontWeight(.medium)
            Spacer()
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Text(agent).foregroundStyle(.secondary)
            Pill(text: allowed ? "Allowed" : "Blocked", color: allowed ? .green : .red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
