import SwiftUI

struct ServerDetailView: View {
    let server: Server
    let irohService: IrohService
    let monitor: IrohConnectionMonitor
    let sessionManager: WebAppSessionManager
    let onAppsUpdated: ([AppInfo]) -> Void
    let onAliasChange: (String) -> Void
    let onReportedName: (String) -> Void
    /// The user tapped an app; the root list owns the navigation stack, so it
    /// presents the app (creating/activating its session).
    let onOpenApp: (WebAppSessionKey) -> Void

    @State private var apps: [AppInfo]
    /// Optional launch paths (e.g. `/?token=…`) keyed by the server's name for
    /// the app (`AppLaunchStore`).
    @State private var launchPaths: [String: String]
    @State private var alias: String
    /// The name the server reports about itself. Local state (not the pushed
    /// snapshot) so the title reflects a name fetched after this view appeared.
    @State private var reportedName: String?
    @State private var isRefreshing = false
    /// An invitation is being minted (may reconnect first); shows progress.
    @State private var isCreatingInvitation = false
    @State private var refreshError: String?
    @State private var showRename = false
    @State private var renameText = ""
    /// The app whose launch path is being edited, if any.
    @State private var launchPrompt: AppInfo?
    @State private var launchText = ""
    @State private var invitation: InvitationPresentation?
    /// The invite sheet (the access picker, then the minted QR — the sheet's
    /// content swaps in place once `invitation` is set).
    @State private var showInviteSheet = false
    /// This device's reported scope for the access picker (`nil` on servers
    /// that predate per-device scopes — then the picker never shows).
    @State private var deviceAccess: DeviceAccess?
    /// Mint failure shown *inside* the access picker (the sheet covers the
    /// screen, so the root view's alert would not be visible).
    @State private var inviteError: String?
    /// The hidden connection-diagnosis modal (long-press the Connection row).
    @State private var showConnectionLogs = false

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
        sessionManager: WebAppSessionManager,
        onAppsUpdated: @escaping ([AppInfo]) -> Void,
        onAliasChange: @escaping (String) -> Void,
        onReportedName: @escaping (String) -> Void,
        onOpenApp: @escaping (WebAppSessionKey) -> Void
    ) {
        self.server = server
        self.irohService = irohService
        self.monitor = monitor
        self.sessionManager = sessionManager
        self.onAppsUpdated = onAppsUpdated
        self.onAliasChange = onAliasChange
        self.onReportedName = onReportedName
        self.onOpenApp = onOpenApp
        _apps = State(initialValue: server.apps)
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
                        Button {
                            onOpenApp(WebAppSessionKey(nodeId: server.nodeId, app: app.name))
                        } label: {
                            appRow(app)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(displayTitle)
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
                        Task { await prepareInvite() }
                    }
                    .disabled(isCreatingInvitation || isRefreshing)
                } label: {
                    // Any server action in flight spins the icon, so it is
                    // always obvious that something is happening.
                    if isRefreshing || isCreatingInvitation {
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
        .sheet(isPresented: $showInviteSheet) {
            if let invitation {
                InviteDeviceView(
                    serverName: displayTitle,
                    uri: invitation.uri,
                    expiresAt: invitation.expiresAt
                )
            } else {
                InviteAccessView(
                    apps: apps,
                    access: deviceAccess,
                    nodeId: server.nodeId,
                    irohService: irohService,
                    isMinting: isCreatingInvitation,
                    errorMessage: inviteError,
                    onCreate: { ports in
                        Task { await mintInvitation(ports: ports, inSheet: true) }
                    }
                )
            }
        }
        .onChange(of: showInviteSheet) { _, shown in
            // A dismissed sheet must not leak a stale QR (or scope) into the
            // next invitation.
            if !shown {
                invitation = nil
                deviceAccess = nil
                inviteError = nil
            }
        }
        .sheet(isPresented: $showConnectionLogs) {
            ConnectionLogView(nodeId: server.nodeId, title: displayTitle, monitor: monitor)
        }
        .task(id: server.nodeId) {
            // Establish/probe the serve connection so the indicator reflects
            // reality as soon as this screen appears.
            await revalidateOnAppear()
        }
        .onChange(of: connectionState) { _, newState in
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
            Task { await revalidateOnAppear() }
        }
    }

    private func revalidateOnAppear() async {
        await irohService.validateConnection(nodeId: server.nodeId)
        await loadServerInfo()
    }

    /// Read the name the server reports about itself.
    private func loadServerInfo() async {
        guard case .connected = connectionState else { return }
        guard let info = try? await irohService.fetchServerInfo(nodeId: server.nodeId), !info.name.isEmpty else { return }
        guard info.name != reportedName else { return }
        reportedName = info.name
        onReportedName(info.name)
    }

    /// Prepare an invitation: connect, read this device's access scope, and
    /// decide whether the inviter has a choice to make.
    ///
    /// The access picker only appears when choosing would matter — this
    /// device reported a scope with at least two ports and there are apps to
    /// pick from. Otherwise the classic inherit-everything link is minted
    /// directly, exactly as before. Runs behind `isCreatingInvitation`, which
    /// disables the menu item and spins the toolbar icon.
    private func prepareInvite() async {
        guard !isCreatingInvitation else { return }
        isCreatingInvitation = true
        defer { isCreatingInvitation = false }

        await irohService.validateConnection(nodeId: server.nodeId)
        guard case .connected = connectionState else {
            refreshError = "Not connected to the server. Try again once it reconnects."
            return
        }

        // `nil` on a server that predates per-device scopes — such a server
        // would silently ignore a narrowed invitation, so we must not offer
        // one. A fetch failure is treated the same way (no picker, no claim).
        let access = try? await irohService.fetchDeviceAccess(nodeId: server.nodeId)
        deviceAccess = access
        inviteError = nil

        if InviteAccess.shouldOfferChoice(access: access, apps: apps) {
            showInviteSheet = true
        } else {
            invitation = nil
            // Release the flag: mintInvitation guards on it (the `defer`
            // below re-clears it, which is a no-op).
            isCreatingInvitation = false
            if await mintInvitation(ports: nil, inSheet: false) {
                showInviteSheet = true
            }
        }
    }

    /// Mint a one-time invitation and present it as a QR/link sheet.
    ///
    /// `ports` narrows the grant (`nil` inherits this device's access);
    /// `inSheet` decides where a failure surfaces — inside the access picker,
    /// which covers the screen, or the root view's alert on the direct path.
    /// Can take a few seconds, so it runs behind `isCreatingInvitation`.
    private func mintInvitation(ports: [UInt16]?, inSheet: Bool) async -> Bool {
        guard !isCreatingInvitation else { return false }
        isCreatingInvitation = true
        defer { isCreatingInvitation = false }

        func fail(_ message: String) -> Bool {
            if inSheet {
                inviteError = message
            } else {
                refreshError = message
            }
            return false
        }

        if inSheet { inviteError = nil }
        await irohService.validateConnection(nodeId: server.nodeId)
        guard case .connected = connectionState else {
            return fail("Not connected to the server. Try again once it reconnects.")
        }
        do {
            let invite = try await irohService.createInvitation(
                nodeId: server.nodeId,
                ports: ports
            )
            invitation = InvitationPresentation(
                uri: invite.uri,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(invite.expiresAtUnix))
            )
            return true
        } catch {
            return fail(InviteAccess.mintErrorMessage(error))
        }
    }

    /// Trigger a server-side discovery scan and refresh the app list.
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await irohService.validateConnection(nodeId: server.nodeId)
        guard case .connected = connectionState else {
            refreshError = "Not connected to the server. Try again once it reconnects."
            return
        }
        await loadServerInfo()

        do {
            let updated = try await irohService.discoverCatalog(nodeId: server.nodeId)
            apps = updated
            onAppsUpdated(updated)
        } catch {
            refreshError = error.localizedDescription
        }
    }

    // MARK: - Connection status

    /// This server's connection state. Keyed by node id, so a *different*
    /// server's connection is never shown here (the NodeId-isolation rule) —
    /// the bug this replaced: a connected server's state leaked into an
    /// unreachable one's detail screen.
    private var connectionState: IrohConnectionState {
        monitor.state(for: server.nodeId)
    }

    @ViewBuilder
    private var connectionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text("Connection")
                Spacer()
                Text(statusText)
                    .foregroundStyle(.secondary)
                if case .disconnected = connectionState {
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

            if case .disconnected(let reason) = connectionState,
               let reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Hidden diagnosis: long-pressing the Connection row opens a live view
        // of the captured connection log. Deliberately undiscoverable — there
        // is no visible affordance.
        .contentShape(Rectangle())
        .onLongPressGesture {
            showConnectionLogs = true
        }
        .accessibilityAction(named: "Connection Logs") {
            showConnectionLogs = true
        }
    }

    private var statusColor: Color {
        switch connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .unknown: return .gray
        }
    }

    private var statusText: String {
        switch connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        // Before the first check the state is genuinely unknown; say so in a
        // way that reads as "working on it" rather than as a failure.
        case .unknown: return "Checking…"
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
        HStack(spacing: 10) {
            AppIconView(nodeId: server.nodeId, app: app.name, service: irohService)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Green dot = the app is running in the background; tapping
                    // resumes it warm instead of reconnecting/reopening.
                    if sessionManager.isRunning(nodeId: server.nodeId, app: app.name) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Running")
                    }
                    Text(app.name)
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
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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
            if sessionManager.isRunning(nodeId: server.nodeId, app: app.name) {
                Button("Close Running App", role: .destructive) {
                    sessionManager.close(nodeId: server.nodeId, app: app.name)
                }
            }
        }
    }
}
