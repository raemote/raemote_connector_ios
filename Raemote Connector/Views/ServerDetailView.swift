import SwiftUI

struct ServerDetailView: View {
    let server: Server
    let irohService: IrohService
    let monitor: IrohConnectionMonitor
    let onAppsUpdated: ([AppInfo]) -> Void
    let onAliasChange: (String) -> Void
    let onReportedName: (String) -> Void

    @State private var apps: [AppInfo]
    /// Display names learned from each app's live page title, keyed by the
    /// server's name for the app (`AppNameStore`).
    @State private var appNames: [String: String]
    /// Optional launch paths (e.g. `/?token=…`) keyed by the server's name for
    /// the app (`AppLaunchStore`).
    @State private var launchPaths: [String: String]
    @State private var alias: String
    /// The name the server reports about itself. Local state (not the pushed
    /// snapshot) so the title reflects a name fetched after this view appeared.
    @State private var reportedName: String?
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var showRename = false
    @State private var renameText = ""
    /// The app whose launch path is being edited, if any.
    @State private var launchPrompt: AppInfo?
    @State private var launchText = ""
    @State private var invitation: InvitationPresentation?

    /// A minted invitation presented in a sheet.
    private struct InvitationPresentation: Identifiable {
        let id = UUID()
        let uri: String
        let expiresAt: Date
    }

    @Environment(\.scenePhase) private var scenePhase

    init(
        server: Server,
        irohService: IrohService,
        monitor: IrohConnectionMonitor,
        onAppsUpdated: @escaping ([AppInfo]) -> Void,
        onAliasChange: @escaping (String) -> Void,
        onReportedName: @escaping (String) -> Void
    ) {
        self.server = server
        self.irohService = irohService
        self.monitor = monitor
        self.onAppsUpdated = onAppsUpdated
        self.onAliasChange = onAliasChange
        self.onReportedName = onReportedName
        _apps = State(initialValue: server.apps)
        _appNames = State(initialValue: AppNameStore.names(nodeId: server.nodeId))
        _launchPaths = State(initialValue: AppLaunchStore.paths(nodeId: server.nodeId))
        _alias = State(initialValue: server.name)
        _reportedName = State(initialValue: server.reportedName)
    }

    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name", value: displayTitle)
                LabeledContent("Node ID", value: server.nodeId.prefix(16) + "...")
                LabeledContent("Apps", value: "\(apps.count)")
                connectionRow
            }

            Section("Apps") {
                if apps.isEmpty {
                    ContentUnavailableView(
                        "No Apps",
                        systemImage: "app.badge",
                        description: Text("Tap refresh to scan for local apps. If none appear, make sure they're running on the computer.")
                    )
                } else {
                    ForEach(apps) { app in
                        NavigationLink(value: app) {
                            appRow(app)
                        }
                    }
                }
            }
        }
        .navigationTitle(displayTitle)
        .navigationDestination(for: AppInfo.self) { app in
            AppWebView(
                app: app,
                nodeId: server.nodeId,
                irohService: irohService,
                monitor: monitor,
                launchPath: launchPaths[app.name],
                onNameLearned: { name in
                    appNames[app.name] = name
                }
            )
        }
        .toolbar {
            // One "…" menu for all server actions — add future actions here.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename…", systemImage: "pencil") {
                        renameText = alias
                        showRename = true
                    }
                    Button("Refresh Apps", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    .disabled(isRefreshing)

                    Divider()

                    Button("Invite Device…", systemImage: "person.badge.plus") {
                        Task { await createInvitation() }
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Server actions")
            }
        }
        .alert("Rename Server", isPresented: $showRename) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                alias = trimmed
                onAliasChange(trimmed)
            }
        } message: {
            Text(aliasFooter)
        }
        .alert("Launch URL", isPresented: .constant(launchPrompt != nil)) {
            TextField("http://127.0.0.1:3080/?token=…", text: $launchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { launchPrompt = nil }
            Button("Save") {
                if let app = launchPrompt {
                    launchPaths[app.name] = AppLaunchStore.remember(
                        launchText,
                        nodeId: server.nodeId,
                        app: app.name
                    )
                }
                launchPrompt = nil
            }
        } message: {
            Text("Paste the URL the app printed on the server (raemote keeps just its path and query and opens the app with it, so token-gated apps can start). Leave it empty to clear.")
        }
        .alert("Refresh Failed", isPresented: .constant(refreshError != nil)) {
            Button("OK") { refreshError = nil }
        } message: {
            if let refreshError {
                Text(refreshError)
            }
        }
        .sheet(item: $invitation) { invitation in
            InviteDeviceView(
                serverName: displayTitle,
                uri: invitation.uri,
                expiresAt: invitation.expiresAt
            )
        }
        .task(id: server.nodeId) {
            // Establish/probe the serve connection so the indicator reflects
            // reality as soon as this screen appears.
            await irohService.validateConnection(nodeId: server.nodeId)
            await loadServerInfo()
        }
        .onChange(of: monitor.state) { _, newState in
            // (Re)read the name once the connection is up, in case the first
            // fetch ran before it was ready.
            if case .connected = newState {
                Task { await loadServerInfo() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Lock/unlock or background/foreground: the serve connection may
            // have been torn down while suspended, so revalidate on return.
            guard phase == .active else { return }
            Task {
                await irohService.validateConnection(nodeId: server.nodeId)
                await loadServerInfo()
            }
        }
    }

    /// Read the name the server reports about itself.
    private func loadServerInfo() async {
        guard case .connected = monitor.state else { return }
        guard let info = try? await irohService.fetchServerInfo(), !info.name.isEmpty else { return }
        guard info.name != reportedName else { return }
        reportedName = info.name
        onReportedName(info.name)
    }

    /// Mint a one-time invitation and present it as a QR/link sheet.
    private func createInvitation() async {
        await irohService.validateConnection(nodeId: server.nodeId)
        guard case .connected = monitor.state else {
            refreshError = "Not connected to the server. Try again once it reconnects."
            return
        }
        do {
            let invite = try await irohService.createInvitation()
            invitation = InvitationPresentation(
                uri: invite.uri,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(invite.expiresAtUnix))
            )
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// Trigger a server-side discovery scan and refresh the app list.
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await irohService.validateConnection(nodeId: server.nodeId)
        guard case .connected = monitor.state else {
            refreshError = "Not connected to the server. Try again once it reconnects."
            return
        }
        await loadServerInfo()

        do {
            let updated = try await irohService.discoverCatalog()
            apps = updated
            onAppsUpdated(updated)
        } catch {
            refreshError = error.localizedDescription
        }
    }

    // MARK: - Connection status

    @ViewBuilder
    private var connectionRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text("Connection")
            Spacer()
            Text(statusText)
                .foregroundStyle(.secondary)
            if case .disconnected = monitor.state {
                Button {
                    Task { await irohService.validateConnection(nodeId: server.nodeId) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .accessibilityLabel("Reconnect")
            }
        }

        if case .disconnected(let reason) = monitor.state,
           let reason, !reason.isEmpty {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch monitor.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .unknown: return .gray
        }
    }

    private var statusText: String {
        switch monitor.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .unknown: return "Unknown"
        }
    }

    private var displayTitle: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let reported = reportedName, !reported.isEmpty { return reported }
        return "Server \(server.nodeId.prefix(8))"
    }

    private var aliasFooter: String {
        if let reported = reportedName, !reported.isEmpty {
            return "The server calls itself \"\(reported)\". Leave this empty to use that name."
        }
        return "Give this server a name you'll recognize. Leave empty to use its own name."
    }

    private func appRow(_ app: AppInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(appNames[app.name] ?? app.name)
                    .font(.headline)
                if launchPaths[app.name] != nil {
                    Image(systemName: "link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Opens with a launch URL")
                }
            }
            Text("\(app.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Launch URL…", systemImage: "link") {
                launchText = launchPaths[app.name] ?? ""
                launchPrompt = app
            }
            if launchPaths[app.name] != nil {
                Button("Clear Launch URL", role: .destructive) {
                    AppLaunchStore.remember("", nodeId: server.nodeId, app: app.name)
                    launchPaths[app.name] = nil
                }
            }
        }
    }
}
